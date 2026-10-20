#!/bin/bash
# Pull platform + product secrets from Secrets Manager into /run/collective/*.env (tmpfs, root:0600).
# Usage: fetch-secrets.sh [platform|<product>|all]   (default: all)
source "$(dirname "$0")/lib.sh"

fetch_platform() {
  local out="$RUN_DIR/platform.secrets.env.tmp"
  : > "$out"; chmod 0600 "$out"

  local pg valkey emqx grafana caddy
  pg=$(secret_json platform/postgres);   [ -n "$pg" ]     || die "secret ${SECRETS_PREFIX}/platform/postgres is empty"
  valkey=$(secret_json platform/valkey); [ -n "$valkey" ] || die "secret ${SECRETS_PREFIX}/platform/valkey is empty"
  emqx=$(secret_json platform/emqx);     [ -n "$emqx" ]   || die "secret ${SECRETS_PREFIX}/platform/emqx is empty"
  grafana=$(secret_json platform/grafana)
  caddy=$(secret_json platform/caddy)

  {
    echo "POSTGRES_SUPERUSER_PASSWORD=$(jq -r .superuser_password <<<"$pg")"
    echo "GETPACK_DB_PASSWORD=$(jq -r .getpack_password <<<"$pg")"
    echo "GETPROPERTY_DB_PASSWORD=$(jq -r .getproperty_password <<<"$pg")"
    echo "GETPOP_DB_PASSWORD=$(jq -r .getpop_password <<<"$pg")"
    echo "VALKEY_PASSWORD=$(jq -r .password <<<"$valkey")"
    echo "EMQX_DASHBOARD_PASSWORD=$(jq -r .dashboard_password <<<"$emqx")"
    echo "CADDY_ACME_EMAIL=$(jq -r '.acme_email // "ops@example.invalid"' <<<"${caddy:-{\}}")"
    if [ -n "$grafana" ]; then json_to_env "$grafana" GRAFANA_; else
      log "WARN: platform/grafana secret empty — Alloy will fail to ship; set it and re-run"
      printf 'GRAFANA_%s=\n' PROMETHEUS_URL PROMETHEUS_USER LOKI_URL LOKI_USER TEMPO_URL TEMPO_USER API_KEY
    fi
  } >> "$out"
  mv "$out" "$RUN_DIR/platform.secrets.env"

  # Caddy basic-auth users for the platform host ("basic_auth_users": ["ops:$2a$14$…"])
  if [ -n "$caddy" ] && jq -e '.basic_auth_users' <<<"$caddy" >/dev/null; then
    jq -r '.basic_auth_users[] | sub(":"; " ")' <<<"$caddy" > "$PLATFORM_DIR/caddy/sites/_platform_users"
  else
    [ -f "$PLATFORM_DIR/caddy/sites/_platform_users" ] || echo "ops \$2a\$14\$invalidinvalidinvalidinvalidinvalidinvalidinvalidinvali" > "$PLATFORM_DIR/caddy/sites/_platform_users"
  fi
  log "platform secrets rendered"
}

fetch_product() {
  local product="$1" json out="$RUN_DIR/$1.env.tmp"
  json=$(secret_json "$product/app")
  [ -n "$json" ] || die "secret ${SECRETS_PREFIX}/${product}/app is empty"
  jq -e '._placeholder' <<<"$json" >/dev/null && die "secret ${SECRETS_PREFIX}/${product}/app still has the placeholder value"
  : > "$out"; chmod 0600 "$out"
  json_to_env "$json" >> "$out"
  mv "$out" "$RUN_DIR/$product.env"
  log "$product secrets rendered ($(wc -l < "$RUN_DIR/$product.env") keys)"
}

case "${1:-all}" in
  platform) fetch_platform ;;
  all) fetch_platform; for p in getpack getproperty getpop; do [ -d "$PLATFORM_DIR/products/$p" ] && fetch_product "$p" || true; done ;;
  *) fetch_product "$1" ;;
esac
