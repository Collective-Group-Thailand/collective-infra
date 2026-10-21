#!/bin/bash
# getproperty smoke for the monthly restore drill (bin/restore-drill.sh; getproperty-api blueprint T-15, RUNBOOK §9).
# Runs against the restored throw-away instance only. Exit non-zero = the drill fails.
#
# 1. Database checks (psql inside the drill container, superuser over the local socket): the migration history is
#    complete (no failed or unfinished row in public._prisma_migrations), the asset-core `core` and the `smart`
#    schemas exist, and the newest meter reading / invoice timestamps are printed (how fresh the backup is).
# 2. Application smoke inside the api image — the command getproperty-api provides (coordinated with its T-15):
#        node dist/src/drill-smoke.js
#    Environment it gets: DATABASE_URL (the drill instance as login `getproperty` with a one-off password set here),
#    DATABASE_APP_ROLE=gp_app, DATABASE_PLATFORM_ROLE=gp_platform, DRILL_SMOKE=1, DRILL_SOURCE_ENV, DRILL_SAME_ENV,
#    NODE_ENV=production, TZ=Asia/Bangkok. When DRILL_SAME_ENV=true (the backup is this box's environment) the product
#    env file /run/collective/getproperty.env is passed first, so the smoke can decrypt fields and exercise the owner
#    login; for a prod backup restored on uat (DRILL_SAME_ENV=false) the source environment's keys do not exist here and
#    the smoke must limit itself to database-level checks under RLS.
#    It runs on the drill's --internal network (nothing but the restored database is reachable: no Valkey, EMQX, S3,
#    IMDS or internet) with --memory 512m. Expected checks: an owner login, a billing-cycle preview of one building,
#    a cross-tenant read returning nothing. Output: one line per check (`SMOKE <check> ok|fail|skip <detail>`); exit 0
#    = no check failed (getproperty-api D-248). The command ships in every api image since getproperty-api 6b02d84
#    (2026-10-22), which this platform branch requires anyway (PDF queue env, EMQX HTTP auth): an image without it
#    is too old for this platform and fails the drill instead of being skipped.
set -euo pipefail
: "${DRILL_CONTAINER:?}" "${DRILL_NETWORK:?}" "${DRILL_DB_HOST:?}" "${DRILL_DB_PORT:?}"
source "$(dirname "$0")/../../../bin/lib.sh"

q() { docker exec "$DRILL_CONTAINER" psql -U postgres -p "$DRILL_DB_PORT" -d getproperty -v ON_ERROR_STOP=1 -Atc "$1"; }

if [ "$(docker exec "$DRILL_CONTAINER" psql -U postgres -p "$DRILL_DB_PORT" -Atc "select 1 from pg_database where datname = 'getproperty'")" != 1 ]; then
  echo "SKIPPED: no getproperty database in this backup"; exit 0
fi

# 1. database checks
bad=$(q "select count(*) from public._prisma_migrations where finished_at is null or rolled_back_at is not null")
applied=$(q "select count(*) from public._prisma_migrations where finished_at is not null and rolled_back_at is null")
echo "SMOKE migrations $([ "$bad" = 0 ] && echo ok || echo fail) applied=$applied unfinished_or_rolled_back=$bad"
schemas=$(q "select count(*) from pg_namespace where nspname in ('core', 'smart')")
echo "SMOKE schemas $([ "$schemas" = 2 ] && echo ok || echo fail) core+smart=$schemas/2"
echo "INFO newest smart.meter_reading: $(q "select coalesce(max(created_at)::text, 'n/a') from smart.meter_reading" 2>/dev/null || echo n/a)"
[ "$bad" = 0 ] && [ "$schemas" = 2 ] || exit 1

# 2. application smoke in the deployed api image
tag=$(grep -s '^IMAGE_TAG=' "$STATE_DIR/getproperty.env" | cut -d= -f2 || true)
if [ -z "$tag" ]; then echo "SKIPPED app smoke: getproperty is not deployed on this box"; exit 0; fi
image="$ECR_REGISTRY/getproperty/api:$tag"
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REGISTRY" >/dev/null
docker pull --quiet "$image" >/dev/null
if ! docker run --rm --network none --entrypoint node "$image" \
     -e "process.exit(require('fs').existsSync('dist/src/drill-smoke.js') ? 0 : 3)"; then
  echo "SMOKE app fail $image has no dist/src/drill-smoke.js (getproperty-api older than 6b02d84, T-15) — deploy a current api image"; exit 1
fi

pw=$(openssl rand -hex 24) # one-off password of the restored login; the drill instance is deleted afterwards
q "alter role getproperty password '$pw'" >/dev/null
env_args=()
if [ "${DRILL_SAME_ENV:-false}" = true ] && [ -f "$RUN_DIR/getproperty.env" ]; then env_args=(--env-file "$RUN_DIR/getproperty.env"); fi
docker run --rm --network "$DRILL_NETWORK" --memory 512m "${env_args[@]}" \
  -e NODE_ENV=production -e TZ=Asia/Bangkok -e DRILL_SMOKE=1 \
  -e DRILL_SOURCE_ENV="${DRILL_SOURCE_ENV:-}" -e DRILL_SAME_ENV="${DRILL_SAME_ENV:-false}" \
  -e DATABASE_URL="postgresql://getproperty:${pw}@${DRILL_DB_HOST}:${DRILL_DB_PORT}/getproperty" \
  -e DATABASE_APP_ROLE=gp_app -e DATABASE_PLATFORM_ROLE=gp_platform \
  "$image" node dist/src/drill-smoke.js
