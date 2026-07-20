#!/usr/bin/env bash
# redis-stalwart-entrypoint.sh — thin wrapper around the official redis
# entrypoint that builds the redis-server invocation for Stalwart's
# dedicated Redis pair. It is the entrypoint for the `stalwart-redis`
# service in stalwart-redis/docker-compose.yml.
#
# Mirrors shared-db/pg-entrypoint.sh's role split, but Redis's own
# replication is simpler than pg_basebackup: passing --replicaof at startup
# is enough — redis-server performs the full sync itself (and any future
# partial resyncs against its backlog) with no manual clone step, and no
# separate "rejoin" command after a promotion (see README "Stalwart Redis
# high availability").
#
# Behaviour by role (STALWART_REDIS_ROLE, default "primary"):
#   - primary (or unset): plain redis-server, no --replicaof. Single-node
#     deployments are unchanged.
#   - standby: adds --replicaof <STALWART_REDIS_PRIMARY_MAGIC_NAME>.<TS_TAILNET> 6379
#     and --masterauth (same password as --requirepass, so a promotion needs
#     no credential change). Comes up read-only, streaming from the primary.
#     Promote with: ./bootstrap.sh stalwart-redis-promote
#
# See README "Stalwart Redis high availability".
set -euo pipefail

: "${STALWART_REDIS_PASSWORD:?STALWART_REDIS_PASSWORD must be set in .env}"

args=(redis-server --appendonly yes --protected-mode no --requirepass "${STALWART_REDIS_PASSWORD}")

if [ "${STALWART_REDIS_ROLE:-primary}" = "standby" ]; then
  : "${STALWART_REDIS_PRIMARY_MAGIC_NAME:?standby requires STALWART_REDIS_PRIMARY_MAGIC_NAME in .env}"
  : "${TS_TAILNET:?standby requires TS_TAILNET in .env}"
  primary_host="${STALWART_REDIS_PRIMARY_MAGIC_NAME}.${TS_TAILNET}"
  echo "[redis-stalwart-entrypoint] standby: replicating from ${primary_host}:6379"
  args+=(--replicaof "${primary_host}" 6379 --masterauth "${STALWART_REDIS_PASSWORD}")
fi

exec docker-entrypoint.sh "${args[@]}"
