#!/bin/bash
# getproperty's database roles (getproperty-api docs/deployment.md §3). Runs once on an empty data directory after
# 10-products.sh; idempotent, so on a box initialised before this file existed run it by hand (SSM):
#   docker exec platform-postgres-1 bash /docker-entrypoint-initdb.d/20-getproperty.sh
#
# The product login `getproperty` is NOCREATEROLE and its migrations (@collective/asset-core 0001, app 0010) expect
# these NOLOGIN group roles; gp_platform needs BYPASSRLS, which only a superuser can grant. The app runs as
# `getproperty` and switches per transaction (`SET LOCAL ROLE gp_app` / `gp_platform`: DATABASE_APP_ROLE /
# DATABASE_PLATFORM_ROLE in the app secret), so row-level security applies to every tenant query.
# EMQX no longer reads PostgreSQL (getproperty-api D-235, blueprint T-7: HTTP authn/authz on getproperty-api), so
# there is no broker login. `gp_mqtt` survives only as a NOLOGIN role without members: getproperty-api's migration 0010
# (immutable, applied by the NOCREATEROLE product login) still grants to it and creates a policy for it; drop it by
# hand once getproperty-api ships the migration that removes that policy (docs/PROGRESS.md, needs from getproperty-api).
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
  GRANT gp_owner, gp_app, gp_platform, gp_reporting TO getproperty;
SQL

# Boxes initialised with the PostgreSQL ACL source (before T-7): retire EMQX's login. Idempotent.
psql -v ON_ERROR_STOP=1 --username postgres --dbname postgres <<-'SQL'
  DO $retire$
  BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'getproperty_mqtt') THEN
      REVOKE CONNECT ON DATABASE getproperty FROM getproperty_mqtt;
      DROP ROLE getproperty_mqtt;
    END IF;
  END
  $retire$;
SQL

# Extensions the getproperty migrations use (trusted ones the owner could create too; timescaledb is not trusted)
for ext in timescaledb pgcrypto citext btree_gist pg_trgm; do
  psql -v ON_ERROR_STOP=1 --username postgres --dbname getproperty -c "CREATE EXTENSION IF NOT EXISTS ${ext};"
done
echo "getproperty roles initialised"
