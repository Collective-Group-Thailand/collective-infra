#!/bin/bash
# pgBackRest backup driven by systemd timer: full on Sunday, differential other days.
# Pushes a heartbeat (success/fail + age) as a Prometheus textfile-style log line that Alloy ships, and
# writes /var/lib/collective/last-backup for the restore drill / alerting.
source "$(dirname "$0")/lib.sh"

TYPE="${1:-auto}"
if [ "$TYPE" = auto ]; then
  [ "$(date +%u)" = 7 ] && TYPE=full || TYPE=diff
fi

start=$(date +%s)
if compose_platform exec -T postgres pgbackrest --stanza=collective --type="$TYPE" backup 2>&1 | tee -a "$LOG_DIR/pgbackrest.log"; then
  status=ok
else
  status=fail
fi
dur=$(( $(date +%s) - start ))
compose_platform exec -T postgres pgbackrest --stanza=collective info --output=json > "$STATE_DIR/pgbackrest-info.json" 2>/dev/null || true
printf '%s type=%s status=%s duration_s=%s\n' "$(date -Is)" "$TYPE" "$status" "$dur" | tee -a "$LOG_DIR/backup-heartbeat.log" > "$STATE_DIR/last-backup"
log "backup $TYPE $status in ${dur}s"
[ "$status" = ok ]
