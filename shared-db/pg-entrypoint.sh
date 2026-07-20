#!/usr/bin/env bash
# pg-entrypoint.sh — thin wrapper around the official postgres entrypoint that
# adds streaming-standby bootstrap. It is the entrypoint for the `postgres`
# service in shared-db/docker-compose.yml.
#
# Behaviour by role (PG_ROLE, default "primary"):
#   - primary (or unset): a pure pass-through — it just execs the stock
#     docker-entrypoint.sh, so single-node deployments are byte-for-byte
#     unchanged (initdb on an empty volume, then start).
#   - standby, empty data dir: pg_basebackup-clones from the primary
#     (PG_PRIMARY_MAGIC_NAME) using the replication role, writing
#     standby.signal + primary_conninfo (pg_basebackup -R). The stock
#     entrypoint then starts Postgres, which comes up as a hot standby.
#   - standby, already-cloned: pass-through; Postgres resumes streaming.
#
# The primary must already have the replication role + slot (bootstrap.sh
# creates them on `up shared-db` when REPLICATION_PASSWORD is set) and must be
# reachable over the tailnet — this runs inside the ts-postgres sidecar netns,
# which depends_on the sidecar being healthy, so MagicDNS resolves here.
#
# See README "Postgres high availability".
set -euo pipefail

PGDATA="${PGDATA:-/var/lib/postgresql/data}"

if [ "${PG_ROLE:-primary}" = "standby" ] && [ -z "$(ls -A "$PGDATA" 2>/dev/null)" ]; then
  : "${PG_PRIMARY_MAGIC_NAME:?standby requires PG_PRIMARY_MAGIC_NAME in .env}"
  : "${TS_TAILNET:?standby requires TS_TAILNET in .env}"
  : "${REPLICATION_PASSWORD:?standby requires REPLICATION_PASSWORD in .env}"

  primary_host="${PG_PRIMARY_MAGIC_NAME}.${TS_TAILNET}"
  slot="${PG_REPLICATION_SLOT:-standby_slot}"
  echo "[pg-entrypoint] standby: cloning from ${primary_host} via pg_basebackup (slot ${slot})..."

  # Run the clone as root (pg_basebackup is a plain client tool), then hand
  # ownership to the postgres user so the server can start. This avoids any
  # gosu/su-exec-in-alpine ambiguity — the stock entrypoint starts the server
  # as postgres from a correctly-owned, already-initialised data dir.
  mkdir -p "$PGDATA"
  PGPASSWORD="$REPLICATION_PASSWORD" pg_basebackup \
    --host="$primary_host" \
    --port=5432 \
    --username="${REPLICATION_USER:-replicator}" \
    --pgdata="$PGDATA" \
    --wal-method=stream \
    --progress \
    --write-recovery-conf \
    --slot="$slot" \
    --no-password
  chown -R postgres:postgres "$PGDATA"
  chmod 0700 "$PGDATA"
  echo "[pg-entrypoint] clone complete — standby.signal + primary_conninfo written."
fi

exec docker-entrypoint.sh "$@"
