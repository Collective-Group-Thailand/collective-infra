#!/bin/bash
# Deploy one product at one image tag. Invoked by GitHub Actions through SSM Run Command:
#   /opt/collective/platform/bin/deploy-product.sh <product> <image_tag> [--no-migrate]
# Steps: fetch secrets → pull → migrate → up → healthcheck → (rollback on failure).
source "$(dirname "$0")/lib.sh"

PRODUCT="${1:?product}"; TAG="${2:?image tag}"; MIGRATE=1
[ "${3:-}" = "--no-migrate" ] && MIGRATE=0
PRODUCT_DIR="$PLATFORM_DIR/products/$PRODUCT"
[ -d "$PRODUCT_DIR" ] || die "unknown product $PRODUCT"
STATE="$STATE_DIR/$PRODUCT.env"

exec 9>"$STATE_DIR/.$PRODUCT.lock"; flock -w 600 9 || die "another deploy of $PRODUCT is running"

PREV_TAG=$(grep -s '^IMAGE_TAG=' "$STATE" | cut -d= -f2 || true)
log "deploy $PRODUCT: ${PREV_TAG:-<none>} → $TAG"

# state: current + previous tag (previous is what rollback.sh uses)
{
  echo "IMAGE_TAG=$TAG"
  echo "PREVIOUS_IMAGE_TAG=${PREV_TAG:-$TAG}"
  echo "DEPLOYED_AT=$(date -Is)"
} > "$STATE.next"

bin_dir="$(dirname "$0")"
"$bin_dir/fetch-secrets.sh" "$PRODUCT"

aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REGISTRY" >/dev/null
mv "$STATE.next" "$STATE"
compose_product "$PRODUCT" pull --quiet

if [ "$MIGRATE" = 1 ] && grep -q '^  api:' "$PRODUCT_DIR/docker-compose.yml"; then
  log "running migrations"
  # `migrate` service = same api image, one-shot (defined in the product compose file)
  compose_product "$PRODUCT" run --rm --no-deps migrate
fi

compose_product "$PRODUCT" up -d --remove-orphans --wait --wait-timeout 180 \
  || { log "containers unhealthy after start"; "$bin_dir/rollback.sh" "$PRODUCT"; exit 1; }

"$bin_dir/healthcheck.sh" "$PRODUCT" \
  || { log "healthcheck failed"; "$bin_dir/rollback.sh" "$PRODUCT"; exit 1; }

docker image prune -f --filter "until=168h" >/dev/null || true
log "deploy $PRODUCT $TAG OK"
