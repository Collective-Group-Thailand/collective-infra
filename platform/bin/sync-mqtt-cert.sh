#!/bin/bash
# Copy the Let's Encrypt cert Caddy holds for the platform hostname into EMQX's data dir and reload
# the SSL listener when it changed. Caddy renews ~30 days before expiry; the timer runs daily.
source "$(dirname "$0")/lib.sh"

HOST="${MQTT_HOSTNAME:-$PLATFORM_HOSTNAME}"
SRC=$(find /data/caddy/certificates -type d -name "$HOST" | head -1)
[ -n "$SRC" ] && [ -f "$SRC/$HOST.crt" ] || die "no Caddy certificate for $HOST yet"

DST=/data/emqx/certs; mkdir -p "$DST"
if ! cmp -s "$SRC/$HOST.crt" "$DST/fullchain.pem"; then
  install -m 0644 -o 1000 -g 1000 "$SRC/$HOST.crt" "$DST/fullchain.pem"
  install -m 0600 -o 1000 -g 1000 "$SRC/$HOST.key" "$DST/privkey.pem"
  if docker ps --format '{{.Names}}' | grep -q '^platform-emqx-1$'; then
    compose_platform exec -T emqx emqx ctl listeners restart ssl:default >/dev/null \
      || compose_platform restart emqx
  fi
  log "mqtt cert for $HOST updated"
else
  log "mqtt cert unchanged"
fi
