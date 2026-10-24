#!/usr/bin/env bash
# getproperty's secrets for one environment. Run on a LAPTOP after `make apply ENV=<env>` and after
# platform/bin/init-secrets.sh <env> (it needs collective/<env>/platform/{postgres,valkey}):
#
#   AWS_PROFILE=collective bash platform/products/getproperty/init-secrets.sh uat
#
# Writes (never overwrites a secret that already holds a value — rotate deliberately in the console):
#   collective/<env>/platform/device-ca   the IoT device CA (getproperty-api D-235/D-245): root → issuing CA → broker
#                                         server certificate for MQTT_HOST (EMQX 8883 + wss://<MQTT_HOST>/mqtt)
#   collective/<env>/platform/emqx        + getproperty_auth_token (header of EMQX's HTTP authn/authz calls); the
#                                         existing keys are kept
#   collective/<env>/getproperty/app      the one product secret: API keys unprefixed, WEB__… / LIFF__… per front end
#                                         (getproperty-api docs/deployment.md §3)
# Provider keys the API requires in production (LINE, SMS) are written as `REPLACE_ME…` placeholders so the API
# boots; replace them before testing those features. LIFF__NEXT_PUBLIC_LIFF_ID must be the real LIFF id of this
# environment's LINE Login channel before the first liff deploy (the liff container refuses to start without it).
# Local plaintext copies go to ~/.collective-secrets/<env>/getproperty/ — move them to the password manager.
set -euo pipefail

ENV="${1:?usage: init-secrets.sh <uat|prod>}"
REGION="${AWS_REGION:-ap-southeast-7}"
PREFIX="collective/${ENV}"
OUT_DIR="${HOME}/.collective-secrets/${ENV}/getproperty"
mkdir -p "$OUT_DIR"; chmod 700 "$OUT_DIR"

case "$ENV" in
  uat)  H="uat-"; SES_DOMAIN="uat.getproperty.app"; BADGE=uat ;;
  prod) H="";     SES_DOMAIN="getproperty.app";     BADGE=prod ;;
  *) echo "env must be uat or prod"; exit 1 ;;
esac
D=getproperty.app
OWNER="${H}app.$D" STAFF="${H}staff.$D" ADMIN="${H}admin.$D" LIFF="${H}liff.$D"
API="${H}api.$D" DEVICE="${H}device.$D" MQTT="${H}mqtt.$D"

for c in aws jq; do command -v "$c" >/dev/null || { echo "missing: $c"; exit 1; }; done
# OpenSSL 3 (macOS ships LibreSSL, which lacks Ed25519 keys and -addext): Homebrew's openssl@3 when present
for o in openssl /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl; do
  if command -v "$o" >/dev/null && "$o" version | grep -q '^OpenSSL 3'; then OPENSSL="$o"; break; fi
done
[ -n "${OPENSSL:-}" ] || { echo "needs OpenSSL 3 (macOS: brew install openssl@3)"; exit 1; }
openssl() { "$OPENSSL" "$@"; }
acct=$(aws sts get-caller-identity --query Account --output text)
expected=$(cat "$(dirname "$0")/../../../envs/account.txt" 2>/dev/null || true)
[ -z "$expected" ] || [ "$acct" = "$expected" ] || { echo "WRONG ACCOUNT $acct (expected $expected)"; exit 1; }
echo "account $acct  env $ENV  hosts *.$D"

current() {
  local v
  v=$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$1" --query SecretString --output text 2>/dev/null || true)
  if [ -z "$v" ] || printf '%s' "$v" | jq -e '._placeholder?' >/dev/null 2>&1; then echo ""; else printf '%s' "$v"; fi
}
write() { aws secretsmanager put-secret-value --region "$REGION" --secret-id "$1" --secret-string "$2" >/dev/null; }
hex() { openssl rand -hex "${1:-32}"; }
b64key() { openssl rand -base64 32; }   # 32 random bytes, base64

PG=$(current "$PREFIX/platform/postgres"); VK=$(current "$PREFIX/platform/valkey")
[ -n "$PG" ] && [ -n "$VK" ] || { echo "run platform/bin/init-secrets.sh $ENV first (platform/postgres, platform/valkey)"; exit 1; }

# ---------------------------------------------------------------- device CA (platform-owned)
echo "== $PREFIX/platform/device-ca"
if [ -z "$(current "$PREFIX/platform/device-ca")" ]; then
  T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  ec() { openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$1" 2>/dev/null; }
  ec "$T/root.key"; ec "$T/issuing.key"; ec "$T/broker.key"
  openssl req -x509 -new -key "$T/root.key" -sha256 -days 7300 -subj "/O=Collective Group (Thailand)/CN=Collective Device Root CA ($ENV)" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" -out "$T/root.pem"
  openssl req -new -key "$T/issuing.key" -subj "/O=Collective Group (Thailand)/CN=getproperty Device Issuing CA ($ENV)" -out "$T/issuing.csr"
  printf 'basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign,digitalSignature\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid\n' > "$T/issuing.ext"
  openssl x509 -req -in "$T/issuing.csr" -CA "$T/root.pem" -CAkey "$T/root.key" -CAcreateserial -sha256 -days 3650 \
    -extfile "$T/issuing.ext" -out "$T/issuing.pem" 2>/dev/null
  openssl req -new -key "$T/broker.key" -subj "/CN=$MQTT" -out "$T/broker.csr"
  printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:%s\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid\n' "$MQTT" > "$T/broker.ext"
  openssl x509 -req -in "$T/broker.csr" -CA "$T/issuing.pem" -CAkey "$T/issuing.key" -CAcreateserial -sha256 -days 397 \
    -extfile "$T/broker.ext" -out "$T/broker.pem" 2>/dev/null
  openssl verify -CAfile "$T/root.pem" -untrusted "$T/issuing.pem" "$T/broker.pem" >/dev/null
  CA=$(jq -n --rawfile chain <(cat "$T/issuing.pem" "$T/root.pem") --rawfile ic "$T/issuing.pem" --rawfile ik "$T/issuing.key" \
             --rawfile bc <(cat "$T/broker.pem" "$T/issuing.pem") --rawfile bk "$T/broker.key" \
             '{ca_chain_pem:$chain, issuing_cert_pem:$ic, issuing_key_pem:$ik, broker_cert_pem:$bc, broker_key_pem:$bk}')
  write "$PREFIX/platform/device-ca" "$CA"
  # The root key signs nothing day to day: keep it offline (password manager), never on a box or in Secrets Manager.
  install -m 600 "$T/root.key" "$OUT_DIR/device-root-ca.key"; install -m 644 "$T/root.pem" "$OUT_DIR/device-root-ca.pem"
  echo "  + device CA (root key → $OUT_DIR/device-root-ca.key — move it offline); broker cert for $MQTT, 397 days"
else echo "  = kept"; fi

# ---------------------------------------------------------------- EMQX hook token (merged into platform/emqx)
echo "== $PREFIX/platform/emqx getproperty_auth_token"
EM=$(current "$PREFIX/platform/emqx")
[ -n "$EM" ] || { echo "platform/emqx is empty — run platform/bin/init-secrets.sh $ENV first"; exit 1; }
if [ -z "$(jq -r '.getproperty_auth_token // ""' <<<"$EM")" ]; then
  write "$PREFIX/platform/emqx" "$(jq -c --arg t "$(hex 32)" '. + {getproperty_auth_token:$t}' <<<"$EM")"
  echo "  + added"
else echo "  = kept"; fi

# ---------------------------------------------------------------- product secret
echo "== $PREFIX/getproperty/app"
if [ -z "$(current "$PREFIX/getproperty/app")" ]; then
  T2=$(mktemp -d)
  openssl genpkey -algorithm ED25519 -out "$T2/jwt.key"
  openssl ecparam -name prime256v1 -genkey -noout -out "$T2/vapid.pem" 2>/dev/null
  # VAPID: raw public point (65 bytes) and private scalar (32 bytes), base64url — the web-push format
  vpub=$(openssl ec -in "$T2/vapid.pem" -pubout -outform DER 2>/dev/null | tail -c 65 | base64 | tr '+/' '-_' | tr -d '=\n')
  vpriv=$(openssl ec -in "$T2/vapid.pem" -outform DER 2>/dev/null | head -c 39 | tail -c 32 | base64 | tr '+/' '-_' | tr -d '=\n')
  PGPW=$(jq -r .getproperty_password <<<"$PG"); VKPW=$(jq -r .password <<<"$VK")
  APP=$(jq -n \
    --arg db "postgresql://getproperty:${PGPW}@postgres:5432/getproperty" \
    --arg redis "redis://:${VKPW}@valkey:6379/2" \
    --arg mqttpw "$(hex 24)" --arg fek "$(b64key)" --arg fhk "$(b64key)" \
    --arg jwt "$(base64 < "$T2/jwt.key" | tr -d '\n')" --arg kid "gp-${ENV}-$(date +%Y%m)" \
    --arg vpub "$vpub" --arg vpriv "$vpriv" \
    --arg api "https://$API" --arg owner "https://$OWNER" --arg staff "https://$STAFF" --arg liff "https://$LIFF" \
    --arg mqtt "mqtts://$MQTT:8883" --arg mqttws "wss://$MQTT/mqtt" \
    --arg from "getproperty <no-reply@${SES_DOMAIN}>" \
    --arg oh "$OWNER" --arg sh "$STAFF" --arg ah "$ADMIN" --arg badge "$BADGE" \
    --arg assets "https://collective-${ENV}-getproperty-assets.s3.${REGION}.amazonaws.com" \
    '{
      DATABASE_URL:$db, DATABASE_APP_ROLE:"gp_app", DATABASE_PLATFORM_ROLE:"gp_platform",
      REDIS_URL:$redis,
      MQTT_USERNAME:"getproperty-api", MQTT_PASSWORD:$mqttpw,
      PUBLIC_API_BASE_URL:$api, PUBLIC_WEB_APP_URL:$owner, PUBLIC_STAFF_APP_URL:$staff, PUBLIC_RESIDENT_APP_URL:$liff,
      MQTT_PUBLIC_URL:$mqtt, MQTT_PUBLIC_WS_URL:$mqttws, DEVICE_PUBLIC_BASE_URL:"",
      FIELD_ENCRYPTION_KEY:$fek, FIELD_HASH_KEY:$fhk,
      AUTH_JWT_PRIVATE_KEY:$jwt, AUTH_JWT_KID:$kid, AUTH_JWT_PREVIOUS_KEYS:"",
      OTA_SIGNING_PUBLIC_KEYS:"",
      LINE_LOGIN_CHANNEL_IDS:"REPLACE_ME_LINE_LOGIN_CHANNEL_ID", LINE_MESSAGING_ACCESS_TOKEN:"REPLACE_ME_LINE_MESSAGING_TOKEN",
      SMS_API_URL:"https://sms.invalid/REPLACE_ME", SMS_API_KEY:"REPLACE_ME", SMS_API_SECRET:"REPLACE_ME",
      SES_FROM_ADDRESS:$from,
      WEB_PUSH_VAPID_PUBLIC_KEY:$vpub, WEB_PUSH_VAPID_PRIVATE_KEY:$vpriv, WEB_PUSH_SUBJECT:"mailto:ops@getproperty.app",
      SLIP_VERIFY_API_KEY:"", AI_GATEWAY_URL:"", AI_GATEWAY_API_KEY:"", SENTRY_DSN:"",
      DOCS_ENABLED:"false",
      WEB__OWNER_HOST:$oh, WEB__STAFF_HOST:$sh, WEB__ADMIN_HOST:$ah,
      WEB__NEXT_PUBLIC_ENV_BADGE:$badge, WEB__NEXT_PUBLIC_ASSET_BASE_URL:$assets,
      WEB__NEXT_PUBLIC_VAPID_PUBLIC_KEY:$vpub,
      LIFF__NEXT_PUBLIC_LIFF_ID:"", LIFF__NEXT_PUBLIC_ENV_BADGE:$badge, LIFF__NEXT_PUBLIC_ASSET_BASE_URL:$assets,
      LIFF__NEXT_PUBLIC_VAPID_PUBLIC_KEY:$vpub, LIFF__APP_ORIGIN:$liff
    }')
  write "$PREFIX/getproperty/app" "$APP"
  printf '%s\n' "$APP" > "$OUT_DIR/app.json"; chmod 600 "$OUT_DIR/app.json"
  rm -rf "$T2"
  echo "  + written (copy: $OUT_DIR/app.json)"
  echo "  ! replace before testing: LINE_* , SMS_* ; set LIFF__NEXT_PUBLIC_LIFF_ID before the first liff deploy"
else echo "  = kept"; fi

echo "done."
