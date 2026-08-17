#!/usr/bin/env bash
# =============================================================================
# Extra init commands, run automatically by the official Postgres entrypoint
# on FIRST container start (same lifecycle as schema.sql — only runs once,
# when the data directory is still empty).
#
# Naming: prefixed "02-" so it runs AFTER 01-schema.sql (files in
# /docker-entrypoint-initdb.d/ run in alphabetical order). Add more scripts
# the same way: 03-seed-data.sh, 04-create-readonly-user.sql, etc.
#
# Anything you can do in bash is fair game here: create extra roles, seed
# reference data, set GUCs that need a running server, call `psql`, curl a
# file, etc. Keep it idempotent (safe to imagine running twice) since it's
# good practice even though the entrypoint only calls it once per fresh volume.
# =============================================================================
set -euo pipefail

echo "[02-extra-setup] running extra init commands..."

# Example 1 — run arbitrary SQL against the DB that was just created
# ($POSTGRES_USER / $POSTGRES_DB are already exported by the base image).
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    -- example: a read-only role for reporting/BI tools, separate from the app user
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'it_kb_readonly') THEN
            CREATE ROLE it_kb_readonly LOGIN PASSWORD 'change_me';
        END IF;
    END
    \$\$;
    GRANT CONNECT ON DATABASE "$POSTGRES_DB" TO it_kb_readonly;
    GRANT USAGE ON SCHEMA public TO it_kb_readonly;
    GRANT SELECT ON ALL TABLES IN SCHEMA public TO it_kb_readonly;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO it_kb_readonly;
EOSQL

# Example 2 — plain shell commands, e.g. warm up a directory the app expects,
# or print extension versions for the container logs.
mkdir -p /var/lib/postgresql/data/it_kb_extra
psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT extname, extversion FROM pg_extension;"

echo "[02-extra-setup] done."
