#!/bin/bash
# getproperty after its secrets are rendered (bin/fetch-secrets.sh getproperty, deploys + hourly refresh):
#  1. EMQX device listener TLS (getproperty-api docs/deployment.md §5): collective/<env>/getproperty/mqtt-tls =
#     {"server_pem", "server_key", "ca_pem"} — the broker's server certificate issued from the getproperty device
#     CA (`pnpm device:broker-cert` in getproperty-api) and the CA that verifies gateway client certificates.
#     → /data/emqx/certs/getproperty/{server.pem,server.key,ca.pem}; the ssl listener restarts when they change.
#  2. The device CA for Caddy's DEVICE_HOST client_auth → caddy/sites/getproperty-device-ca.pem, then
#     render-sites.sh (the getproperty site is skipped until this file exists).
#  3. The API's MQTT user on EMQX's internal listener (MQTT_USERNAME / MQTT_PASSWORD of the app secret):
#     bootstrap file for a fresh EMQX + an upsert through EMQX's REST API for a running one.
# UNVERIFIED on a live box (written against the EMQX 5.8 and Caddy 2.10 documentation).
source "$(dirname "$0")/../../../bin/lib.sh"

TLS_DIR=/data/emqx/certs/getproperty
USERS_DIR=/data/emqx/getproperty
mkdir -p "$TLS_DIR" "$USERS_DIR"
changed=0

tls=$(secret_json getproperty/mqtt-tls)
if [ -n "$tls" ] && jq -e '.server_pem and .server_key and .ca_pem' <<<"$tls" >/dev/null 2>&1; then
  for pair in server_pem:server.pem server_key:server.key ca_pem:ca.pem; do
    key=${pair%%:*}; file=${pair#*:}
    jq -r ".$key" <<<"$tls" > "$TLS_DIR/$file.next"
    if ! cmp -s "$TLS_DIR/$file.next" "$TLS_DIR/$file"; then
      install -m 0600 -o 1000 -g 1000 "$TLS_DIR/$file.next" "$TLS_DIR/$file"; changed=1
    fi
    rm -f "$TLS_DIR/$file.next"
  done
  if ! cmp -s "$TLS_DIR/ca.pem" "$PLATFORM_DIR/caddy/sites/getproperty-device-ca.pem"; then
    install -m 0644 "$TLS_DIR/ca.pem" "$PLATFORM_DIR/caddy/sites/getproperty-device-ca.pem"
    "$PLATFORM_DIR/bin/render-sites.sh"
  fi
  if [ "$changed" = 1 ] && docker ps --format '{{.Names}}' | grep -q '^platform-emqx-1$'; then
    compose_platform exec -T emqx emqx ctl listeners restart ssl:default >/dev/null || compose_platform restart emqx
    log "getproperty mqtt tls updated"
  fi
else
  log "WARN: ${SECRETS_PREFIX}/getproperty/mqtt-tls not set — EMQX's device listener and the device host stay down"
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
