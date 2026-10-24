#!/bin/bash
# Roll one component of a product back to its previous tag (app containers only — migrations are
# expand/contract by repo convention, so the previous image runs against the current schema).
#   rollback.sh <product> <component>
source "$(dirname "$0")/lib.sh"
PRODUCT="${1:?product}"; COMPONENT="${2:?component (api|web)}"
VAR="$(tr '[:lower:]' '[:upper:]' <<<"$COMPONENT")_TAG"

CUR=$(state_get "$PRODUCT" "$VAR"); PREV=$(state_get "$PRODUCT" "PREVIOUS_$VAR")
mapfile -t SERVICES < <(component_services "$PRODUCT" "$COMPONENT")

if [ -z "$PREV" ] || [ "$PREV" = "$CUR" ]; then
  # first deploy of this component: nothing older to return to → stop it rather than leave it crash-looping
  log "no previous $PRODUCT/$COMPONENT tag; stopping ${SERVICES[*]}"
  compose_product "$PRODUCT" stop "${SERVICES[@]}" || true
  # forget the failed tag so a reboot does not start it again and the next deploy starts clean
  state_set "$PRODUCT" "$VAR" ""; state_set "$PRODUCT" "PREVIOUS_$VAR" ""
  exit 1
fi

log "ROLLBACK $PRODUCT/$COMPONENT: $CUR → $PREV"
state_set "$PRODUCT" "$VAR" "$PREV"
state_set "$PRODUCT" "PREVIOUS_$VAR" "$CUR"
state_set "$PRODUCT" "ROLLED_BACK_FROM_$VAR" "$CUR"
compose_product "$PRODUCT" up -d --no-deps --wait --wait-timeout 180 "${SERVICES[@]}"
log "rollback complete; $PRODUCT/$COMPONENT running $PREV"
