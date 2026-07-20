#!/usr/bin/env bash
# pg-backup.sh — dump all Postgres databases and ship the gzipped dump to the
# Garage `pg-backups` bucket over the tailnet. Designed for unattended cron.
#
# What it does:
#   1. pg_dumpall (roles + all databases) inside the shared-db postgres
#      container — the same container bootstrap.sh provisions into.
#   2. gzip the stream.
#   3. Upload to s3://${PG_BACKUP_BUCKET}/pg-YYYYmmdd-HHMMSS.sql.gz via the
#      aws-cli, pointed at the Garage S3 endpoint over the tailnet.
#   4. Prune objects older than ${PG_BACKUP_RETENTION_DAYS}.
#
# Nothing is written to local disk — the dump streams straight to Garage.
#
# Exits non-zero on any failure. Note cron mails OUTPUT, not exit codes —
# the backup-cron helper's crontab line turns a failure into one stdout line
# so MAILTO actually fires (all normal output goes to log/pg-backup.log).
#
# Requirements:
#   - Run on the host where shared-db is running (uses docker exec).
#   - That host on the tailnet with an ACL grant to reach tag:garage:3900.
#     The admin-owned host already has this; a dedicated backup host needs a
#     grant added to acl.example.hujson.
#   - docker available; the aws-cli runs as a throwaway container
#     (amazon/aws-cli) so nothing extra is installed on the host.
#   - provision-garage has run (creates the pg-backups bucket + key) and
#     PG_BACKUP_GARAGE_KEY_ID / PG_BACKUP_GARAGE_KEY_SECRET are set in .env.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"

[[ -f "$ENV_FILE" ]] || { echo "Error: ${ENV_FILE} not found." >&2; exit 1; }
set -a; source "$ENV_FILE"; set +a

# ---- Config (override in .env if you like) --------------------------------
PG_BACKUP_BUCKET="${PG_BACKUP_BUCKET:-pg-backups}"
PG_BACKUP_RETENTION_DAYS="${PG_BACKUP_RETENTION_DAYS:-14}"
PG_BACKUP_PREFIX="${PG_BACKUP_PREFIX:-pg-}"
GARAGE_REGION="${GARAGE_REGION:-garage}"
# Pinned deliberately: :latest silently broke this backup for two days when
# aws-cli 2.23 flipped on default checksums (see aws_garage below). This is the
# fleet's last-line DB safety net, so reproducibility beats auto-patching; the
# container only signs requests to Garage over the tailnet, so CVE latency is a
# non-issue. Bump intentionally, verify, then move the pin. Override via .env.
AWSCLI_IMAGE="${AWSCLI_IMAGE:-amazon/aws-cli:2.35.8}"

# GARAGE_S3_ENDPOINT_NAME defaults to the single node ("garage"); in a
# multi-node cluster set it to the reverse-proxy host so backups ship through
# the HA S3 load-balancer (README "Highly available S3 endpoint").
GARAGE_ENDPOINT="http://${GARAGE_S3_ENDPOINT_NAME:-garage}.${TS_TAILNET}:3900"

for v in TS_TAILNET PG_BACKUP_GARAGE_KEY_ID PG_BACKUP_GARAGE_KEY_SECRET DB_MAGIC_NAME; do
  [[ -n "${!v:-}" ]] || { echo "Error: ${v} is not set in .env" >&2; exit 1; }
done

log() { echo "[pg-backup] $*"; }

# aws-cli pointed at Garage, networked through the host so MagicDNS resolves.
# Reads stdin when called in a pipe (the cp - case below passes -i).
#
# AWS_{REQUEST,RESPONSE}_CHECKSUM_* = when_required: aws-cli v2.23+ (Jan 2025)
# turned on default CRC32 data-integrity checksums, which Garage rejects on
# CreateMultipartUpload with "Bad request: invalid checksum algorithm". Since
# AWSCLI_IMAGE tracks :latest, that break arrives silently on any pull. Scoping
# checksums to when_required restores S3-compat without pinning the image.
aws_garage() {
  docker run --rm -i --network host \
    -e AWS_ACCESS_KEY_ID="${PG_BACKUP_GARAGE_KEY_ID}" \
    -e AWS_SECRET_ACCESS_KEY="${PG_BACKUP_GARAGE_KEY_SECRET}" \
    -e AWS_DEFAULT_REGION="${GARAGE_REGION}" \
    -e AWS_REQUEST_CHECKSUM_CALCULATION=when_required \
    -e AWS_RESPONSE_CHECKSUM_VALIDATION=when_required \
    "${AWSCLI_IMAGE}" \
    --endpoint-url "${GARAGE_ENDPOINT}" "$@"
}

# ---- Locate the postgres container ----------------------------------------
PG_CONTAINER="$(docker compose \
  -f "${REPO_ROOT}/shared-db/docker-compose.yml" \
  --env-file "${ENV_FILE}" ps -q postgres 2>/dev/null | head -1)"
[[ -n "$PG_CONTAINER" ]] || {
  echo "Error: postgres container not found. Is shared-db running on this host?" >&2
  exit 1
}

# ---- Dump → gzip → upload (no local temp file) ----------------------------
KEY="${PG_BACKUP_PREFIX}$(date -u +%Y%m%d-%H%M%S).sql.gz"
log "Dumping all databases from ${DB_MAGIC_NAME} → s3://${PG_BACKUP_BUCKET}/${KEY}"

set -o pipefail
if docker exec "$PG_CONTAINER" pg_dumpall -U postgres \
     | gzip \
     | aws_garage s3 cp - "s3://${PG_BACKUP_BUCKET}/${KEY}"; then
  log "Upload complete: ${KEY}"
else
  echo "Error: backup pipeline failed (dump, gzip, or upload). Nothing pruned." >&2
  exit 1
fi

# ---- Prune old backups ----------------------------------------------------
# Key format is ${PREFIX}YYYYmmdd-HHMMSS.sql.gz, so the date is embedded and
# we don't depend on S3 LastModified. Compare the embedded YYYYmmdd to a
# cutoff and delete anything older.
cutoff="$(date -u -d "${PG_BACKUP_RETENTION_DAYS} days ago" +%Y%m%d 2>/dev/null \
          || date -u -v-"${PG_BACKUP_RETENTION_DAYS}"d +%Y%m%d)"  # GNU || BSD date
log "Pruning backups older than ${cutoff} (retention ${PG_BACKUP_RETENTION_DAYS}d)..."

# `s3 ls` prints: <date> <time> <size> <key>
aws_garage s3 ls "s3://${PG_BACKUP_BUCKET}/${PG_BACKUP_PREFIX}" 2>/dev/null \
  | awk '{print $NF}' \
  | while read -r key; do
      [[ -n "$key" ]] || continue
      # Extract the YYYYmmdd that follows the prefix.
      datepart="$(printf '%s' "$key" | sed -nE "s/^${PG_BACKUP_PREFIX}([0-9]{8})-.*/\1/p")"
      [[ -n "$datepart" ]] || continue
      if [[ "$datepart" -lt "$cutoff" ]]; then
        log "  deleting ${key}"
        aws_garage s3 rm "s3://${PG_BACKUP_BUCKET}/${key}" >/dev/null
      fi
    done

log "Done."
