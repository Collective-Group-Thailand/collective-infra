#!/bin/bash
# getproperty after its secrets are rendered (bin/fetch-secrets.sh getproperty, deploys + hourly refresh):
#  1. The device CA for the API (signs gateway CSRs at /v1/device/bootstrap and …/certificate/renew): from the platform
#     secret collective/<env>/platform/device-ca (bin/render-device-ca.sh renders the same secret for EMQX and Caddy)
#     → DEVICE_CA_CERT / DEVICE_CA_KEY / DEVICE_CA_CHAIN (base64 PEM) in /run/collective/getproperty.env, replacing
#     any copy still in the product secret. Interim (box set up before T-6): when the platform secret is empty the
#     product secret's own DEVICE_CA_* stay, and the legacy getproperty/mqtt-tls secret still feeds EMQX's listener.
#  2. The API's MQTT user on EMQX's internal listener (MQTT_USERNAME / MQTT_PASSWORD of the app secret):
#     bootstrap file for a fresh EMQX + an upsert through EMQX's REST API for a running one.
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
  tls=$(secret_json getproperty/mqtt-tls)
  if [ -n "$tls" ] && jq -e '.server_pem and .server_key and .ca_pem' <<<"$tls" >/dev/null 2>&1; then
    install_device_tls "$(jq -r .server_pem <<<"$tls")" "$(jq -r .server_key <<<"$tls")" "$(jq -r .ca_pem <<<"$tls")" \
      "getproperty/mqtt-tls (interim)"
  fi
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
