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

# Valkey logical databases (one Valkey per box, `--databases 16`): each product keeps its own queues and cache in its
# own DB 0–14 (getproperty 2 — its REDIS_URL; getpack and getbuild the DB of their REDIS_URL); DB 15 is reserved for
# queues shared between products (BullMQ prefix `collective`): `pdf-render` (getproperty-api docs/pdf-render-queue.md
# — every producer and getpack's consumer use exactly this DB). No product may use 15 for its own keys.
PLATFORM_QUEUES_VALKEY_DB=15

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
  # config hashes → `collective.config` labels (see docker-compose.yml header)
  h() { (cd "$PLATFORM_DIR" && cat "$@" 2>/dev/null) | sha256sum | cut -c1-12; }
  export CFG_CADDY=$(h Caddyfile) CFG_ALLOY=$(h alloy/config.alloy) CFG_CLAMAV=$(h clamav/clamd.conf) CFG_EMQX=$(h emqx/platform-acl.conf) \
         CFG_POSTGRES=$(h postgres/postgresql.conf postgres/pg_hba.conf postgres/pgbackrest.conf)
  # Alloy (profile "observability") runs only once Grafana Cloud credentials exist
  if grep -qE "^GRAFANA_PROMETHEUS_URL='?https" "$RUN_DIR/platform.secrets.env" 2>/dev/null; then
    export COMPOSE_PROFILES=observability
  else
    unset COMPOSE_PROFILES
  fi
  local knobs; mapfile -t knobs < <(env_knobs_args)
  docker compose --project-directory "$PLATFORM_DIR" \
    --env-file "$PLATFORM_ENV_FILE" "${knobs[@]}" --env-file "$RUN_DIR/platform.secrets.env" "$@"
}

compose_product() { # compose_product <product> <args…>
  # env files: platform.env · <product>.env (API_TAG/WEB_TAG state) · <product>.hosts.env (render-sites.sh)
  local product="$1"; shift
  local files=(--env-file "$PLATFORM_ENV_FILE") f knobs
  mapfile -t knobs < <(env_knobs_args); files+=("${knobs[@]}")
  for f in "$STATE_DIR/$product.env" "$STATE_DIR/$product.hosts.env"; do
    [ -f "$f" ] && files+=(--env-file "$f")
  done
  docker compose --project-name "$product" --project-directory "$PLATFORM_DIR/products/$product" "${files[@]}" "$@"
}

# component_services <product> <component> → compose services running the <product>/<component> image
# (profile-only services such as `migrate` are excluded because `config` skips inactive profiles)
component_services() {
  compose_product "$1" config --format json \
    | jq -r --arg img "/$1/$2:" '.services | to_entries[] | select(.value.image | contains($img)) | .key'
}

# state_get <product> <KEY> / state_set <product> <KEY> <value>  (KEY=value lines in $STATE_DIR/<product>.env)
state_get() { grep -s "^$2=" "$STATE_DIR/$1.env" | tail -1 | cut -d= -f2- || true; }
state_set() {
  local f="$STATE_DIR/$1.env"; touch "$f"
  grep -v "^$2=" "$f" > "$f.tmp" || true
  echo "$2=$3" >> "$f.tmp"; mv "$f.tmp" "$f"
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
