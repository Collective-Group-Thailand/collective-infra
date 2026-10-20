#!/bin/bash
# Render caddy/templates/<product>.caddy → caddy/sites/<product>.caddy using caddy/sites.<env>.yml,
# then validate and reload Caddy if it is running.
source "$(dirname "$0")/lib.sh"

SITES_YML="$PLATFORM_DIR/caddy/sites.${COLLECTIVE_ENV}.yml"
[ -f "$SITES_YML" ] || die "missing $SITES_YML"

python3 - "$SITES_YML" "$PLATFORM_DIR/caddy" <<'PY'
import re, sys, pathlib
yml, caddy_dir = sys.argv[1], pathlib.Path(sys.argv[2])
# tiny YAML subset parser: "product:\n  KEY: value" — no dependency on PyYAML
sites, cur = {}, None
for raw in pathlib.Path(yml).read_text().splitlines():
    line = raw.split("#", 1)[0].rstrip()
    if not line.strip():
        continue
    if not line.startswith(" "):
        cur = line.rstrip(":").strip(); sites[cur] = {}
    else:
        k, v = line.strip().split(":", 1); sites[cur][k.strip()] = v.strip()
out_dir = caddy_dir / "sites"
for product, vars_ in sites.items():
    tmpl = caddy_dir / "templates" / f"{product}.caddy"
    if not tmpl.exists():
        print(f"skip {product}: no template"); continue
    text = tmpl.read_text()
    missing = set(re.findall(r"{{(\w+)}}", text)) - set(vars_)
    if missing:
        sys.exit(f"{product}: missing {sorted(missing)} in {yml}")
    for k, v in vars_.items():
        text = text.replace("{{%s}}" % k, v)
    (out_dir / f"{product}.caddy").write_text(text)
    print(f"rendered {product}.caddy")
PY

if docker ps --format '{{.Names}}' | grep -q '^platform-caddy-1$'; then
  compose_platform exec -T caddy caddy validate --config /etc/caddy/Caddyfile >/dev/null
  compose_platform exec -T caddy caddy reload --config /etc/caddy/Caddyfile
  log "caddy reloaded"
fi
