#!/usr/bin/env bash
# pg-restore.sh — restore a Postgres dump produced by pg-backup.sh.
#
# ############################################################################
# # DESTRUCTIVE. A pg_dumpall restore replays roles and databases into the    #
# # live cluster — it can clobber existing data and roles. Read what it       #
# # prints, confirm the prompt, and prefer a throwaway test cluster the       #
# # first time. See the README "Backups" section.                             #
# ############################################################################
#
# Usage:
#   ./backup/pg-restore.sh                       # restore the LATEST backup
#   ./backup/pg-restore.sh pg-20260613-030000.sql.gz   # a specific object
#   ./backup/pg-restore.sh --list                # list available backups
#
# What it does:
#   1. Resolves the backup key (latest, or the one you named).
#   2. Streams it from Garage, gunzips, and pipes into `psql -U postgres`
#      inside the shared-db postgres container.
#   pg_dumpall output is plain SQL (CREATE ROLE / CREATE DATABASE / \connect /
#   COPY ...), so psql against the maintenance DB replays the whole cluster.
#
# Requirements: same as pg-backup.sh (run on the shared-db host; Garage
# reachable; PG_BACKUP_GARAGE_KEY_ID/SECRET in .env).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"

[[ -f "$ENV_FILE" ]] || { echo "Error: ${ENV_FILE} not found." >&2; exit 1; }
set -a; source "$ENV_FILE"; set +a

PG_BACKUP_BUCKET="${PG_BACKUP_BUCKET:-pg-backups}"
PG_BACKUP_PREFIX="${PG_BACKUP_PREFIX:-pg-}"
GARAGE_REGION="${GARAGE_REGION:-garage}"
AWSCLI_IMAGE="${AWSCLI_IMAGE:-amazon/aws-cli:latest}"
# GARAGE_S3_ENDPOINT_NAME defaults to the single node ("garage"); in a
# multi-node cluster set it to the reverse-proxy host so restores read through
# the HA S3 load-balancer (README "Highly available S3 endpoint").
GARAGE_ENDPOINT="http://${GARAGE_S3_ENDPOINT_NAME:-garage}.${TS_TAILNET}:3900"

for v in TS_TAILNET PG_BACKUP_GARAGE_KEY_ID PG_BACKUP_GARAGE_KEY_SECRET; do
  [[ -n "${!v:-}" ]] || { echo "Error: ${v} is not set in .env" >&2; exit 1; }
done

log() { echo "[pg-restore] $*"; }

aws_garage() {
  docker run --rm -i --network host \
    -e AWS_ACCESS_KEY_ID="${PG_BACKUP_GARAGE_KEY_ID}" \
    -e AWS_SECRET_ACCESS_KEY="${PG_BACKUP_GARAGE_KEY_SECRET}" \
    -e AWS_DEFAULT_REGION="${GARAGE_REGION}" \
    "${AWSCLI_IMAGE}" \
    --endpoint-url "${GARAGE_ENDPOINT}" "$@"
}

list_backups() {
  aws_garage s3 ls "s3://${PG_BACKUP_BUCKET}/${PG_BACKUP_PREFIX}" 2>/dev/null \
    | awk '{print $NF}' | sort
}

if [[ "${1:-}" == "--list" ]]; then
  log "Backups in s3://${PG_BACKUP_BUCKET}/:"
  list_backups
  exit 0
fi

KEY="${1:-}"
if [[ -z "$KEY" ]]; then
  KEY="$(list_backups | tail -1)"
  [[ -n "$KEY" ]] || { echo "Error: no backups found in s3://${PG_BACKUP_BUCKET}/" >&2; exit 1; }
  log "No key given — using the latest: ${KEY}"
fi

PG_CONTAINER="$(docker compose \
  -f "${REPO_ROOT}/shared-db/docker-compose.yml" \
  --env-file "${ENV_FILE}" ps -q postgres 2>/dev/null | head -1)"
[[ -n "$PG_CONTAINER" ]] || {
  echo "Error: postgres container not found. Is shared-db running on this host?" >&2
  exit 1
}

echo ""
echo "  !!  About to restore s3://${PG_BACKUP_BUCKET}/${KEY}"
echo "  !!  into the LIVE Postgres cluster (${DB_MAGIC_NAME:-shared-db})."
echo "  !!  This replays roles and databases and can OVERWRITE existing data."
echo ""
read -r -p "Type 'restore' to proceed: " confirm
[[ "$confirm" == "restore" ]] || { echo "Aborted."; exit 1; }

log "Restoring ${KEY}..."
set -o pipefail
if aws_garage s3 cp "s3://${PG_BACKUP_BUCKET}/${KEY}" - \
     | gunzip \
     | docker exec -i "$PG_CONTAINER" psql -U postgres -v ON_ERROR_STOP=0; then
  log "Restore finished. Review psql output above for any errors."
else
  echo "Error: restore pipeline failed (download, gunzip, or psql)." >&2
  exit 1
fi
