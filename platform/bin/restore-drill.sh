#!/bin/bash
# Monthly restore drill: restore the latest backup (optionally from ANOTHER env's repo, e.g. prod → uat)
# into a throw-away Postgres container, run sanity queries per product and each product's smoke hook
# (products/<p>/hooks/drill-smoke.sh), measure the elapsed time against the 30-minute RTO target, write a report.
# The restored instance lives on its own --internal docker network (no route to Valkey, EMQX, S3, IMDS or the
# internet), so neither the drill nor a product smoke can touch live state. Exit 1 when a check fails.
# Usage: restore-drill.sh [source_env] [--pitr "2026-11-01 02:00:00+07"]
source "$(dirname "$0")/lib.sh"

SRC_ENV="${1:-$COLLECTIVE_ENV}"
PITR=""; [ "${2:-}" = "--pitr" ] && PITR="${3:?timestamp}"
NAME="restore-drill-$(date +%Y%m%d-%H%M)"
NET="$NAME-net"
TARGET=/data/restore-drill
REPORT="$LOG_DIR/$NAME.txt"
RTO_TARGET_SECONDS=1800 # locked decision 6: RTO target 30 min via restore
STARTED=$(date +%s)

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$TARGET"
}
trap cleanup EXIT
cleanup; mkdir -p "$TARGET"; chown 1000:1000 "$TARGET"

log "restore drill from env=$SRC_ENV ${PITR:+PITR=$PITR} → $NAME"
# shellcheck disable=SC1091
source "$RUN_DIR/platform.secrets.env"

restore_args=(--stanza=collective --delta --log-level-console=info)
[ -n "$PITR" ] && restore_args+=(--type=time "--target=$PITR" --target-action=promote)

docker run --rm --name "$NAME-restore" -u 1000:1000 \
  -e PGBACKREST_REPO1_S3_BUCKET="$BACKUP_BUCKET" -e PGBACKREST_REPO1_S3_REGION="$AWS_REGION" \
  -e PGBACKREST_REPO1_S3_ENDPOINT="s3.${AWS_REGION}.amazonaws.com" -e PGBACKREST_REPO1_PATH="/pgbackrest/$SRC_ENV" \
  -v "$PLATFORM_DIR/postgres/pgbackrest.conf:/etc/pgbackrest/pgbackrest.conf:ro" \
  -v "$TARGET:/home/postgres/pgdata" \
  timescale/timescaledb-ha:pg18 pgbackrest "${restore_args[@]}" restore 2>&1 | tee -a "$REPORT"

# archive_command must not push WAL from the drill instance into the real repo
cat >> "$TARGET/data/postgresql.auto.conf" <<EOF
archive_mode = off
port = 5433
EOF

docker network create --internal "$NET" >/dev/null
docker run -d --name "$NAME" -u 1000:1000 --network "$NET" --memory 1g \
  -e POSTGRES_PASSWORD="$POSTGRES_SUPERUSER_PASSWORD" -e PGDATA=/home/postgres/pgdata/data \
  -v "$TARGET:/home/postgres/pgdata" \
  -v "$PLATFORM_DIR/postgres/pg_hba.conf:/etc/postgresql/pg_hba.conf:ro" \
  timescale/timescaledb-ha:pg18 postgres -c hba_file=/etc/postgresql/pg_hba.conf -c shared_preload_libraries=timescaledb -c archive_mode=off >/dev/null

for i in $(seq 1 90); do docker exec "$NAME" pg_isready -U postgres -h 127.0.0.1 -p 5433 >/dev/null 2>&1 && break; sleep 2; done
docker exec "$NAME" pg_isready -U postgres -h 127.0.0.1 -p 5433 || die "restored instance did not start (see $REPORT)"

rc=0
{
  echo "== restore drill $NAME  source=$SRC_ENV  ${PITR:+pitr=$PITR}"
  echo "latest xact: $(docker exec "$NAME" psql -U postgres -p 5433 -Atc "select pg_last_committed_xact()" 2>/dev/null || echo n/a)"
  for db in getpack getproperty getbuild; do
    if [ "$(docker exec "$NAME" psql -U postgres -p 5433 -Atc "select 1 from pg_database where datname = '$db'")" != 1 ]; then
      echo "-- $db: not in this backup"; continue
    fi
    echo "-- $db"
    docker exec "$NAME" psql -U postgres -p 5433 -d "$db" -Atc "
      select 'tables=' || count(*) from information_schema.tables
       where table_schema not in ('pg_catalog', 'information_schema') and table_schema not like '\_timescaledb%';
      select 'size=' || pg_size_pretty(pg_database_size(current_database()));" 2>&1 | sed 's/^/   /'
    if [ "$db" = getpack ]; then
      docker exec "$NAME" psql -U postgres -p 5433 -d "$db" -Atc "
        select 'newest_row=' || coalesce(max(created_at)::text,'n/a') from (
          select created_at from orders union all select created_at from users
        ) t;" 2>&1 | sed 's/^/   /'
    fi
  done
} | tee -a "$REPORT"

# Product smoke hooks (getproperty: blueprint T-15). Contract: env DRILL_CONTAINER, DRILL_NETWORK, DRILL_DB_HOST,
# DRILL_DB_PORT, DRILL_SOURCE_ENV, DRILL_SAME_ENV; output into the report; exit 0 = pass.
for hook in "$PLATFORM_DIR"/products/*/hooks/drill-smoke.sh; do
  [ -x "$hook" ] || continue
  product=$(basename "$(dirname "$(dirname "$hook")")")
  echo "-- smoke $product" | tee -a "$REPORT"
  if DRILL_CONTAINER="$NAME" DRILL_NETWORK="$NET" DRILL_DB_HOST="$NAME" DRILL_DB_PORT=5433 DRILL_SOURCE_ENV="$SRC_ENV" \
       DRILL_SAME_ENV="$([ "$SRC_ENV" = "$COLLECTIVE_ENV" ] && echo true || echo false)" \
       "$hook" 2>&1 | sed 's/^/   /' | tee -a "$REPORT"; then
    echo "   smoke $product: OK" | tee -a "$REPORT"
  else
    echo "   smoke $product: FAIL" | tee -a "$REPORT"; rc=1
  fi
done

elapsed=$(( $(date +%s) - STARTED ))
{
  echo "rto_seconds=$elapsed target=$RTO_TARGET_SECONDS $([ "$elapsed" -le "$RTO_TARGET_SECONDS" ] && echo within || echo EXCEEDED)"
  [ "$rc" = 0 ] && echo "RESULT: OK" || echo "RESULT: FAIL"
} | tee -a "$REPORT"

aws s3 cp "$REPORT" "s3://$BACKUP_BUCKET/drills/$NAME.txt" --region "$AWS_REGION" >/dev/null && log "report → s3://$BACKUP_BUCKET/drills/$NAME.txt"
exit "$rc"
