#!/bin/bash
# getproperty after its `migrate` service succeeded (bin/deploy-product.sh, api deploys only). Idempotent.
#
# Retire the role gp_mqtt (getproperty-api D-244, migration 0037). EMQX no longer reads PostgreSQL; 0037 dropped the
# policy mqtt_acl_rls_broker and every grant to gp_mqtt. The role cannot simply leave postgres/init/20-getproperty.sh:
# migration 0010 (immutable) runs `CREATE ROLE gp_mqtt` when it is missing, which the NOCREATEROLE product login may not
# do, so a fresh box still needs the init script to create it. Order on every box, fresh or existing:
#   init script creates gp_mqtt → migrate applies 0010 … 0037 → this hook drops gp_mqtt.
# Only once 0037 is recorded as applied in public._prisma_migrations; a failure here only warns (the role has no
# access left after 0037, so keeping it is harmless) and never fails the deploy.
source "$(dirname "$0")/../../../bin/lib.sh"

PG=platform-postgres-1
MIGRATION_0037=20261022000037_0037_emqx_http_auth
psql_gp() { docker exec -i "$PG" psql -U postgres -d getproperty -v ON_ERROR_STOP=1 -Atq "$@"; }

if [ "$(psql_gp -c "select to_regclass('public._prisma_migrations') is not null")" != t ]; then
  log "getproperty post-migrate: no _prisma_migrations yet — gp_mqtt kept"; exit 0
fi
applied=$(psql_gp -c "select count(*) from public._prisma_migrations
  where migration_name = '$MIGRATION_0037' and finished_at is not null and rolled_back_at is null")
if [ "$applied" != 1 ]; then
  log "getproperty post-migrate: $MIGRATION_0037 not applied — gp_mqtt kept"; exit 0
fi

# DROP ROLE refuses while anything still depends on the role (a privilege or policy 0037 did not remove): then the
# role stays, the deploy goes on, and the warning names the remaining objects.
if psql_gp <<'SQL'
DO $retire$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'gp_mqtt') THEN
    DROP ROLE gp_mqtt;
    RAISE NOTICE 'gp_mqtt dropped';
  END IF;
END
$retire$;
SQL
then
  log "getproperty post-migrate: gp_mqtt retired (role absent)"
else
  log "WARN: getproperty post-migrate: DROP ROLE gp_mqtt failed — check its remaining privileges (\\dp in getproperty) and drop it by hand"
fi
