#!/usr/bin/env bash
# Run on a LAPTOP (not the box) once per environment, after `make apply ENV=<env>`.
# Generates every platform secret + the getpack app secret and stores them in Secrets Manager.
#
#   AWS_PROFILE=collective platform/bin/init-secrets.sh uat
#   AWS_PROFILE=collective platform/bin/init-secrets.sh uat --only getpack   # just one product
#
# Idempotent: a secret that already holds a real value is NEVER overwritten (rotating the
# postgres passwords after the database was initialised would lock the apps out). Use the
# console / `aws secretsmanager put-secret-value` for deliberate rotation.
# Requires: aws, openssl, node (JWK generation), ssh-keygen, htpasswd (macOS built-in), jq; gh optional.
set -euo pipefail

ENV="${1:?usage: init-secrets.sh <uat|prod> [--only <product>]}"
ONLY="${3:-}"
REGION="${AWS_REGION:-ap-southeast-7}"
PREFIX="collective/${ENV}"
GITHUB_REPO="${GITHUB_REPO:-Collective-Group-Thailand/collective-infra}"
ACME_EMAIL="${ACME_EMAIL:-piyapan.pak@gmail.com}"
OUT_DIR="${HOME}/.collective-secrets/${ENV}"   # local copy of generated plaintext (chmod 700) — move to your password manager
mkdir -p "$OUT_DIR"; chmod 700 "$OUT_DIR"

case "$ENV" in
  uat)  GETPACK_WEB="uat.getpack.co"; SES_DOMAIN="uat.getpack.co" ;;
  prod) GETPACK_WEB="getpack.co";     SES_DOMAIN="getpack.co" ;;
  *) echo "env must be uat or prod"; exit 1 ;;
esac

for c in aws openssl node ssh-keygen htpasswd jq; do command -v "$c" >/dev/null || { echo "missing: $c"; exit 1; }; done
acct=$(aws sts get-caller-identity --query Account --output text)
expected=$(cat "$(dirname "$0")/../../envs/account.txt" 2>/dev/null || true)
[ -z "$expected" ] || [ "$acct" = "$expected" ] || { echo "WRONG ACCOUNT $acct (expected $expected)"; exit 1; }
echo "account $acct  env $ENV  region $REGION"

pw() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "${1:-32}"; }

current() {  # prints current SecretString or empty (no version / placeholder → empty)
  local v
  v=$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$1" --query SecretString --output text 2>/dev/null || true)
  if [ -z "$v" ] || printf '%s' "$v" | jq -e '._placeholder?' >/dev/null 2>&1; then echo ""; else printf '%s' "$v"; fi
}

put() {  # put <name> <value> — only if empty
  local name="$1" value="$2"
  if [ -n "$(current "$name")" ]; then echo "  = $name (already set, kept)"; return 0; fi
  aws secretsmanager put-secret-value --region "$REGION" --secret-id "$name" --secret-string "$value" >/dev/null
  echo "  + $name"
}

# ---------------------------------------------------------------- platform
if [ -z "$ONLY" ]; then
  echo "== platform"

  # postgres: superuser + one role per product (reuse existing so product URLs stay valid)
  PG=$(current "$PREFIX/platform/postgres")
  if [ -z "$PG" ]; then
    PG=$(jq -n --arg s "$(pw 40)" --arg a "$(pw 32)" --arg b "$(pw 32)" --arg c "$(pw 32)" \
      '{superuser_password:$s, getpack_password:$a, getproperty_password:$b, getbuild_password:$c}')
    put "$PREFIX/platform/postgres" "$PG"
  else echo "  = $PREFIX/platform/postgres (already set, kept)"; fi

  VK=$(current "$PREFIX/platform/valkey")
  if [ -z "$VK" ]; then VK=$(jq -n --arg p "$(pw 40)" '{password:$p}'); put "$PREFIX/platform/valkey" "$VK"
  else echo "  = $PREFIX/platform/valkey (already set, kept)"; fi

  EM_PW=$(pw 24)
  put "$PREFIX/platform/emqx" "$(jq -n --arg p "$EM_PW" '{dashboard_password:$p}')"

  # Caddy basic-auth for /emqx and /alloy on the platform host (bcrypt; Caddy accepts $2a$)
  if [ -z "$(current "$PREFIX/platform/caddy")" ]; then
    OPS_PW=$(pw 24)
    HASH=$(htpasswd -nbBC 12 ops "$OPS_PW" | cut -d: -f2 | sed 's/^\$2y\$/$2a$/')
    put "$PREFIX/platform/caddy" "$(jq -n --arg e "$ACME_EMAIL" --arg u "ops:$HASH" '{acme_email:$e, basic_auth_users:[$u]}')"
    printf 'platform basic-auth  user=ops  password=%s\nemqx dashboard       user=admin password=%s\n' "$OPS_PW" "$EM_PW" > "$OUT_DIR/platform-logins.txt"
    chmod 600 "$OUT_DIR/platform-logins.txt"
  else echo "  = $PREFIX/platform/caddy (already set, kept)"; fi

  # Read-only deploy key so the box can clone collective-infra
  if [ -z "$(current "$PREFIX/platform/deploy-key")" ]; then
    KEY="$OUT_DIR/deploy-key"; rm -f "$KEY" "$KEY.pub"
    ssh-keygen -q -t ed25519 -N "" -C "collective-${ENV}-box" -f "$KEY"
    put "$PREFIX/platform/deploy-key" "$(cat "$KEY")"
    if command -v gh >/dev/null && gh repo view "$GITHUB_REPO" >/dev/null 2>&1; then
      gh repo deploy-key add "$KEY.pub" --repo "$GITHUB_REPO" --title "collective-${ENV}-box" && echo "  + deploy key added to $GITHUB_REPO (read-only)"
    else
      echo "  ! add this READ-ONLY deploy key to github.com/$GITHUB_REPO → Settings → Deploy keys:"; cat "$KEY.pub"
    fi
    rm -f "$KEY"   # private half now lives only in Secrets Manager
  else echo "  = $PREFIX/platform/deploy-key (already set, kept)"; fi

  if [ -z "$(current "$PREFIX/platform/grafana")" ]; then
    echo "  ! $PREFIX/platform/grafana not set — Alloy will run but ship nothing. Fill it from Grafana Cloud later (README §3)."
  fi
fi

# ---------------------------------------------------------------- getpack app
if [ -z "$ONLY" ] || [ "$ONLY" = getpack ]; then
  echo "== getpack"
  if [ -z "$(current "$PREFIX/getpack/app")" ]; then
    PG=$(current "$PREFIX/platform/postgres"); VK=$(current "$PREFIX/platform/valkey")
    [ -n "$PG" ] && [ -n "$VK" ] || { echo "platform secrets missing — run without --only first"; exit 1; }
    GP_PW=$(jq -r .getpack_password <<<"$PG"); VK_PW=$(jq -r .password <<<"$VK")
    JWK=$(node -e '
      const {generateKeyPairSync,randomUUID}=require("crypto");
      const {privateKey}=generateKeyPairSync("ed25519");
      const j=privateKey.export({format:"jwk"}); j.kid=randomUUID(); j.alg="EdDSA"; j.use="sig";
      process.stdout.write(JSON.stringify([j]));')
    APP=$(jq -n \
      --arg db "postgresql://getpack:${GP_PW}@postgres:5432/getpack?schema=public&connection_limit=15" \
      --arg redis "redis://:${VK_PW}@valkey:6379/0" \
      --arg jwk "$JWK" --arg otp "$(pw 48)" --arg fek "$(openssl rand -base64 32)" --arg lookup "$(pw 48)" \
      --arg from "no-reply@${SES_DOMAIN}" --arg web "https://${GETPACK_WEB}" \
      '{
        NODE_ENV:"production", LOG_LEVEL:"info", LOG_PRETTY:"false", INTEGRATIONS_MODE:"real",
        DATABASE_URL:$db, REDIS_URL:$redis,
        AWS_ENDPOINT_URL:"", S3_FORCE_PATH_STYLE:"false", S3_KEY_PREFIX:"",
        TRUST_PROXY:"1", DOCS_ENABLED:"false",
        JWT_SIGNING_KEYS:$jwk, OTP_HMAC_SECRET:$otp, FIELD_ENCRYPTION_KEY:$fek, LOOKUP_HMAC_SECRET:$lookup,
        SES_FROM_ADDRESS:$from, SES_REGION:"ap-southeast-1",
        PDF_CHROMIUM_PATH:"/usr/bin/chromium",
        PUBLIC_WEB_URL:$web,
        SENTRY_DSN:"", FIREBASE_PROJECT_ID:"", LINE_LOGIN_CHANNEL_ID:"",
        LINE_MESSAGING_CHANNEL_ACCESS_TOKEN:"", LINE_MESSAGING_CHANNEL_SECRET:"", LINE_MESSAGING_CHANNEL_ID:"",
        VAPID_PUBLIC_KEY:"", VAPID_PRIVATE_KEY:"", VAPID_SUBJECT:"",
        THAIBULKSMS_API_KEY:"", THAIBULKSMS_API_SECRET:"", THAIBULKSMS_SENDER:""
      }')
    put "$PREFIX/getpack/app" "$APP"
    echo "  ! fill the empty third-party keys (LINE, ThaiBulkSMS, Firebase, VAPID, Sentry) in the console before the first real test"
  else echo "  = $PREFIX/getpack/app (already set, kept)"; fi
fi

echo "done. Local plaintext (move to a password manager, then delete): $OUT_DIR"
