# =============================================================================
# Postgres + pgvector server for the IT KB Pipeline
#
# Build:
#   docker build -t it-kb-postgres -f db/Dockerfile .
#
# Run:
#   docker run -d --name it-kb-postgres \
#     -e POSTGRES_USER=postgres \
#     -e POSTGRES_PASSWORD=postgres \
#     -e POSTGRES_DB=it_kb \
#     -p 5432:5432 \
#     -v it_kb_pgdata:/var/lib/postgresql/data \
#     it-kb-postgres
#
# `db/schema.sql` is copied into /docker-entrypoint-initdb.d/, which Postgres's
# official image runs automatically ONLY on first init (empty data dir) —
# so `CREATE EXTENSION vector` + all tables in schema.sql are created for you
# the first time the container starts. Re-running the container against an
# existing volume will NOT re-run it (this is standard Postgres image
# behavior) — see README section below for how to re-apply schema changes.
# =============================================================================

# pgvector/pgvector ships official Postgres builds with the pgvector
# extension already compiled in — no manual `CREATE EXTENSION` build step
# needed. Pick the Postgres major version here (16 matches the design doc's
# assumptions; change if your environment needs a different version).
FROM pgvector/pgvector:pg16

# Values below are DEFAULTS only — override at `docker run -e ...` or in
# docker-compose.yml. They must NOT be treated as production secrets.
ENV POSTGRES_USER=postgres \
    POSTGRES_PASSWORD=postgres \
    POSTGRES_DB=it_kb

# Copied first so it always runs before any project-specific init logic.
# Files in /docker-entrypoint-initdb.d/ run in alphabetical order — the
# leading "01-" keeps this ahead of anything else you might add later
# (e.g. seed data scripts named 02-seed.sql).
COPY schema.sql /docker-entrypoint-initdb.d/01-schema.sql

# Extra shell commands, run right after schema.sql on first boot (see the
# script's own comments for what it does / how to add more). Must be
# executable, or the entrypoint silently skips it.
COPY 02-extra-setup.sh /docker-entrypoint-initdb.d/02-extra-setup.sh
RUN chmod +x /docker-entrypoint-initdb.d/02-extra-setup.sh

EXPOSE 5432

# pgvector does NOT require shared_preload_libraries (no background workers
# by default), so the stock entrypoint/CMD from the base image is fine as-is.
# Override only if you need to tune Postgres further, e.g.:
#   CMD ["postgres", "-c", "max_connections=100", "-c", "shared_buffers=256MB"]
