#!/bin/bash
# Render the platform device CA (Secrets Manager collective/<env>/platform/device-ca; getproperty-api D-235, blueprint
# T-6) for its three consumers on the box:
#   1. EMQX device listener (8883 mutual TLS; also the TLS of wss://<MQTT_HOST>/mqtt through Caddy) → /data/emqx/certs/device
#   2. Caddy's DEVICE_HOST client_auth trust pool → caddy/sites/device-ca.pem (+ render-sites.sh)
#   3. getproperty-api (signs gateway CSRs) → DEVICE_CA_* in /run/collective/getproperty.env, written by
#      products/getproperty/hooks/post-secrets.sh from the same secret
# Secret JSON (values are PEM text; issue the broker certificate with `pnpm device:broker-cert` in getproperty-api):
#   {"ca_chain_pem": "<root [+ issuing] — the gateways' caChainPem>",
#    "issuing_cert_pem": "<CA certificate that signs gateway CSRs>", "issuing_key_pem": "<its EC P-256 key>",
#    "broker_cert_pem": "<server certificate for MQTT_HOST, leaf first + issuing>", "broker_key_pem": "<its key>"}
# Called by fetch-secrets.sh (platform | all), i.e. at bootstrap, on every deploy and hourly (secrets-refresh.timer).
source "$(dirname "$0")/lib.sh"

json=$(secret_json platform/device-ca)
if [ -n "$json" ] && jq -e '.ca_chain_pem and .broker_cert_pem and .broker_key_pem' <<<"$json" >/dev/null 2>&1; then
  install_device_tls "$(jq -r .broker_cert_pem <<<"$json")" "$(jq -r .broker_key_pem <<<"$json")" \
    "$(jq -r .ca_chain_pem <<<"$json")" "platform/device-ca"
  exit 0
fi

# Interim (until the device CA moves into the platform secret on a box set up before T-6): a product hook may install
# the listener files from its own secret. Never leave EMQX without a certfile.
ensure_device_tls_placeholder
log "WARN: ${SECRETS_PREFIX}/platform/device-ca not set — gateways cannot connect until it is (README §3)"
