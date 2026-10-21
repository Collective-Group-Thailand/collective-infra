#!/bin/bash
# getproperty after its secrets are rendered (bin/fetch-secrets.sh getproperty, deploys + hourly refresh):
#  1. The device CA for the API (signs gateway CSRs at /v1/device/bootstrap and …/certificate/renew): from the platform
#     secret collective/<env>/platform/device-ca (bin/render-device-ca.sh renders the same secret for EMQX and Caddy)
#     → DEVICE_CA_CERT / DEVICE_CA_KEY / DEVICE_CA_CHAIN (base64 PEM) in /run/collective/getproperty.env, replacing
#     any copy still in the product secret. Interim (box set up before T-6): when the platform secret is empty the
#     product secret's own DEVICE_CA_* stay, and MQTT_TLS__SERVER_PEM / MQTT_TLS__SERVER_KEY / MQTT_TLS__CA_PEM of
#     the product secret (the former getproperty/mqtt-tls secret, T-4) still feed EMQX's listener.
#  2. EMQX_AUTH_TOKEN for the API: the header token EMQX sends on its HTTP authn/authz calls to
#     /internal/emqx/{authn,authz} (platform secret collective/<env>/platform/emqx, key getproperty_auth_token).
#  3. The API's MQTT user on EMQX's internal listener (MQTT_USERNAME / MQTT_PASSWORD of the app secret):
#     bootstrap file for a fresh EMQX + an upsert through EMQX's REST API for a running one.
#  4. PDF_RENDER_REDIS_URL (getproperty-api PDF_RENDERER_MODE=queue, docs/pdf-render-queue.md): REDIS_URL of the app
#     secret with the platform's shared-queue logical DB (PLATFORM_QUEUES_VALKEY_DB = 15), so getproperty and getpack's
#     pdf-render consumer meet in the same DB whatever DB getproperty's own REDIS_URL names. A value in the product
#     secret wins but is reported when it names another DB. Harmless while the mode is `real` (the API ignores it).
# UNVERIFIED on a live box (written against the EMQX 5.8 and Caddy 2.10 documentation).
source "$(dirname "$0")/../../../bin/lib.sh"

USERS_DIR=/data/emqx/getproperty
mkdir -p "$USERS_DIR"
ENV_FILE="$RUN_DIR/getproperty.env"

ca=$(secret_json platform/device-ca)
if [ -n "$ca" ] && jq -e '.issuing_cert_pem and .issuing_key_pem and .ca_chain_pem' <<<"$ca" >/dev/null 2>&1; then
  b64() { jq -r ".$1" <<<"$ca" | base64 -w0; }
  {
    grep -v -E '^DEVICE_CA_(CERT|KEY|CHAIN)=' "$ENV_FILE" || true
    printf "DEVICE_CA_CERT='%s'\nDEVICE_CA_KEY='%s'\nDEVICE_CA_CHAIN='%s'\n" "$(b64 issuing_cert_pem)" "$(b64 issuing_key_pem)" "$(b64 ca_chain_pem)"
  } > "$ENV_FILE.next"
  chmod 0600 "$ENV_FILE.next"; mv "$ENV_FILE.next" "$ENV_FILE"
else
  log "WARN: ${SECRETS_PREFIX}/platform/device-ca not set — the API keeps DEVICE_CA_* from its own secret (interim)"
  tls=$(secret_json getproperty/app)
  if [ -n "$tls" ] && jq -e '.MQTT_TLS__SERVER_PEM and .MQTT_TLS__SERVER_KEY and .MQTT_TLS__CA_PEM' <<<"$tls" >/dev/null 2>&1; then
    install_device_tls "$(jq -r .MQTT_TLS__SERVER_PEM <<<"$tls")" "$(jq -r .MQTT_TLS__SERVER_KEY <<<"$tls")" \
      "$(jq -r .MQTT_TLS__CA_PEM <<<"$tls")" "getproperty/app MQTT_TLS__* (interim)"
  fi
fi

# The token EMQX's HTTP hooks present (x-emqx-auth-token); the API refuses /internal/emqx/* without it
token=$(grep -s '^GETPROPERTY_EMQX_AUTH_TOKEN=' "$RUN_DIR/platform.secrets.env" | cut -d= -f2- || true)
if [ -n "$token" ]; then
  { grep -v '^EMQX_AUTH_TOKEN=' "$ENV_FILE" || true; printf "EMQX_AUTH_TOKEN='%s'\n" "$token"; } > "$ENV_FILE.next"
  chmod 0600 "$ENV_FILE.next"; mv "$ENV_FILE.next" "$ENV_FILE"
else
  log "WARN: ${SECRETS_PREFIX}/platform/emqx has no getproperty_auth_token — EMQX refuses every gateway"
fi

# The shared pdf-render queue's Valkey DB (same host and password as REDIS_URL, DB PLATFORM_QUEUES_VALKEY_DB)
unquote() { sed -e "s/^'//" -e "s/'\$//"; }
pdf_url=$(grep -s '^PDF_RENDER_REDIS_URL=' "$ENV_FILE" | cut -d= -f2- | unquote || true)
redis_url=$(grep -s '^REDIS_URL=' "$ENV_FILE" | cut -d= -f2- | unquote || true)
if [ -n "$pdf_url" ]; then
  [[ "${pdf_url%%\?*}" =~ /${PLATFORM_QUEUES_VALKEY_DB}$ ]] \
    || log "WARN: PDF_RENDER_REDIS_URL in getproperty/app is not Valkey DB ${PLATFORM_QUEUES_VALKEY_DB} — getpack's pdf-render consumer will not see the jobs"
elif [[ "${redis_url%%\?*}" =~ ^(rediss?://[^/]+)(/[0-9]*)?$ ]]; then
  { cat "$ENV_FILE"; printf "PDF_RENDER_REDIS_URL='%s/%s'\n" "${BASH_REMATCH[1]}" "$PLATFORM_QUEUES_VALKEY_DB"; } > "$ENV_FILE.next"
  chmod 0600 "$ENV_FILE.next"; mv "$ENV_FILE.next" "$ENV_FILE"
else
  log "WARN: REDIS_URL missing or unparsable in getproperty/app — PDF_RENDER_REDIS_URL not set (PDF_RENDERER_MODE=queue would fall back to getproperty's own DB)"
fi

# The API's broker login (internal listener 1883; never published)
user=$(grep -s '^MQTT_USERNAME=' "$RUN_DIR/getproperty.env" | cut -d= -f2- | tr -d "'" || true)
pass=$(grep -s '^MQTT_PASSWORD=' "$RUN_DIR/getproperty.env" | cut -d= -f2- | tr -d "'" || true)
if [ -n "$user" ] && [ -n "$pass" ]; then
  jq -n --arg u "$user" --arg p "$pass" '[{user_id: $u, password: $p, is_superuser: false}]' > "$USERS_DIR/users.json.next"
  if ! cmp -s "$USERS_DIR/users.json.next" "$USERS_DIR/users.json"; then
    install -m 0600 -o 1000 -g 1000 "$USERS_DIR/users.json.next" "$USERS_DIR/users.json"
    if docker ps --format '{{.Names}}' | grep -q '^platform-emqx-1$'; then
      dash=$(grep -s "^EMQX_DASHBOARD_PASSWORD=" "$RUN_DIR/platform.secrets.env" | cut -d= -f2- || true)
      api="http://platform-emqx-1:18083/api/v5"
      curl_net() { docker run --rm --network collective curlimages/curl:8.10.1 -fsS "$@"; }
      token=$(curl_net -X POST "$api/login" -H 'Content-Type: application/json' \
                -d "$(jq -n --arg p "$dash" '{username: "admin", password: $p}')" | jq -r .token)
      body=$(jq -n --arg p "$pass" '{password: $p, is_superuser: false}')
      users="$api/authentication/password_based:built_in_database/users"
      curl_net -X PUT "$users/$user" -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d "$body" >/dev/null \
        || curl_net -X POST "$users" -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
             -d "$(jq -n --arg u "$user" --arg p "$pass" '{user_id: $u, password: $p, is_superuser: false}')" >/dev/null \
        || log "WARN: could not upsert the EMQX user $user (REST); it applies on the next fresh EMQX start"
    fi
    log "getproperty mqtt user $user updated"
  fi
  rm -f "$USERS_DIR/users.json.next"
else
  log "WARN: MQTT_USERNAME / MQTT_PASSWORD missing in ${SECRETS_PREFIX}/getproperty/app — ingest cannot connect"
fi
