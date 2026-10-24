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

compose_platform() {
  # config hashes → `collective.config` labels (see docker-compose.yml header)
  h() { (cd "$PLATFORM_DIR" && cat "$@" 2>/dev/null) | sha256sum | cut -c1-12; }
  export CFG_CADDY=$(h Caddyfile) CFG_ALLOY=$(h alloy/config.alloy) CFG_CLAMAV=$(h clamav/clamd.conf) \
         CFG_POSTGRES=$(h postgres/postgresql.conf postgres/pg_hba.conf postgres/pgbackrest.conf)
  # Alloy (profile "observability") runs only once Grafana Cloud credentials exist
  if grep -qE "^GRAFANA_PROMETHEUS_URL='?https" "$RUN_DIR/platform.secrets.env" 2>/dev/null; then
    export COMPOSE_PROFILES=observability
  else
    unset COMPOSE_PROFILES
  fi
  docker compose --project-directory "$PLATFORM_DIR" \
    --env-file "$PLATFORM_ENV_FILE" --env-file "$RUN_DIR/platform.secrets.env" "$@"
}

compose_product() { # compose_product <product> <args…>
  # env files: platform.env · <product>.env (API_TAG/WEB_TAG state) · <product>.hosts.env (render-sites.sh)
  local product="$1"; shift
  local files=(--env-file "$PLATFORM_ENV_FILE") f
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
