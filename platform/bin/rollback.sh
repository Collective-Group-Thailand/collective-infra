#!/bin/bash
# Roll a product back to PREVIOUS_IMAGE_TAG (app containers only — migrations are expand/contract by
# repo convention, so the previous image runs against the current schema).
source "$(dirname "$0")/lib.sh"
PRODUCT="${1:?product}"
STATE="$STATE_DIR/$PRODUCT.env"
[ -f "$STATE" ] || die "no state for $PRODUCT"

CUR=$(grep '^IMAGE_TAG=' "$STATE" | cut -d= -f2)
PREV=$(grep '^PREVIOUS_IMAGE_TAG=' "$STATE" | cut -d= -f2)
[ -n "$PREV" ] && [ "$PREV" != "$CUR" ] || die "nothing to roll back to (current=$CUR previous=$PREV)"

log "ROLLBACK $PRODUCT: $CUR → $PREV"
{
  echo "IMAGE_TAG=$PREV"
  echo "PREVIOUS_IMAGE_TAG=$CUR"
  echo "DEPLOYED_AT=$(date -Is)"
  echo "ROLLED_BACK_FROM=$CUR"
} > "$STATE"
compose_product "$PRODUCT" up -d --remove-orphans --wait --wait-timeout 180
log "rollback complete; $PRODUCT running $PREV"
