#!/bin/bash
# Runs once on an empty data directory (docker-entrypoint-initdb.d), and is safe to re-run by hand:
#   docker exec platform-postgres-1 bash /docker-entrypoint-initdb.d/10-products.sh One database + one owner role
# per product. Extensions are created per database so each product can be peeled off to RDS later.
set -euo pipefail

create_product() {
  local name="$1" password="$2" extensions="$3"
  [ -n "$password" ] || { echo "ERROR: empty password for ${name} (check platform/postgres secret)"; exit 1; }
  psql -v ON_ERROR_STOP=1 --username postgres --dbname postgres -v name="$name" -v pw="$password" <<-'SQL'
    SELECT format('CREATE ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE', :'name') WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'name')\gexec
    SELECT format('ALTER ROLE %I PASSWORD %L', :'name', :'pw')\gexec
    SELECT format('CREATE DATABASE %I OWNER %I ENCODING ''UTF8'' LC_COLLATE ''C.UTF-8'' LC_CTYPE ''C.UTF-8'' TEMPLATE template0', :'name', :'name') WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'name')\gexec
    SELECT format('CREATE DATABASE %I OWNER %I TEMPLATE template0', :'name' || '_shadow', :'name') WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'name' || '_shadow')\gexec
    SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC', :'name')\gexec
SQL
  for db in "${name}" "${name}_shadow"; do
    for ext in ${extensions}; do
      psql -v ON_ERROR_STOP=1 -q --username postgres --dbname "$db" -c "CREATE EXTENSION IF NOT EXISTS ${ext};"
    done
  done
  psql -v ON_ERROR_STOP=1 -q --username postgres --dbname "${name}" <<-SQL
    ALTER SCHEMA public OWNER TO ${name};
    ALTER DEFAULT PRIVILEGES FOR ROLE ${name} IN SCHEMA public GRANT ALL ON TABLES TO ${name};
SQL
}

create_product getpack     "${GETPACK_DB_PASSWORD}"     "vector pg_stat_statements pgcrypto citext"
create_product getproperty "${GETPROPERTY_DB_PASSWORD}" "timescaledb vector pg_stat_statements pgcrypto citext"
create_product getbuild      "${GETBUILD_DB_PASSWORD}"      "vector pg_stat_statements pgcrypto citext"

psql -v ON_ERROR_STOP=1 --username postgres --dbname postgres -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"

# pgBackRest stanza (repo on S3 via instance role)
pgbackrest --stanza=collective --log-level-console=info stanza-create || echo "stanza-create skipped (will retry via systemd timer)"
echo "products initialised"
