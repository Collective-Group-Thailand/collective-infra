#!/bin/bash
# Deploy one component (= one image) of a product. Invoked by GitHub Actions through SSM Run Command:
#   /opt/collective/platform/bin/deploy-product.sh <product> <component> <image_tag> [--no-migrate]
#   e.g. deploy-product.sh getpack api sha-abc1234   → services using <registry>/getpack/api:<tag>
# api and web live in different repos and ship on their own, so each component has its own tag
# (API_TAG / WEB_TAG in $STATE_DIR/<product>.env) and its own rollback point.
# Steps: fetch secrets → pull → migrate (api) → up → healthcheck → rollback on failure.
source "$(dirname "$0")/lib.sh"

PRODUCT="${1:?product}"; COMPONENT="${2:?component (api|web)}"; TAG="${3:?image tag}"; MIGRATE=1
[ "${4:-}" = "--no-migrate" ] && MIGRATE=0
PRODUCT_DIR="$PLATFORM_DIR/products/$PRODUCT"
[ -d "$PRODUCT_DIR" ] || die "unknown product $PRODUCT"
[[ "$TAG" =~ ^[A-Za-z0-9._-]+$ ]] || die "bad tag $TAG"
VAR="$(tr '[:lower:]' '[:upper:]' <<<"$COMPONENT")_TAG"
bin_dir="$(dirname "$0")"

exec 9>"$STATE_DIR/.$PRODUCT.lock"; flock -w 600 9 || die "another deploy of $PRODUCT is running"

"$bin_dir/fetch-secrets.sh" "$PRODUCT"
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REGISTRY" >/dev/null

PREV=$(state_get "$PRODUCT" "$VAR")
log "deploy $PRODUCT/$COMPONENT: ${PREV:-<none>} → $TAG"
state_set "$PRODUCT" "$VAR" "$TAG"
state_set "$PRODUCT" "PREVIOUS_$VAR" "${PREV:-$TAG}"
state_set "$PRODUCT" "DEPLOYED_AT_$VAR" "$(date -Is)"

mapfile -t SERVICES < <(component_services "$PRODUCT" "$COMPONENT")
[ "${#SERVICES[@]}" -gt 0 ] || die "no services in $PRODUCT compose use the $PRODUCT/$COMPONENT image"
log "services: ${SERVICES[*]}"

restore_state() { state_set "$PRODUCT" "$VAR" "${PREV:-}"; }
compose_product "$PRODUCT" pull --quiet "${SERVICES[@]}" || { log "pull failed"; restore_state; exit 1; }

if [ "$MIGRATE" = 1 ] && [ "$COMPONENT" = api ] && compose_product "$PRODUCT" --profile tools config --services | grep -qx migrate; then
  log "running migrations"
  # `migrate` = same api image, one-shot. Migrations are expand/contract, so a failed migration
  # leaves the previous version serving; nothing to roll back.
  compose_product "$PRODUCT" run --rm --no-deps migrate || { log "migration failed"; restore_state; exit 1; }
  # Product hook (optional), only after a successful migration: products/<product>/hooks/post-migrate.sh — e.g.
  # getproperty drops the gp_mqtt role once its migration 0037 is applied. Idempotent; a failure only warns.
  hook="$PRODUCT_DIR/hooks/post-migrate.sh"
  if [ -x "$hook" ]; then "$hook" || log "WARN: $PRODUCT post-migrate hook failed"; fi
fi

compose_product "$PRODUCT" up -d --no-deps --wait --wait-timeout 180 "${SERVICES[@]}" \
  || { log "containers unhealthy after start"; "$bin_dir/rollback.sh" "$PRODUCT" "$COMPONENT"; exit 1; }

"$bin_dir/healthcheck.sh" "$PRODUCT" "$COMPONENT" \
  || { log "healthcheck failed"; "$bin_dir/rollback.sh" "$PRODUCT" "$COMPONENT"; exit 1; }

docker image prune -f --filter "until=168h" >/dev/null || true
log "deploy $PRODUCT/$COMPONENT $TAG OK"
