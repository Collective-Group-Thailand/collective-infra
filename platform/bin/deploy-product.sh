#!/bin/bash
# Deploy one product at one image tag. Invoked by GitHub Actions through SSM Run Command:
#   /opt/collective/platform/bin/deploy-product.sh <product> <image_tag> [--no-migrate] [--component <name>]
# Steps: fetch secrets → pull → migrate → up → healthcheck → (rollback on failure).
# --component <name>: a product whose images come from several repos (getproperty: api, web, liff) deploys one
# image at a time. The tag goes to <NAME>_IMAGE_TAG in the state file (the compose file reads it, e.g.
# getproperty/web:${WEB_IMAGE_TAG}); IMAGE_TAG (the api image) and the other components keep theirs. Without it,
# behaviour is unchanged (IMAGE_TAG), and component tags already in the state file are carried over.
source "$(dirname "$0")/lib.sh"

PRODUCT="${1:?product}"; TAG="${2:?image tag}"; MIGRATE=1; COMPONENT=""
shift 2
while [ $# -gt 0 ]; do
  case "$1" in
    --no-migrate) MIGRATE=0 ;;
    --component) COMPONENT="${2:?--component needs a name}"; shift ;;
    "") ;;
    *) die "unknown option $1" ;;
  esac
  shift
done
[ -z "$COMPONENT" ] || [[ "$COMPONENT" =~ ^[a-z][a-z0-9]*$ ]] || die "invalid component $COMPONENT"
PRODUCT_DIR="$PLATFORM_DIR/products/$PRODUCT"
[ -d "$PRODUCT_DIR" ] || die "unknown product $PRODUCT"
STATE="$STATE_DIR/$PRODUCT.env"

exec 9>"$STATE_DIR/.$PRODUCT.lock"; flock -w 600 9 || die "another deploy of $PRODUCT is running"

if [ -n "$COMPONENT" ]; then
  VAR="$(tr '[:lower:]' '[:upper:]' <<<"$COMPONENT")_IMAGE_TAG"
  PREV_TAG=$(grep -s "^$VAR=" "$STATE" | cut -d= -f2 || true)
  log "deploy $PRODUCT/$COMPONENT: ${PREV_TAG:-<none>} → $TAG"
  {
    grep -sv -e "^$VAR=" -e "^PREVIOUS_$VAR=" -e '^DEPLOYED_AT=' "$STATE" || true
    echo "$VAR=$TAG"
    echo "PREVIOUS_$VAR=${PREV_TAG:-$TAG}"
    echo "DEPLOYED_AT=$(date -Is)"
  } > "$STATE.next"
  MIGRATE=0 # migrations belong to the api image
else
  PREV_TAG=$(grep -s '^IMAGE_TAG=' "$STATE" | cut -d= -f2 || true)
  log "deploy $PRODUCT: ${PREV_TAG:-<none>} → $TAG"
  # state: current + previous tag (previous is what rollback.sh uses); component tags are kept
  {
    echo "IMAGE_TAG=$TAG"
    echo "PREVIOUS_IMAGE_TAG=${PREV_TAG:-$TAG}"
    echo "DEPLOYED_AT=$(date -Is)"
    grep -s -E '^(PREVIOUS_)?[A-Z][A-Z0-9]*_IMAGE_TAG=' "$STATE" | grep -v '^PREVIOUS_IMAGE_TAG=' || true
  } > "$STATE.next"
fi

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

rollback_args=("$PRODUCT"); [ -z "$COMPONENT" ] || rollback_args+=(--component "$COMPONENT")
compose_product "$PRODUCT" up -d --remove-orphans --wait --wait-timeout 180 \
  || { log "containers unhealthy after start"; "$bin_dir/rollback.sh" "${rollback_args[@]}"; exit 1; }

"$bin_dir/healthcheck.sh" "$PRODUCT" \
  || { log "healthcheck failed"; "$bin_dir/rollback.sh" "${rollback_args[@]}"; exit 1; }

docker image prune -f --filter "until=168h" >/dev/null || true
log "deploy $PRODUCT${COMPONENT:+/$COMPONENT} $TAG OK"
