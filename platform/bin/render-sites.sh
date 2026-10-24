#!/bin/bash
# Render caddy/templates/<product>.caddy → caddy/sites/<product>.caddy using caddy/sites.<env>.yml,
# then validate and reload Caddy if it is running.
source "$(dirname "$0")/lib.sh"

SITES_YML="$PLATFORM_DIR/caddy/sites.${COLLECTIVE_ENV}.yml"
[ -f "$SITES_YML" ] || die "missing $SITES_YML"

python3 - "$SITES_YML" "$PLATFORM_DIR/caddy" "$STATE_DIR" <<'PY'
import re, sys, pathlib
yml, caddy_dir, state_dir = sys.argv[1], pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
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
    # hosts also go to the product's compose (e.g. getpack-web needs PUBLIC_HOST/ADMIN_HOST/PARTNER_HOST)
    (state_dir / f"{product}.hosts.env").write_text("".join(f"{k}={v}\n" for k, v in vars_.items()))
    # one or more templates per product: <product>.caddy and optional <product>-<part>.caddy
    templates = sorted((caddy_dir / "templates").glob(f"{product}.caddy")) + \
                sorted((caddy_dir / "templates").glob(f"{product}-*.caddy"))
    stale = list(out_dir.glob(f"{product}.caddy")) + list(out_dir.glob(f"{product}-*.caddy"))
    # Placeholder domains (*.example, RFC 2606) cannot get certificates; serving them only makes
    # Caddy retry ACME forever. The product goes live once real hostnames are in sites.<env>.yml.
    if any(v.endswith(".example") for v in vars_.values()):
        for f in stale: f.unlink(missing_ok=True)
        print(f"skip {product}: placeholder hostnames"); continue
    if not templates:
        print(f"skip {product}: no template"); continue
    for tmpl in templates:
        rendered = out_dir / tmpl.name
        text = tmpl.read_text()
        # A template may need a file a product hook renders first (e.g. a client-CA bundle):
        #   # requires-file: sites/<name>   (relative to caddy/). Skipped — not broken — until it exists.
        needs = [n for n in re.findall(r"^# requires-file: (\S+)$", text, re.M) if not (caddy_dir / n).exists()]
        if needs:
            print(f"skip {tmpl.name}: waiting for {needs}"); rendered.unlink(missing_ok=True); continue
        # ... or a host only some environments have (e.g. prod's www name):  # requires-var: KEY
        unset = [k for k in re.findall(r"^# requires-var: (\w+)$", text, re.M) if not vars_.get(k)]
        if unset:
            print(f"skip {tmpl.name}: {unset} not in {pathlib.Path(yml).name}"); rendered.unlink(missing_ok=True); continue
        missing = set(re.findall(r"{{(\w+)}}", text)) - set(vars_)
        if missing:
            sys.exit(f"{tmpl.name}: missing {sorted(missing)} in {yml}")
        for k, v in vars_.items():
            text = text.replace("{{%s}}" % k, v)
        rendered.write_text(text)
        print(f"rendered {tmpl.name}")
PY

if docker ps --format '{{.Names}}' | grep -q '^platform-caddy-1$'; then
  compose_platform exec -T caddy caddy validate --config /etc/caddy/Caddyfile >/dev/null
  compose_platform exec -T caddy caddy reload --config /etc/caddy/Caddyfile
  log "caddy reloaded"
fi
