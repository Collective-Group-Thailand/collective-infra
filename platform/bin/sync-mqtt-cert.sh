#!/bin/bash
# Copy the Let's Encrypt cert Caddy holds for the platform hostname into EMQX's data dir and reload
# the SSL listener when it changed. Caddy renews ~30 days before expiry; the timer runs daily.
# NOTE: the 8883 listener serves IoT gateways with mutual TLS and a server certificate from the platform device CA
# (bin/render-device-ca.sh, collective/<env>/platform/device-ca) — gateways do not trust Let's Encrypt. This copy is
# kept for a future Let's Encrypt listener and never touches the device listener.
source "$(dirname "$0")/lib.sh"

HOST="${MQTT_HOSTNAME:-$PLATFORM_HOSTNAME}"
SRC=$(find /data/caddy/certificates -type d -name "$HOST" | head -1)
[ -n "$SRC" ] && [ -f "$SRC/$HOST.crt" ] || die "no Caddy certificate for $HOST yet"

DST=/data/emqx/certs; mkdir -p "$DST"
if ! cmp -s "$SRC/$HOST.crt" "$DST/fullchain.pem"; then
  install -m 0644 -o 1000 -g 1000 "$SRC/$HOST.crt" "$DST/fullchain.pem"
  install -m 0600 -o 1000 -g 1000 "$SRC/$HOST.key" "$DST/privkey.pem"
  log "mqtt cert for $HOST updated"
else
  log "mqtt cert unchanged"
fi
