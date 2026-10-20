#!/bin/bash
# Runs once on an empty data directory (docker-entrypoint-initdb.d). One database + one owner role
# per product. Extensions are created per database so each product can be peeled off to RDS later.
set -euo pipefail

create_product() {
  local name="$1" password="$2" extensions="$3"
  psql -v ON_ERROR_STOP=1 --username postgres --dbname postgres <<-SQL
    CREATE ROLE ${name} LOGIN PASSWORD '${password}' NOSUPERUSER NOCREATEDB NOCREATEROLE;
    CREATE DATABASE ${name} OWNER ${name} ENCODING 'UTF8' LC_COLLATE 'C.UTF-8' LC_CTYPE 'C.UTF-8' TEMPLATE template0;
    REVOKE ALL ON DATABASE ${name} FROM PUBLIC;
    -- Prisma shadow database for migrate dev (UAT only; harmless in prod)
    CREATE DATABASE ${name}_shadow OWNER ${name} TEMPLATE template0;
SQL
  for ext in ${extensions}; do
    psql -v ON_ERROR_STOP=1 --username postgres --dbname "${name}" -c "CREATE EXTENSION IF NOT EXISTS ${ext};"
    psql -v ON_ERROR_STOP=1 --username postgres --dbname "${name}_shadow" -c "CREATE EXTENSION IF NOT EXISTS ${ext};"
  done
  # Default privileges so the product role owns everything it creates; nothing cross-product.
  psql -v ON_ERROR_STOP=1 --username postgres --dbname "${name}" <<-SQL
    ALTER SCHEMA public OWNER TO ${name};
    ALTER DEFAULT PRIVILEGES FOR ROLE ${name} IN SCHEMA public GRANT ALL ON TABLES TO ${name};
SQL
}

create_product getpack     "${GETPACK_DB_PASSWORD}"     "vector pg_stat_statements pgcrypto citext"
create_product getproperty "${GETPROPERTY_DB_PASSWORD}" "timescaledb vector pg_stat_statements pgcrypto citext"
create_product getpop      "${GETPOP_DB_PASSWORD}"      "vector pg_stat_statements pgcrypto citext"

psql -v ON_ERROR_STOP=1 --username postgres --dbname postgres -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"

# pgBackRest stanza (repo on S3 via instance role)
pgbackrest --stanza=collective --log-level-console=info stanza-create || echo "stanza-create skipped (will retry via systemd timer)"
echo "products initialised"
