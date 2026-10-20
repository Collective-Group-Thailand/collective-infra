#!/bin/bash
# First-run (and safe re-run) of the platform on a box: secrets → sites → systemd units → compose up.
# Called by EC2 user-data after cloning the repo; also the thing to run after `git pull` of platform/.
source "$(dirname "$0")/lib.sh"
cd "$PLATFORM_DIR"

log "bootstrap platform env=$COLLECTIVE_ENV"

# 1. systemd units (timers for backups, cert sync; service that re-renders secrets at boot)
install -m 0644 systemd/*.service systemd/*.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now collective-platform.service pgbackrest-backup.timer mqtt-cert-sync.timer secrets-refresh.timer

# 2. secrets + Caddy sites
bin/fetch-secrets.sh platform
bin/render-sites.sh

# 3. ECR login (instance role) so platform/product pulls work
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY" >/dev/null

# 4. shared services
compose_platform pull --quiet
compose_platform up -d --remove-orphans
log "waiting for postgres…"
for i in $(seq 1 60); do
  compose_platform exec -T postgres pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1 && break
  sleep 2
done
compose_platform exec -T postgres pg_isready -U postgres -h 127.0.0.1 || die "postgres did not become ready"

# 5. pgBackRest stanza (idempotent) + first full backup if the repo is empty
if ! compose_platform exec -T postgres pgbackrest --stanza=collective info --output=json | jq -e '.[0].backup | length > 0' >/dev/null 2>&1; then
  compose_platform exec -T postgres pgbackrest --stanza=collective stanza-create || true
  compose_platform exec -T postgres pgbackrest --stanza=collective check
  log "taking first full backup"
  compose_platform exec -T postgres pgbackrest --stanza=collective --type=full backup
fi

# 6. MQTT cert (needs Caddy to have issued the cert for MQTT_HOSTNAME first; timer retries)
bin/sync-mqtt-cert.sh || log "mqtt cert not ready yet (timer will retry)"

# 7. bring up any product that has been deployed before (state file exists)
for f in "$STATE_DIR"/*.env; do
  [ -f "$f" ] || continue
  p=$(basename "$f" .env)
  log "restoring product $p"
  bin/fetch-secrets.sh "$p" && compose_product "$p" up -d --remove-orphans || log "WARN: $p failed to start"
done

log "bootstrap complete"
