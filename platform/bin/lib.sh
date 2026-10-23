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
  local product="$1"; shift
  docker compose --project-name "$product" --project-directory "$PLATFORM_DIR/products/$product" \
    --env-file "$PLATFORM_ENV_FILE" --env-file "$STATE_DIR/$product.env" "$@"
}
