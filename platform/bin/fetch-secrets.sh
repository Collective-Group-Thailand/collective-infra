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
    echo "GETBUILD_DB_PASSWORD=$(jq -r .getbuild_password <<<"$pg")"
    echo "VALKEY_PASSWORD=$(jq -r .password <<<"$valkey")"
    echo "EMQX_DASHBOARD_PASSWORD=$(jq -r .dashboard_password <<<"$emqx")"
    # Shared header token of EMQX's HTTP authn/authz calls to getproperty-api (/internal/emqx/*, D-235); the
    # getproperty hook hands the same value to the API as EMQX_AUTH_TOKEN. Empty = every gateway is refused.
    echo "GETPROPERTY_EMQX_AUTH_TOKEN=$(jq -r '.getproperty_auth_token // ""' <<<"$emqx")"
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

  # Device CA → EMQX device listener, Caddy device-host trust pool (getproperty-api D-235)
  "$PLATFORM_DIR/bin/render-device-ca.sh" || log "WARN: render-device-ca failed"
}

fetch_product() {
  local product="$1" json out="$RUN_DIR/$1.env.tmp"
  json=$(secret_json "$product/app")
  [ -n "$json" ] || die "secret ${SECRETS_PREFIX}/${product}/app is empty"
  jq -e '._placeholder' <<<"$json" >/dev/null && die "secret ${SECRETS_PREFIX}/${product}/app still has the placeholder value"

  # One secret per product per env (locked 2026-10-21): collective/<env>/<product>/app. Keys of the form
  # <COMPONENT>__<KEY> belong to one component only (getproperty: WEB__…, LIFF__…, MQTT_TLS__…) and never reach the
  # product's main env file, so a front end still never receives the API's secrets and the API never gets the front
  # ends' session keys.
  : > "$out"; chmod 0600 "$out"
  json_to_env "$(jq 'with_entries(select((.key | index("__")) as $i | $i == null or $i == 0))' <<<"$json")" >> "$out"
  mv "$out" "$RUN_DIR/$product.env"
  log "$product secrets rendered ($(wc -l < "$RUN_DIR/$product.env") keys)"

  # Per-component env files: /run/collective/<product>-<component>.env, the prefix stripped (WEB__SESSION_SECRET →
  # SESSION_SECRET in <product>-web.env; MQTT_TLS__CA_PEM → CA_PEM in <product>-mqtt-tls.env). Rendered for every
  # prefix present and for every `env_file: /run/collective/<product>-<component>.env` the compose file asks for
  # (an empty file when the secret has no key for it — compose needs the file to exist).
  local compose="$PLATFORM_DIR/products/$product/docker-compose.yml" comp prefix cjson wanted
  wanted=$(grep -oE "/run/collective/${product}-[a-z0-9-]+\.env" "$compose" 2>/dev/null | sed -E "s#.*/${product}-(.*)\.env#\1#" | sort -u || true)
  for comp in $( { jq -r 'keys[] | (index("__")) as $i | select($i != null and $i > 0) | .[:$i] | ascii_downcase | gsub("_"; "-")' <<<"$json"
                   printf '%s\n' $wanted; } | sort -u); do
    if ! [[ "$comp" =~ ^[a-z][a-z0-9-]*$ ]]; then log "WARN: $product: ignoring keys with component prefix '$comp'"; continue; fi
    prefix="$(tr 'a-z-' 'A-Z_' <<<"$comp")__"
    cjson=$(jq --arg p "$prefix" 'with_entries(select((.key | startswith($p)) and (.key | length) > ($p | length)) | .key |= .[($p | length):])' <<<"$json")
    out="$RUN_DIR/$product-$comp.env.tmp"; : > "$out"; chmod 0600 "$out"
    json_to_env "$cjson" >> "$out"
    mv "$out" "$RUN_DIR/$product-$comp.env"
    if [ "$cjson" = "{}" ]; then
      log "WARN: ${SECRETS_PREFIX}/${product}/app has no ${prefix}* keys — $product-$comp.env rendered empty"
    else
      log "$product-$comp secrets rendered ($(wc -l < "$RUN_DIR/$product-$comp.env") keys)"
    fi
  done

  # Product hook (optional): products/<product>/hooks/post-secrets.sh — e.g. getproperty's MQTT TLS files.
  local hook="$PLATFORM_DIR/products/$product/hooks/post-secrets.sh"
  if [ -x "$hook" ]; then "$hook" || log "WARN: $product post-secrets hook failed"; fi
}

case "${1:-all}" in
  platform) fetch_platform ;;
  all) fetch_platform; for p in getpack getproperty getbuild; do [ -d "$PLATFORM_DIR/products/$p" ] && fetch_product "$p" || true; done ;;
  *) fetch_product "$1" ;;
esac
