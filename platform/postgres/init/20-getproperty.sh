#!/bin/bash
# getproperty's database roles (getproperty-api docs/deployment.md §3). Runs once on an empty data directory after
# 10-products.sh; idempotent, so on a box initialised before this file existed run it by hand (SSM):
#   docker exec -e GETPROPERTY_MQTT_DB_PASSWORD="…" platform-postgres-1 bash /docker-entrypoint-initdb.d/20-getproperty.sh
#
# The product login `getproperty` is NOCREATEROLE and its migrations (@collective/asset-core 0001, app 0010) expect
# these NOLOGIN group roles; gp_platform needs BYPASSRLS, which only a superuser can grant. The app runs as
# `getproperty` and switches per transaction (`SET LOCAL ROLE gp_app` / `gp_platform`: DATABASE_APP_ROLE /
# DATABASE_PLATFORM_ROLE in the app secret), so row-level security applies to every tenant query.
# `getproperty_mqtt` is EMQX's login for the authorization source: member of gp_mqtt, which reads only the live
# rows of smart.mqtt_acl (RLS policy of migration 0010).
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username postgres --dbname postgres <<-'SQL'
  DO $roles$
  DECLARE spec text[];
  BEGIN
    FOREACH spec SLICE 1 IN ARRAY ARRAY[['gp_owner', 'NOLOGIN'], ['gp_app', 'NOLOGIN NOBYPASSRLS'],
        ['gp_platform', 'NOLOGIN BYPASSRLS'], ['gp_reporting', 'NOLOGIN NOBYPASSRLS'], ['gp_mqtt', 'NOLOGIN NOBYPASSRLS']] LOOP
      IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = spec[1]) THEN
        EXECUTE format('CREATE ROLE %I %s', spec[1], spec[2]);
      END IF;
    END LOOP;
  END
  $roles$;
  GRANT gp_owner, gp_app, gp_platform, gp_reporting, gp_mqtt TO getproperty;
SQL

if [ -n "${GETPROPERTY_MQTT_DB_PASSWORD:-}" ]; then
  psql -v ON_ERROR_STOP=1 --username postgres --dbname postgres -v pw="$GETPROPERTY_MQTT_DB_PASSWORD" <<-'SQL'
    SELECT format('CREATE ROLE getproperty_mqtt LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS PASSWORD %L', :'pw')
     WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'getproperty_mqtt') \gexec
    SELECT format('ALTER ROLE getproperty_mqtt PASSWORD %L', :'pw') \gexec
    GRANT gp_mqtt TO getproperty_mqtt;
    GRANT CONNECT ON DATABASE getproperty TO getproperty_mqtt;
    ALTER ROLE getproperty_mqtt SET statement_timeout = '2s';
SQL
else
  echo "20-getproperty: GETPROPERTY_MQTT_DB_PASSWORD empty — EMQX authorization login not created (gateways are denied)"
fi

# Extensions the getproperty migrations use (trusted ones the owner could create too; timescaledb is not trusted)
for ext in timescaledb pgcrypto citext btree_gist pg_trgm; do
  psql -v ON_ERROR_STOP=1 --username postgres --dbname getproperty -c "CREATE EXTENSION IF NOT EXISTS ${ext};"
done
echo "getproperty roles initialised"
