#!/bin/bash
# Roll a product back to PREVIOUS_IMAGE_TAG (app containers only — migrations are expand/contract by
# repo convention, so the previous image runs against the current schema).
#   rollback.sh <product> [--component <name>]   (a component rolls back <NAME>_IMAGE_TAG only)
source "$(dirname "$0")/lib.sh"
PRODUCT="${1:?product}"
STATE="$STATE_DIR/$PRODUCT.env"
[ -f "$STATE" ] || die "no state for $PRODUCT"
VAR=IMAGE_TAG
if [ "${2:-}" = "--component" ]; then
  [[ "${3:-}" =~ ^[a-z][a-z0-9]*$ ]] || die "invalid component ${3:-}"
  VAR="$(tr '[:lower:]' '[:upper:]' <<<"$3")_IMAGE_TAG"
fi

CUR=$(grep "^$VAR=" "$STATE" | cut -d= -f2 || true)
PREV=$(grep "^PREVIOUS_$VAR=" "$STATE" | cut -d= -f2 || true)
[ -n "$PREV" ] && [ "$PREV" != "$CUR" ] || die "nothing to roll back to (current=$CUR previous=$PREV)"

log "ROLLBACK $PRODUCT ($VAR): $CUR → $PREV"
{
  grep -v -e "^$VAR=" -e "^PREVIOUS_$VAR=" -e '^DEPLOYED_AT=' -e '^ROLLED_BACK_FROM=' "$STATE" || true
  echo "$VAR=$PREV"
  echo "PREVIOUS_$VAR=$CUR"
  echo "DEPLOYED_AT=$(date -Is)"
  echo "ROLLED_BACK_FROM=$CUR"
} > "$STATE.next"
mv "$STATE.next" "$STATE"
compose_product "$PRODUCT" up -d --remove-orphans --wait --wait-timeout 180
log "rollback complete; $PRODUCT running $VAR=$PREV"
