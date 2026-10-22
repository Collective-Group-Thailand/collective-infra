#!/bin/bash
# Monthly restore drill: restore the latest backup (optionally from ANOTHER env's repo, e.g. prod → uat)
# into a throw-away Postgres container, run row-count sanity queries per product, write a report.
# Usage: restore-drill.sh [source_env] [--pitr "2026-11-01 02:00:00+07"]
source "$(dirname "$0")/lib.sh"

SRC_ENV="${1:-$COLLECTIVE_ENV}"
PITR=""; [ "${2:-}" = "--pitr" ] && PITR="${3:?timestamp}"
NAME="restore-drill-$(date +%Y%m%d-%H%M)"
TARGET=/data/restore-drill
REPORT="$LOG_DIR/$NAME.txt"

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf "$TARGET"; }
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

docker run -d --name "$NAME" -u 1000:1000 --network collective --memory 1g \
  -e POSTGRES_PASSWORD="$POSTGRES_SUPERUSER_PASSWORD" -e PGDATA=/home/postgres/pgdata/data \
  -v "$TARGET:/home/postgres/pgdata" \
  -v "$PLATFORM_DIR/postgres/pg_hba.conf:/etc/postgresql/pg_hba.conf:ro" \
  timescale/timescaledb-ha:pg18 postgres -c hba_file=/etc/postgresql/pg_hba.conf -c shared_preload_libraries=timescaledb -c archive_mode=off >/dev/null

for i in $(seq 1 90); do docker exec "$NAME" pg_isready -U postgres -h 127.0.0.1 -p 5433 >/dev/null 2>&1 && break; sleep 2; done
docker exec "$NAME" pg_isready -U postgres -h 127.0.0.1 -p 5433 || die "restored instance did not start (see $REPORT)"

{
  echo "== restore drill $NAME  source=$SRC_ENV  ${PITR:+pitr=$PITR}"
  echo "latest xact: $(docker exec "$NAME" psql -U postgres -p 5433 -Atc "select pg_last_committed_xact()" 2>/dev/null || echo n/a)"
  for db in getpack getproperty getbuild; do
    echo "-- $db"
    docker exec "$NAME" psql -U postgres -p 5433 -d "$db" -Atc "
      select 'tables=' || count(*) from information_schema.tables where table_schema='public';
      select 'size=' || pg_size_pretty(pg_database_size(current_database()));
      select 'newest_row=' || coalesce(max(created_at)::text,'n/a') from (
        select created_at from orders union all select created_at from users
      ) t;" 2>&1 | sed 's/^/   /'
  done
  echo "RESULT: OK"
} | tee -a "$REPORT"

aws s3 cp "$REPORT" "s3://$BACKUP_BUCKET/drills/$NAME.txt" --region "$AWS_REGION" >/dev/null && log "report → s3://$BACKUP_BUCKET/drills/$NAME.txt"
