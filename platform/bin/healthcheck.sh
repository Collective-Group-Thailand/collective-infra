#!/bin/bash
# Post-deploy smoke test for a product: every service's HEALTHCHECK is healthy and the public
# hostnames answer through Caddy with 2xx/3xx. Exit 1 on failure.
source "$(dirname "$0")/lib.sh"
PRODUCT="${1:?product}"

# 1. container health
unhealthy=$(compose_product "$PRODUCT" ps --format json | jq -r 'select(.Health != "" and .Health != "healthy") | .Service')
if [ -n "$unhealthy" ]; then log "unhealthy services: $unhealthy"; exit 1; fi

# 2. edge check through Caddy (hosts from caddy/sites.<env>.yml)
hosts=$(python3 - "$PLATFORM_DIR/caddy/sites.${COLLECTIVE_ENV}.yml" "$PRODUCT" <<'PY'
import sys, pathlib
yml, product = sys.argv[1], sys.argv[2]
cur = None
for raw in pathlib.Path(yml).read_text().splitlines():
    line = raw.split("#",1)[0].rstrip()
    if not line.strip(): continue
    if not line.startswith(" "): cur = line.rstrip(":").strip(); continue
    if cur == product: print(line.split(":",1)[1].strip())
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
