#!/bin/bash
# Shared helpers for platform/bin/*. Source, don't execute.
set -euo pipefail

PLATFORM_ENV_FILE=/etc/collective/platform.env
RUN_DIR=/run/collective          # tmpfs: rendered secrets (never on disk)
STATE_DIR=/var/lib/collective    # persisted: current/previous image tags per product
LOG_DIR=/var/log/collective

# shellcheck disable=SC1090
[ -f "$PLATFORM_ENV_FILE" ] && source "$PLATFORM_ENV_FILE"
: "${COLLECTIVE_ENV:?missing COLLECTIVE_ENV — run user-data bootstrap first}"
: "${AWS_REGION:?}" "${SECRETS_PREFIX:?}" "${PLATFORM_DIR:=/opt/collective/platform}"

mkdir -p "$RUN_DIR" "$STATE_DIR" "$LOG_DIR"
chmod 0700 "$RUN_DIR"

log() { printf '%s [%s] %s\n' "$(date -Is)" "${0##*/}" "$*" | tee -a "$LOG_DIR/platform.log" >&2; }
die() { log "ERROR: $*"; exit 1; }

secret_json() { # secret_json <name-under-prefix>  → prints SecretString or empty
  aws secretsmanager get-secret-value --region "$AWS_REGION" --secret-id "${SECRETS_PREFIX}/$1" \
    --query SecretString --output text 2>/dev/null || true
}

# json_to_env <json> [PREFIX_]  → KEY=value lines (keys uppercased, PREFIX_ prepended)
json_to_env() {
  local json="$1" prefix="${2:-}"
  printf '%s' "$json" | jq -r --arg p "$prefix" '
    to_entries[] | select(.key | startswith("_") | not)
    | "\($p)\(.key | ascii_upcase)=\(.value | tostring | @sh)"'
}

# Non-secret per-environment compose knobs (memory limits, modes) committed in platform/env/<env>.env. Later
# --env-file arguments win, so the order is: box facts (platform.env) → env knobs → secrets / deploy state.
env_knobs_args() {
  local f="$PLATFORM_DIR/env/${COLLECTIVE_ENV}.env"
  [ -f "$f" ] && printf -- '--env-file\n%s\n' "$f"
  return 0
}

compose_platform() {
  local knobs; mapfile -t knobs < <(env_knobs_args)
  docker compose --project-directory "$PLATFORM_DIR" \
    --env-file "$PLATFORM_ENV_FILE" "${knobs[@]}" --env-file "$RUN_DIR/platform.secrets.env" "$@"
}

compose_product() { # compose_product <product> <args…>
  local product="$1"; shift
  local knobs; mapfile -t knobs < <(env_knobs_args)
  docker compose --project-name "$product" --project-directory "$PLATFORM_DIR/products/$product" \
    --env-file "$PLATFORM_ENV_FILE" "${knobs[@]}" --env-file "$STATE_DIR/$product.env" "$@"
}

# --- Device CA (collective/<env>/platform/device-ca, getproperty-api D-235 / blueprint T-6) -----------------------
# EMQX's device listener (8883, mutual TLS) and Caddy's DEVICE_HOST trust pool use the platform-owned device CA.
DEVICE_TLS_DIR=/data/emqx/certs/device
DEVICE_CA_SITE_FILE="$PLATFORM_DIR/caddy/sites/device-ca.pem"

# install_device_tls <server_pem> <server_key> <ca_pem> <source label>
#   server_pem = the broker certificate for MQTT_HOST (leaf first, then any intermediate), issued from the device CA;
#   ca_pem     = the CA chain that verifies gateway client certificates (the gateways' caChainPem).
# Writes the files EMQX reads, gives Caddy the trust pool (render-sites.sh un-skips the device host), and restarts
# EMQX's ssl listener when anything changed.
install_device_tls() {
  local src="$4" changed=0 name site mode
  local -A content=([server.pem]="$1" [server.key]="$2" [ca.pem]="$3")
  mkdir -p "$DEVICE_TLS_DIR"
  for name in server.pem server.key ca.pem; do
    printf '%s\n' "${content[$name]}" > "$DEVICE_TLS_DIR/$name.next"
    if ! cmp -s "$DEVICE_TLS_DIR/$name.next" "$DEVICE_TLS_DIR/$name"; then
      install -m 0600 -o 1000 -g 1000 "$DEVICE_TLS_DIR/$name.next" "$DEVICE_TLS_DIR/$name"; changed=1
    fi
    rm -f "$DEVICE_TLS_DIR/$name.next"
  done
  # Caddy: the CA chain (DEVICE_HOST client_auth trust pool) and the broker certificate (MQTT_HOST, the WSS fallback
  # wss://<MQTT_HOST>/mqtt — same certificate as 8883, so gateways verify both against their caChainPem).
  local sites_changed=0 pair
  for pair in "ca.pem:device-ca.pem:0644" "server.pem:device-broker.pem:0600" "server.key:device-broker.key:0600"; do
    IFS=: read -r name site mode <<<"$pair"
    if ! cmp -s "$DEVICE_TLS_DIR/$name" "$PLATFORM_DIR/caddy/sites/$site"; then
      install -m "$mode" "$DEVICE_TLS_DIR/$name" "$PLATFORM_DIR/caddy/sites/$site"; sites_changed=1
    fi
  done
  if [ "$sites_changed" = 1 ]; then
    "$PLATFORM_DIR/bin/render-sites.sh" || log "WARN: render-sites failed after the device CA changed"
  fi
  if [ "$changed" = 1 ]; then
    log "device TLS updated from $src"
    if docker ps --format '{{.Names}}' | grep -q '^platform-emqx-1$'; then
      compose_platform exec -T emqx emqx ctl listeners restart ssl:default >/dev/null || compose_platform restart emqx
    fi
  fi
}

# EMQX refuses to start on a missing certfile: a throwaway self-signed placeholder until the real CA is filled in
# (gateways cannot connect to it; Caddy's device host stays skipped because device-ca.pem is not written).
ensure_device_tls_placeholder() {
  [ -s "$DEVICE_TLS_DIR/server.pem" ] && return 0
  mkdir -p "$DEVICE_TLS_DIR"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 -subj "/CN=placeholder" \
    -keyout "$DEVICE_TLS_DIR/server.key" -out "$DEVICE_TLS_DIR/server.pem" 2>/dev/null
  cp "$DEVICE_TLS_DIR/server.pem" "$DEVICE_TLS_DIR/ca.pem"
  chown -R 1000:1000 "$DEVICE_TLS_DIR"; chmod 0600 "$DEVICE_TLS_DIR/server.key"
  log "device TLS: placeholder certificate (collective/${COLLECTIVE_ENV}/platform/device-ca not filled yet)"
}
