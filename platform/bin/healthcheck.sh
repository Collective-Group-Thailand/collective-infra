#!/bin/bash
# Post-deploy smoke test for one component: its containers are healthy and its public hostnames
# answer through Caddy. api → API_HOST; web → every other host of the product (WEB/ADMIN/PARTNER…).
#   healthcheck.sh <product> <component>
source "$(dirname "$0")/lib.sh"
PRODUCT="${1:?product}"; COMPONENT="${2:?component (api|web)}"

# 1. container health (only this component's services)
mapfile -t SERVICES < <(component_services "$PRODUCT" "$COMPONENT")
bad=$(compose_product "$PRODUCT" ps --format json "${SERVICES[@]}" \
        | jq -r '(if type == "array" then .[] else . end) | select(.State != "running" or (.Health != "" and .Health != "healthy")) | "\(.Service)=\(.State)/\(.Health)"')
if [ -n "$bad" ]; then log "unhealthy: $bad"; exit 1; fi

# 2. edge check through Caddy (hosts from caddy/sites.<env>.yml)
hosts=$(python3 - "$PLATFORM_DIR/caddy/sites.${COLLECTIVE_ENV}.yml" "$PRODUCT" "$COMPONENT" <<'PY'
import sys, pathlib
yml, product, component = sys.argv[1:4]
cur = None
for raw in pathlib.Path(yml).read_text().splitlines():
    line = raw.split("#",1)[0].rstrip()
    if not line.strip(): continue
    if not line.startswith(" "): cur = line.rstrip(":").strip(); continue
    if cur != product: continue
    key, val = (p.strip() for p in line.split(":",1))
    if (key == "API_HOST") == (component == "api"): print(val)
PY
)
rc=0
for h in $hosts; do
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 --resolve "$h:443:127.0.0.1" "https://$h/health" || echo 000)
  case "$code" in
    2*|3*|404) log "edge $h → $code" ;;   # 404 on /health is fine for web hosts; TLS + routing proved
    *) log "edge $h → $code FAIL"; rc=1 ;;
  esac
done
exit $rc
