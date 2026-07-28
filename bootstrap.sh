#!/usr/bin/env bash
# bootstrap.sh — unified operator interface for the federated-social stack.
#
# Wraps per-app CLIs (tootctl, php artisan, funkwhale-manage, rails runner)
# behind a single consistent interface so operators don't have to learn each
# app's tooling separately. The app CLIs remain the source of truth — this
# script just calls them with the right arguments.
#
# Usage:
#   ./bootstrap.sh up   <stack>                  bring up a stack
#   ./bootstrap.sh down <stack>                  tear down a stack
#   ./bootstrap.sh logs <stack> [service]        tail logs
#   ./bootstrap.sh ps   [stack]                  show container status
#   ./bootstrap.sh provision-db <app>            idempotent DB + role setup
#   ./bootstrap.sh provision-garage              idempotent Garage bucket + key setup
#   ./bootstrap.sh provision-stalwart            configure Stalwart via JMAP (auto-run by 'up stalwart')
#   ./bootstrap.sh user-create <app> <username> <email>
#
# <stack>/<app>: shared-db | garage | pixelfed | mastodon | diaspora | funkwhale | gotosocial | peertube | stalwart | authelia | lemmy
#
# Bring-up order: shared-db → garage → app stacks.
#
# provision-db is called automatically by 'up' for app stacks. Run it
# standalone if you add a new app after shared-db has already been running.
#
# provision-garage is called automatically by 'up garage'. Run it standalone
# after first boot to initialize the cluster layout, create buckets, and
# generate the access key. Re-running is idempotent.
#
# user-create requires the stack to already be running (the app sidecar must
# be up for the run container to get network access). Run `up` first.
#
# Passwords are generated randomly and printed once. Save them — there is no
# recovery path from this script. Operators can change passwords via the web
# UI after first login.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${REPO_ROOT}/.env"
# Operator-local log directory. Rootless by design: things like the pg-backup
# cron log here instead of /var/log, so an unprivileged shell account works.
mkdir -p "${REPO_ROOT}/log"
ALL_STACKS=(shared-db garage pixelfed mastodon diaspora funkwhale gotosocial peertube stalwart stalwart-redis stalwart-redis-router authelia lemmy pg-router)
# Stacks that need a Postgres DB provisioned before starting.
DB_STACKS=(pixelfed mastodon diaspora funkwhale gotosocial peertube stalwart authelia lemmy)

# Load .env — required before any command.
if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE"; set +a
  # .env holds every secret in the stack — keep it owner-only. A fresh scp
  # often lands it 0644 (world-readable on a shared box); tighten in place and
  # say so, so the operator knows it happened.
  if [[ "$(stat -c '%a' "$ENV_FILE" 2>/dev/null)" != "600" ]]; then
    chmod 600 "$ENV_FILE" 2>/dev/null \
      && echo "[bootstrap] Tightened ${ENV_FILE} permissions to 600 (it holds every secret)."
  fi
else
  echo "Error: ${ENV_FILE} not found." >&2
  echo "" >&2
  echo "  cp ${REPO_ROOT}/.env.example ${ENV_FILE}" >&2
  echo "  \$EDITOR ${ENV_FILE}" >&2
  echo "" >&2
  echo "Fill in all required values before running bootstrap.sh." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

dc() {
  local stack="$1"; shift
  docker compose \
    -f "${REPO_ROOT}/${stack}/docker-compose.yml" \
    --env-file "$ENV_FILE" \
    "$@"
}

die() { echo "Error: $*" >&2; exit 1; }

# After a failed 'docker compose up', scan sidecar logs for the Tailscale
# "requested tags ... not permitted" error and print an ACL reminder.
_check_ts_auth() {
  local stack="$1"
  # Brief pause — Tailscale may crash immediately on a tag rejection and the
  # log buffer may not be flushed to the daemon by the time we call `logs`.
  sleep 2
  local logs
  logs=$(dc "$stack" logs 2>/dev/null || true)
  if echo "$logs" | grep -qi "requested tags.*invalid\|not permitted"; then
    echo "" >&2
    echo "[bootstrap] Tailscale tag error: the tag(s) for '${stack}' are not in your ACL." >&2
    echo "[bootstrap]   1. Open acl.example.hujson and find the tag(s) for '${stack}'" >&2
    echo "[bootstrap]   2. Add them to tagOwners in the Tailscale admin console:" >&2
    echo "[bootstrap]      https://login.tailscale.com/admin/acls" >&2
    echo "[bootstrap]   3. Re-run: ./bootstrap.sh up ${stack}" >&2
    echo "" >&2
  else
    echo "[bootstrap] Start failed. Check logs: ./bootstrap.sh logs ${stack}" >&2
  fi
}

require_stack() {
  local stack="$1"
  local valid=0
  for s in "${ALL_STACKS[@]}"; do [[ "$s" == "$stack" ]] && valid=1; done
  [[ $valid -eq 1 ]] || die "Unknown stack '${stack}'. Valid: ${ALL_STACKS[*]}"
}

# ---------------------------------------------------------------------------
# DB provisioning helpers — idempotent, safe to re-run at any time.
# ---------------------------------------------------------------------------

# Run psql as superuser inside the shared-db postgres container.
_pg_exec() {
  local container
  container=$(dc shared-db ps -q postgres 2>/dev/null | head -1)
  [[ -n "$container" ]] || die "Postgres container not found. Is shared-db running? ./bootstrap.sh up shared-db"
  docker exec -i "$container" psql -v ON_ERROR_STOP=1 --username postgres "$@"
}

# Idempotent role + database: creates on first run, updates password on re-runs.
_provision_role_db() {
  local user="$1" password="$2" dbname="$3"
  echo "[bootstrap] Provisioning role '${user}' and database '${dbname}'..."
  _pg_exec --dbname postgres <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${user}') THEN
    CREATE ROLE "${user}" LOGIN PASSWORD '${password}';
  ELSE
    ALTER ROLE "${user}" WITH LOGIN PASSWORD '${password}';
  END IF;
END
\$\$;
SELECT 'CREATE DATABASE "${dbname}" OWNER "${user}"'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${dbname}')\gexec
GRANT ALL PRIVILEGES ON DATABASE "${dbname}" TO "${user}";
SQL
}

# Idempotent extension install (requires superuser, hence run here not by app).
_provision_extension() {
  local dbname="$1" ext="$2"
  _pg_exec --dbname "$dbname" -c "CREATE EXTENSION IF NOT EXISTS \"${ext}\";"
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_provision_db() {
  local app="${1:-}"
  [[ -n "$app" ]] || die "Usage: ./bootstrap.sh provision-db <app>"

  case "$app" in
    shared-db)
      echo "[bootstrap] shared-db has no app database to provision."
      ;;
    pixelfed)
      _provision_role_db "${PIXELFED_DB_USER}" "${PIXELFED_DB_PASSWORD}" "${PIXELFED_DB_NAME}"
      ;;
    mastodon)
      _provision_role_db "${MASTODON_DB_USER}" "${MASTODON_DB_PASSWORD}" "${MASTODON_DB_NAME}"
      ;;
    diaspora)
      _provision_role_db "${DIASPORA_DB_USER}" "${DIASPORA_DB_PASSWORD}" "${DIASPORA_DB_NAME}"
      ;;
    funkwhale)
      _provision_role_db "${FUNKWHALE_DB_USER}" "${FUNKWHALE_DB_PASSWORD}" "${FUNKWHALE_DB_NAME}"
      ;;
    gotosocial)
      _provision_role_db "${GOTOSOCIAL_DB_USER}" "${GOTOSOCIAL_DB_PASSWORD}" "${GOTOSOCIAL_DB_NAME}"
      ;;
    peertube)
      _provision_role_db "${PEERTUBE_DB_USER}" "${PEERTUBE_DB_PASSWORD}" "${PEERTUBE_DB_NAME}"
      _provision_extension "${PEERTUBE_DB_NAME}" pg_trgm
      _provision_extension "${PEERTUBE_DB_NAME}" unaccent
      _provision_extension "${PEERTUBE_DB_NAME}" uuid-ossp
      ;;
    stalwart)
      _provision_role_db "${STALWART_DB_USER:-stalwart}" "${STALWART_DB_PASSWORD}" "${STALWART_DB_NAME:-stalwart}"
      ;;
    authelia)
      _provision_role_db "${AUTHELIA_DB_USER:-authelia}" "${AUTHELIA_DB_PASSWORD}" "${AUTHELIA_DB_NAME:-authelia}"
      ;;
    lemmy)
      _provision_role_db "${LEMMY_DB_USER:-lemmy}" "${LEMMY_DB_PASSWORD}" "${LEMMY_DB_NAME:-lemmy}"
      ;;
    *)
      die "Unknown app '${app}'. Valid: pixelfed mastodon diaspora funkwhale gotosocial peertube stalwart authelia lemmy"
      ;;
  esac
  echo "[bootstrap] DB provisioning complete for ${app}."
}

cmd_provision_garage() {
  local container
  container=$(dc garage ps -q garage 2>/dev/null | head -1)
  [[ -n "$container" ]] || die "Garage is not running. Start it first: ./bootstrap.sh up garage"

  # Confirm the container is actually running, not just Created/Exited.
  local running
  running=$(docker inspect "$container" --format='{{.State.Running}}' 2>/dev/null || echo "false")
  [[ "$running" == "true" ]] || die "Garage container exists but is not running (state: $(docker inspect "$container" --format='{{.State.Status}}' 2>/dev/null)). Try: ./bootstrap.sh up garage"

  # Inline Garage CLI wrapper — all garage commands run inside the container.
  # The dxflrs/garage image places the binary at /garage (not on $PATH).
  _g() { docker exec "$container" /garage "$@"; }

  echo "[bootstrap] Checking Garage cluster layout..."

  local rf="${GARAGE_REPLICATION_FACTOR:-1}"
  [[ "$rf" =~ ^[0-9]+$ ]] || die "GARAGE_REPLICATION_FACTOR must be a positive integer (got '${rf}')."

  # Garage v1.0.x prints: ==== CURRENT CLUSTER LAYOUT (version N) ====
  _garage_layout_version() {
    _g layout show 2>/dev/null \
      | grep -i "CURRENT CLUSTER LAYOUT" | grep -oE '[0-9]+' | head -1
  }
  # Zone for a node name: from GARAGE_CLUSTER_ZONES ("name:zone name:zone ...");
  # default is the node's own name, so each node is its own failure domain.
  _garage_zone_for() {
    local want="$1" entry
    for entry in ${GARAGE_CLUSTER_ZONES:-}; do
      [[ "${entry%%:*}" == "$want" ]] && { echo "${entry#*:}"; return; }
    done
    echo "$want"
  }

  if [[ "$rf" -gt 1 ]]; then
    # ---- Multi-node cluster layout ----------------------------------------
    [[ -n "${GARAGE_BOOTSTRAP_PEERS:-}" ]] || \
      die "Cluster mode (GARAGE_REPLICATION_FACTOR=${rf}) needs GARAGE_BOOTSTRAP_PEERS in .env.
  Boot every node once ('./bootstrap.sh up garage' per host), run
  './bootstrap.sh garage-peer-id' on each, set the combined comma-separated
  list as GARAGE_BOOTSTRAP_PEERS in every host's .env, re-run 'up garage',
  then run this command once."

    local _peers=() _p
    IFS=',' read -ra _peers <<< "${GARAGE_BOOTSTRAP_PEERS}"
    local _clean=()
    for _p in "${_peers[@]}"; do _p="$(echo "$_p" | xargs)"; [[ -n "$_p" ]] && _clean+=("$_p"); done
    _peers=("${_clean[@]}")
    local _n=${#_peers[@]}
    [[ "$_n" -ge "$rf" ]] || \
      die "GARAGE_BOOTSTRAP_PEERS lists ${_n} node(s) but replication_factor is ${rf} (need >= ${rf})."

    echo "[bootstrap] Cluster mode: ${_n} nodes, replication_factor ${rf}."
    # Connect to every peer (idempotent — bootstrap_peers usually did this).
    for _p in "${_peers[@]}"; do _g node connect "$_p" >/dev/null 2>&1 || true; done

    # Wait until all N nodes are visible in the cluster.
    echo "[bootstrap] Waiting for all ${_n} nodes to connect (up to 120s)..."
    local _elapsed=0 _interval=5 _timeout=120 _seen=0
    while true; do
      _seen=$(_g status 2>/dev/null | grep -icE '^[[:space:]]*[0-9a-f]{6,}@?' || true)
      [[ "${_seen:-0}" -ge "$_n" ]] && break
      _elapsed=$(( _elapsed + _interval ))
      if [[ $_elapsed -ge $_timeout ]]; then
        die "Only ${_seen}/${_n} Garage nodes connected after ${_timeout}s.
  - Is every node up?           ./bootstrap.sh ps garage   (on each host)
  - Same GARAGE_BOOTSTRAP_PEERS on every host's .env?
  - ACL grants tag:garage -> tag:garage:3901?"
      fi
      sleep "$_interval"
    done
    echo "[bootstrap] All ${_n} nodes connected."

    # Stage a role for every node: pubkey from the peer string, zone from
    # GARAGE_CLUSTER_ZONES (default = node name), capacity shared. Assigning
    # an unchanged role is a no-op, so this is safe to re-run.
    local _pk _name _zone
    for _p in "${_peers[@]}"; do
      _pk="${_p%%@*}"
      _name="${_p#*@}"; _name="${_name%%.*}"; _name="${_name%%:*}"
      _zone="$(_garage_zone_for "$_name")"
      echo "[bootstrap]   assign ${_name} (zone=${_zone}, capacity=${GARAGE_CAPACITY:-100G})"
      _g layout assign "$_pk" -z "$_zone" -c "${GARAGE_CAPACITY:-100G}" -t "$_name" >/dev/null 2>&1 \
        || echo "[bootstrap]     (unchanged)"
    done

    # Apply only if there are staged changes ('layout show' prints an
    # "apply --version" hint under a STAGED section when so).
    local _cur _next
    _cur="$(_garage_layout_version)"; _cur="${_cur:-0}"
    if _g layout show 2>/dev/null | grep -qiE 'staged|apply --version'; then
      _next=$(( _cur + 1 ))
      echo "[bootstrap] Applying layout version ${_next}..."
      _g layout apply --version "$_next" || die "garage layout apply failed — see ./bootstrap.sh logs garage"
      echo "[bootstrap] Layout applied (version ${_next})."
    else
      echo "[bootstrap] Layout already current (version ${_cur}) — no changes."
    fi
  else
    # ---- Single-node layout (unchanged behaviour) -------------------------
    local layout_version
    layout_version="$(_garage_layout_version)"
    [[ -n "$layout_version" ]] || layout_version="0"

    if [[ "$layout_version" == "0" ]]; then
      echo "[bootstrap] Initializing cluster layout (zone=${GARAGE_ZONE:-dc1}, capacity=${GARAGE_CAPACITY:-100G})..."
      # Run node id without stderr suppression so errors are visible.
      local node_id_raw node_id
      node_id_raw=$(_g node id || true)
      node_id=$(echo "$node_id_raw" | head -1 | cut -d@ -f1)
      if [[ -z "$node_id" ]]; then
        echo "[bootstrap] 'garage node id' output: ${node_id_raw:-<empty>}" >&2
        die "Could not get Garage node ID. Check: ./bootstrap.sh logs garage garage"
      fi
      echo "[bootstrap] Assigning node ${node_id}..."
      if ! _g layout assign "$node_id" \
          --zone     "${GARAGE_ZONE:-dc1}" \
          --capacity "${GARAGE_CAPACITY:-100G}" \
          --tag      "${GARAGE_MAGIC_NAME:-garage}"; then
        die "garage layout assign failed — see output above"
      fi
      echo "[bootstrap] Applying layout version 1..."
      if ! _g layout apply --version 1; then
        die "garage layout apply failed — see output above"
      fi
      echo "[bootstrap] Layout applied (version 1)."
    else
      echo "[bootstrap] Layout already at version ${layout_version} — skipping."
    fi
  fi

  echo "[bootstrap] Ensuring buckets..."
  local buckets=(pg-backups mastodon-media pixelfed-media gotosocial-media stalwart-mail peertube-web-videos peertube-streaming-playlists funkwhale-music lemmy-pictrs)
  for bucket in "${buckets[@]}"; do
    if _g bucket create "$bucket" 2>/dev/null; then
      echo "[bootstrap]   created: ${bucket}"
    else
      echo "[bootstrap]   exists:  ${bucket}"
    fi
  done

  # Per-app access keys — each key can read/write ONLY its own app's
  # buckets (SECURITY.md §5.7). The private stalwart-mail bucket is on a
  # key only Stalwart holds; pg-backups likewise for the backup tooling.
  # A compromised app tier can no longer read other apps' media or the
  # mail store with its S3 credentials.
  _key_env_prefix() {
    case "$1" in
      garage-pixelfed)   echo "PIXELFED_GARAGE_KEY" ;;
      garage-mastodon)   echo "MASTODON_GARAGE_KEY" ;;
      garage-gotosocial) echo "GOTOSOCIAL_GARAGE_KEY" ;;
      garage-funkwhale)  echo "FUNKWHALE_GARAGE_KEY" ;;
      garage-peertube)   echo "PEERTUBE_GARAGE_KEY" ;;
      garage-lemmy)      echo "LEMMY_GARAGE_KEY" ;;
      garage-stalwart)   echo "STALWART_GARAGE_KEY" ;;
      garage-pg-backup)  echo "PG_BACKUP_GARAGE_KEY" ;;
    esac
  }
  _key_buckets() {
    case "$1" in
      garage-pixelfed)   echo "pixelfed-media" ;;
      garage-mastodon)   echo "mastodon-media" ;;
      garage-gotosocial) echo "gotosocial-media" ;;
      garage-funkwhale)  echo "funkwhale-music" ;;
      garage-peertube)   echo "peertube-web-videos peertube-streaming-playlists" ;;
      garage-lemmy)      echo "lemmy-pictrs" ;;
      garage-stalwart)   echo "stalwart-mail" ;;
      garage-pg-backup)  echo "pg-backups" ;;
    esac
  }
  local key_labels=(garage-pixelfed garage-mastodon garage-gotosocial
                    garage-funkwhale garage-peertube garage-lemmy
                    garage-stalwart garage-pg-backup)

  echo "[bootstrap] Ensuring per-app access keys..."
  # Garage allows multiple keys with the same label, so 'key create' always
  # succeeds and mints a new key. Check the key list first.
  local new_env_lines=() kept_keys=() label prefix key_id key_output secret_key b
  for label in "${key_labels[@]}"; do
    prefix=$(_key_env_prefix "$label")
    key_id=$(_g key list 2>/dev/null \
      | awk -v l="$label" 'index($0, l) {print $1; exit}' || true)
    if [[ -n "$key_id" ]]; then
      echo "[bootstrap]   exists:  ${label} (ID: ${key_id})"
      kept_keys+=("${label} ${key_id}")
    else
      key_output=$(_g key create "$label" 2>&1) \
        || die "Failed to create Garage access key ${label}: ${key_output}"
      key_id=$(echo "$key_output" | grep -i "Key ID" | awk '{print $NF}')
      secret_key=$(echo "$key_output" | grep -i "Secret key" | awk '{print $NF}')
      [[ -n "$key_id" && -n "$secret_key" ]] \
        || die "Could not parse key create output for ${label}: ${key_output}"
      echo "[bootstrap]   created: ${label} (ID: ${key_id})"
      new_env_lines+=("${prefix}_ID=${key_id}" "${prefix}_SECRET=${secret_key}")
    fi
    # (Re-)grant the key's own buckets — idempotent, and nothing else.
    for b in $(_key_buckets "$label"); do
      _g bucket allow "$b" --read --write --owner --key "$label" 2>/dev/null || true
    done
  done

  # Pre-split legacy shared key: warn so it gets retired once apps are on
  # their per-app keys. It holds read/write/owner on every bucket.
  local legacy_key_id
  legacy_key_id=$(_g key list 2>/dev/null \
    | awk '/federated-social-apps/ {print $1; exit}' || true)
  if [[ -n "$legacy_key_id" ]]; then
    echo "[bootstrap] NOTE: legacy shared key 'federated-social-apps' (${legacy_key_id})"
    echo "[bootstrap]   still exists and can reach EVERY bucket. After moving all"
    echo "[bootstrap]   apps to the per-app keys above (and a successful pg-backup"
    echo "[bootstrap]   run), delete it:"
    echo "[bootstrap]     docker exec ${container} /garage key delete --yes ${legacy_key_id}"
  fi

  # Enable website serving on public media buckets.
  #
  # Garage's S3 API (port 3900) requires every request to be signed and
  # returns 403 "does not support anonymous access" for unauthenticated GETs.
  # Public browsers therefore cannot fetch media through the S3 API at all.
  #
  # The web endpoint (port 3902, configured in garage.toml [s3_web]) is the
  # mechanism for anonymous public reads. A bucket must have website serving
  # explicitly enabled to be reachable there. The host nginx/Caddy proxy
  # terminates public TLS and forwards to this endpoint — see
  # nginx/sites-available/garage-media.conf.
  #
  # pg-backups, stalwart-mail, and lemmy-pictrs are intentionally excluded —
  # mail blobs are private, and Lemmy serves images THROUGH pict-rs (which reads
  # from S3 and proxies the bytes), so its bucket needs no anonymous web access.
  local public_buckets=(mastodon-media pixelfed-media gotosocial-media peertube-web-videos peertube-streaming-playlists funkwhale-music)
  echo "[bootstrap] Enabling website serving on public media buckets..."
  for bucket in "${public_buckets[@]}"; do
    if _g bucket website --allow "$bucket" 2>/dev/null; then
      echo "[bootstrap]   website enabled: ${bucket}"
    else
      echo "[bootstrap]   website already enabled or failed: ${bucket}"
    fi
  done

  # CORS on the HLS buckets (PeerTube only).
  #
  # PeerTube's HLS player fetches manifests and fmp4 byte-range segments
  # cross-origin via fetch()/XHR (MSE), so the browser requires
  # Access-Control-Allow-Origin on the media host — without it playback hangs on
  # a spinner with no error and no timeout. Plain media (<img>/<video src> as
  # used by Mastodon/Pixelfed/GoToSocial) does NOT need CORS, so only the HLS
  # buckets get a rule. Garage honours per-bucket CORS on its web endpoint, but
  # the garage CLI cannot set it — it's an S3 PutBucketCors call, which needs an
  # S3 client and the access key (not the garage admin socket used by _g above).
  local hls_buckets=(peertube-web-videos peertube-streaming-playlists)
  local s3ep="http://${GARAGE_MAGIC_NAME}.${TS_TAILNET}:3900"
  local cors_json='{"CORSRules":[{"AllowedOrigins":["*"],"AllowedMethods":["GET","HEAD"],"AllowedHeaders":["*"],"ExposeHeaders":["Content-Length","Content-Range","Accept-Ranges"],"MaxAgeSeconds":86400}]}'
  echo "[bootstrap] Setting CORS on HLS (PeerTube) buckets..."
  if [[ -z "${PEERTUBE_GARAGE_KEY_SECRET:-}" ]]; then
    echo "[bootstrap]   skipped — PEERTUBE_GARAGE_KEY_SECRET not in .env yet."
    echo "[bootstrap]   Add the key printed below to .env, then re-run provision-garage."
  elif command -v aws >/dev/null 2>&1; then
    local cf; cf=$(mktemp); printf '%s' "$cors_json" >"$cf"
    for bucket in "${hls_buckets[@]}"; do
      if AWS_ACCESS_KEY_ID="${PEERTUBE_GARAGE_KEY_ID}" AWS_SECRET_ACCESS_KEY="${PEERTUBE_GARAGE_KEY_SECRET}" \
         aws --endpoint-url "$s3ep" --region "${GARAGE_REGION:-garage}" \
         s3api put-bucket-cors --bucket "$bucket" --cors-configuration "file://${cf}" 2>/dev/null; then
        echo "[bootstrap]   CORS set: ${bucket}"
      else
        echo "[bootstrap]   CORS failed: ${bucket} (set it manually — see note below)"
      fi
    done
    rm -f "$cf"
  else
    echo "[bootstrap]   'aws' CLI not found — set CORS manually (required for HLS playback):"
    for bucket in "${hls_buckets[@]}"; do
      echo "[bootstrap]     aws --endpoint-url ${s3ep} --region ${GARAGE_REGION:-garage} \\"
      echo "[bootstrap]       s3api put-bucket-cors --bucket ${bucket} \\"
      echo "[bootstrap]       --cors-configuration '${cors_json}'"
    done
  fi

  echo ""
  echo "[bootstrap] ============================================================"
  if [[ ${#new_env_lines[@]} -gt 0 ]]; then
    echo "[bootstrap] Newly created keys — add these to your .env (secrets are"
    echo "[bootstrap] NOT redisplayable later):"
    echo ""
    local line
    for line in "${new_env_lines[@]}"; do
      echo "  ${line}"
    done
    echo ""
    echo "[bootstrap] Then opt in apps via .env and restart their stacks"
    echo "[bootstrap] (./bootstrap.sh restart <app> — never 'docker compose restart'):"
    echo "  MASTODON_S3_ENABLED=true"
    echo "  PIXELFED_ENABLE_CLOUD=true"
    echo "  PEERTUBE_OBJECT_STORAGE_ENABLED=true"
  fi
  if [[ ${#kept_keys[@]} -gt 0 ]]; then
    echo "[bootstrap] Pre-existing keys (secrets not redisplayable). If a secret"
    echo "[bootstrap] is lost, rotate the key and re-run provision-garage:"
    local kept
    for kept in "${kept_keys[@]}"; do
      echo "  ${kept%% *}  (docker exec ${container} /garage key rotate ${kept##* })"
    done
  fi
  echo "[bootstrap] ============================================================"
}

# Print this host's Garage peer id: <node-pubkey>@<magicdns-name>:3901.
# Collect one from each node to assemble GARAGE_BOOTSTRAP_PEERS (comma-joined)
# for a multi-node cluster. Uses the stable MagicDNS name, never the tailnet
# IP (ephemeral sidecars change IP on restart; the name is stable).
cmd_garage_peer_id() {
  local container
  container=$(dc garage ps -q garage 2>/dev/null | head -1)
  [[ -n "$container" ]] || die "Garage is not running on this host. Start it: ./bootstrap.sh up garage"
  [[ -n "${GARAGE_MAGIC_NAME:-}" && -n "${TS_TAILNET:-}" ]] || \
    die "GARAGE_MAGIC_NAME and TS_TAILNET must be set in .env."
  local pubkey
  pubkey=$(docker exec "$container" /garage node id 2>/dev/null | head -1 | cut -d@ -f1)
  [[ -n "$pubkey" ]] || die "Could not read this node's Garage id. Check: ./bootstrap.sh logs garage"
  echo "${pubkey}@${GARAGE_MAGIC_NAME}.${TS_TAILNET}:3901"
}

# ---------------------------------------------------------------------------
# Stalwart provisioning — JMAP x: management API
# Called automatically by `cmd_up stalwart` and available standalone:
#   ./bootstrap.sh provision-stalwart
#
# Idempotent: queries for existing objects before creating. Safe to re-run.
# ---------------------------------------------------------------------------

# Module-level state for the current provision run (set inside cmd_provision_stalwart).
_SW_AUTH=""      # "user:password" for HTTP Basic auth
_SW_ACCT_ID=""   # JMAP account ID (queried from session after auth)
_SW_JMAP=""      # full JMAP endpoint URL

# PROXY protocol trust for mail listeners only (25/465/587/143/993).
# Includes Tailscale CGNAT range and the ULA subnet used by the sidecar netns.
# NOT applied to http(:8080) or https(:443) — those don't receive PROXY headers.
_SW_NET_TRUST='{"100.64.0.0/10":true,"fd7a:115c:a1e0::/48":true}'

_sw_call() {
  curl -s -m 25 -u "$_SW_AUTH" -H 'Content-Type: application/json' "$_SW_JMAP" -X POST \
    --data "$(jq -nc --argjson mc "$1" \
      '{"using":["urn:ietf:params:jmap:core","urn:stalwart:jmap"],"methodCalls":$mc}')"
}

_sw_ok() {
  local r="$1"
  # Validate the envelope FIRST. A 401/404/5xx body is not JMAP at all, so the
  # two jq checks below would simply fail to match and this function would
  # report success on a rejected call. Catch that here instead.
  if ! echo "$r" | jq -e 'has("methodResponses")' >/dev/null 2>&1; then
    die "Stalwart returned a non-JMAP response (auth or endpoint problem):
  $(echo "$r" | head -c 300)"
  fi
  if echo "$r" | jq -e '.methodResponses[0][0]=="error"' >/dev/null 2>&1; then
    die "JMAP error: $(echo "$r" | jq -c '.methodResponses[0][1]')"
  fi
  if echo "$r" | jq -e '.methodResponses[0][1] | (.notCreated//{}|length>0) or (.notUpdated//{}|length>0) or (.notDestroyed//[]|length>0)' >/dev/null 2>&1; then
    die "JMAP set rejected: $(echo "$r" | jq -c '.methodResponses[0][1]|{notCreated,notUpdated,notDestroyed}')"
  fi
}

# Find the ID of a named object of the given type. Returns empty string if absent.
_sw_find_id() {
  local type="$1" name="$2"
  local r; r=$(_sw_call "$(jq -nc --arg t "$type" --arg acct "$_SW_ACCT_ID" '[
    [($t+"/query"), {"accountId":$acct}, "0"],
    [($t+"/get"),   {"accountId":$acct,
                     "#ids":{"resultOf":"0","name":($t+"/query"),"path":"/ids"},
                     "properties":["name"]}, "1"]
  ]')")
  echo "$r" | jq -r --arg n "$name" '.methodResponses[1][1].list[]? | select(.name==$n) | .id' | head -1
}

# Authenticate. Prefers the persistent admin@DOMAIN; falls back to the
# first-boot virtual admin ("admin") if no real account exists yet.
# Try one "user:password" against /jmap/session. Echoes the primary account ID
# on success, returns non-zero on failure.
#
# The status code CANNOT be used to test authentication here. Stalwart answers
# /jmap/session with 200 and an anonymous body when no credentials are sent,
# and only returns 401 when credentials are sent and are wrong. So a 200 proves
# nothing — `-u garbage:garbage` against an empty store would "pass". The only
# reliable signal is whether the session body carries primaryAccounts.
#
# Note the key order: a real v0.16.7 session has NO urn:ietf:params:jmap:core
# entry, so urn:stalwart:jmap is checked first, with a generic fallback to
# whatever the first primaryAccounts value happens to be.
_sw_try_auth() {
  local cred="$1" session acct
  session=$(curl -s -m 10 -u "$cred" "${_SW_JMAP}/session" 2>/dev/null) || return 1
  acct=$(printf '%s' "$session" | jq -r '
    .primaryAccounts["urn:stalwart:jmap"] //
    .primaryAccounts["urn:ietf:params:jmap:core"] //
    ((.primaryAccounts // {}) | to_entries | first | .value) //
    empty
  ' 2>/dev/null) || return 1
  [[ -n "$acct" && "$acct" != "null" ]] || return 1
  printf '%s' "$acct"
}

# Authenticate and populate _SW_AUTH + _SW_ACCT_ID, trying each plausible
# credential in turn. Safe to call again mid-run: once a real admin account
# exists, Stalwart's first-boot fallback goes inert and the earlier credential
# stops working, so the caller re-runs this after creating the admin.
_sw_auth() {
  local cand acct
  local -a cands=()
  # 1. The persistent admin, using its own password. This is the normal case
  #    for any store that has already been set up — including one configured
  #    through the web wizard, whose admin password is NOT the fallback secret.
  [[ -n "${STALWART_ADMIN_PASSWORD:-}" ]] && \
    cands+=("admin@${STALWART_DOMAIN}:${STALWART_ADMIN_PASSWORD}")
  # 2. The persistent admin created by a previous run of this command, when
  #    STALWART_ADMIN_PASSWORD was unset and the fallback secret was used.
  cands+=("admin@${STALWART_DOMAIN}:${STALWART_FALLBACK_ADMIN_SECRET}")
  # 3. The built-in fallback admin — only live while the config store is empty.
  cands+=("admin:${STALWART_FALLBACK_ADMIN_SECRET}")

  for cand in "${cands[@]}"; do
    if acct=$(_sw_try_auth "$cand"); then
      _SW_AUTH="$cand"
      _SW_ACCT_ID="$acct"
      echo "[bootstrap]   authenticated as ${cand%%:*} (account ${acct})"
      return 0
    fi
  done

  die "Cannot authenticate to Stalwart at ${_SW_JMAP}.
  Tried: admin@${STALWART_DOMAIN} and the first-boot fallback admin.
  If this Stalwart was configured through the web admin UI, its admin password
  is whatever you set there — put it in STALWART_ADMIN_PASSWORD in .env.
  On a genuinely fresh store, STALWART_FALLBACK_ADMIN_SECRET must match the
  value the container booted with."
}

cmd_provision_stalwart() {
  command -v jq >/dev/null || die "jq is required: apt install jq"

  local missing=()
  for v in STALWART_MAGIC_NAME TS_TAILNET STALWART_DOMAIN STALWART_HOSTNAME \
            STALWART_FALLBACK_ADMIN_SECRET \
            STALWART_REDIS_MAGIC_NAME STALWART_REDIS_PASSWORD \
            GARAGE_MAGIC_NAME GARAGE_REGION \
            STALWART_GARAGE_KEY_ID STALWART_GARAGE_KEY_SECRET \
            STALWART_S3_BUCKET STALWART_RELAY_USER STALWART_RELAY_PASSWORD; do
    [[ -n "${!v:-}" ]] || missing+=("$v")
  done
  [[ ${#missing[@]} -eq 0 ]] || die "Required vars missing from .env: ${missing[*]}"

  _SW_JMAP="http://${STALWART_MAGIC_NAME}.${TS_TAILNET}:8080/jmap"
  local relay_addr="${STALWART_RELAY_USER}@${STALWART_DOMAIN}"

  echo "[bootstrap] Provisioning Stalwart at ${_SW_JMAP}..."
  echo "[bootstrap] Waiting for JMAP API (up to 120 s)..."
  local elapsed=0 interval=5 timeout=120
  while true; do
    if curl -s -m 5 -o /dev/null -w '%{http_code}' "${_SW_JMAP}/session" 2>/dev/null | grep -qE '^[24]'; then
      break
    fi
    elapsed=$(( elapsed + interval ))
    if [[ $elapsed -ge $timeout ]]; then
      die "Stalwart JMAP API did not respond after ${timeout}s.
  Ensure shared-db and garage are healthy: ./bootstrap.sh ps
  Check Stalwart logs: ./bootstrap.sh logs stalwart"
    fi
    sleep "$interval"
  done

  _sw_auth

  # ── Blob store → Garage S3 ────────────────────────────────────────────────
  # GARAGE_S3_ENDPOINT_NAME defaults to the single node; set it to the
  # reverse-proxy host for the HA S3 load-balancer (README "Highly available
  # S3 endpoint").
  echo "[bootstrap] Setting blob store (Garage S3, bucket ${STALWART_S3_BUCKET})..."
  _sw_ok "$(_sw_call "$(jq -nc \
    --arg ep     "http://${GARAGE_S3_ENDPOINT_NAME:-garage}.${TS_TAILNET}:3900" \
    --arg region "${GARAGE_REGION}" \
    --arg bucket "${STALWART_S3_BUCKET}" \
    --arg ak     "${STALWART_GARAGE_KEY_ID}" \
    --arg sk     "${STALWART_GARAGE_KEY_SECRET}" \
    --arg acct   "$_SW_ACCT_ID" \
    '[["x:BlobStore/set",{"accountId":$acct,"update":{"singleton":{
      "@type":"S3",
      "region":{"@type":"Custom","customEndpoint":$ep,"customRegion":$region},
      "bucket":$bucket,
      "accessKey":$ak,
      "secretKey":{"@type":"Value","secret":$sk},
      "verifyAfterWrite":true
    }}},"0"]]')")"

  # ── In-memory store → Redis ───────────────────────────────────────────────
  # Stalwart's OWN dedicated Redis instance (stalwart-redis/), separate from
  # the fediverse apps' shared Redis — see README "Stalwart Redis high
  # availability" for why. STALWART_REDIS_MAGIC_NAME is the stable endpoint:
  # a single node directly, or the stalwart-redis-router sidecar in an HA
  # deployment — either way this URL never needs to change on failover.
  # STALWART_REDIS_PASSWORD must be URL-safe (openssl rand -hex 32) — it is
  # embedded in the connection URL.
  echo "[bootstrap] Setting in-memory store (Redis, ${STALWART_REDIS_MAGIC_NAME})..."
  _sw_ok "$(_sw_call "$(jq -nc \
    --arg url  "redis://:${STALWART_REDIS_PASSWORD}@${STALWART_REDIS_MAGIC_NAME}.${TS_TAILNET}:6379" \
    --arg acct "$_SW_ACCT_ID" \
    '[["x:InMemoryStore/set",{"accountId":$acct,"update":{"singleton":{
      "@type":"Redis",
      "url":$url
    }}},"0"]]')")"

  # ── Cluster coordinator (optional, multi-node) ────────────────────────────
  # Only when STALWART_CLUSTER_ENABLE=true (see README "Stalwart high
  # availability") — single-node deployments skip this entirely, unchanged.
  # "Default" reuses the InMemoryStore connection just configured above (same
  # Redis, same credentials) for the pub/sub that propagates mailbox change
  # hints, IMAP IDLE/push triggers, and ACME cert availability across nodes.
  # This is best-effort, non-persistent pub/sub (per Stalwart's own docs) —
  # authoritative state is always Postgres + Garage, both shared and durable,
  # so a missed pub/sub message degrades responsiveness, not correctness.
  if [[ "${STALWART_CLUSTER_ENABLE:-false}" == "true" ]]; then
    echo "[bootstrap] Setting cluster coordinator (Default — reuses the Redis in-memory store)..."
    _sw_ok "$(_sw_call "$(jq -nc \
      --arg acct "$_SW_ACCT_ID" \
      '[["x:Coordinator/set",{"accountId":$acct,"update":{"singleton":{
        "@type":"Default"
      }}},"0"]]')")"
  fi

  # ── Primary domain ────────────────────────────────────────────────────────
  echo "[bootstrap] Ensuring domain ${STALWART_DOMAIN} (catch-all → ${relay_addr})..."
  local domain_id
  domain_id=$(_sw_find_id x:Domain "${STALWART_DOMAIN}")
  if [[ -z "$domain_id" ]]; then
    local r; r=$(_sw_call "$(jq -nc \
      --arg d    "${STALWART_DOMAIN}" \
      --arg ca   "$relay_addr" \
      --arg acct "$_SW_ACCT_ID" \
      '[["x:Domain/set",{"accountId":$acct,"create":{"d":{
        "name":$d,
        "isEnabled":true,
        "description":"Primary mail domain",
        "catchAllAddress":$ca,
        "subAddressing":{"@type":"Enabled"},
        "dkimManagement":{
          "@type":"Automatic",
          "algorithms":{"Dkim1Ed25519Sha256":true,"Dkim1RsaSha256":true},
          "selectorTemplate":"v{version}-{algorithm}-{date-%Y%m%d}",
          "rotateAfter":7776000000,
          "retireAfter":604800000,
          "deleteAfter":2592000000
        }
      }}},"0"]]')")
    _sw_ok "$r"
    domain_id=$(echo "$r" | jq -r '.methodResponses[0][1].created.d.id')
    echo "[bootstrap]   domain created (ID: ${domain_id})"
  else
    echo "[bootstrap]   domain ${STALWART_DOMAIN} present (ID: ${domain_id})"
  fi

  # ── Persistent admin account ──────────────────────────────────────────────
  echo "[bootstrap] Ensuring admin account (admin@${STALWART_DOMAIN})..."
  if [[ -z "$(_sw_find_id x:Account admin)" ]]; then
    _sw_ok "$(_sw_call "$(jq -nc \
      --arg pw   "${STALWART_ADMIN_PASSWORD:-$STALWART_FALLBACK_ADMIN_SECRET}" \
      --arg dom  "$domain_id" \
      --arg acct "$_SW_ACCT_ID" \
      '[["x:Account/set",{"accountId":$acct,"create":{"a":{
        "@type":"User",
        "name":"admin",
        "domainId":$dom,
        "description":"System administrator",
        "roles":{"@type":"Admin"},
        "credentials":{"0":{"@type":"Password","secret":$pw}}
      }}},"0"]]')")"
    echo "[bootstrap]   admin account created"
  else
    echo "[bootstrap]   admin account present"
  fi

  # Re-authenticate. If the admin account was just created, the first-boot
  # fallback we may have been using has gone inert and would 401 from here on.
  # This dies on failure rather than silently continuing with stale credentials.
  _sw_auth

  # ── Relay / catch-all account ─────────────────────────────────────────────
  echo "[bootstrap] Ensuring relay account (${relay_addr})..."
  if [[ -z "$(_sw_find_id x:Account "${STALWART_RELAY_USER}")" ]]; then
    _sw_ok "$(_sw_call "$(jq -nc \
      --arg n    "${STALWART_RELAY_USER}" \
      --arg dom  "$domain_id" \
      --arg pw   "${STALWART_RELAY_PASSWORD}" \
      --arg acct "$_SW_ACCT_ID" \
      '[["x:Account/set",{"accountId":$acct,"create":{"a":{
        "@type":"User",
        "name":$n,
        "domainId":$dom,
        "description":"Relay and catch-all",
        "credentials":{"0":{"@type":"Password","secret":$pw}}
      }}},"0"]]')")"
    echo "[bootstrap]   relay account ${relay_addr} created"
  else
    echo "[bootstrap]   relay account ${relay_addr} present"
  fi

  # ── Network listeners ─────────────────────────────────────────────────────
  # proxyTrust=1 → trust Tailscale CGNAT for PROXY protocol v2 (mail ports).
  # Listeners are created once and persist in Postgres; container restarts do
  # not recreate them. A container restart is required after NEW listeners are
  # created for Stalwart to bind the new ports.
  echo "[bootstrap] Ensuring network listeners..."
  local listener_rows=(
    "smtp         25   smtp         0  1"
    "submission   587  smtp         0  1"
    "submissions  465  smtp         1  1"
    "imap         143  imap         0  1"
    "imaps        993  imap         1  1"
    "http         8080 http         0  0"
    "https        443  http         1  0"
    "sieve        4190 manageSieve  0  0"
  )
  local row lname lport lproto limpl ltrust lid impl_bool pt
  for row in "${listener_rows[@]}"; do
    read -r lname lport lproto limpl ltrust <<< "$row"
    lid=$(_sw_find_id x:NetworkListener "$lname")
    if [[ -n "$lid" ]]; then
      echo "[bootstrap]   listener ${lname} present"
      continue
    fi
    impl_bool="false"; [[ "$limpl" == 1 ]] && impl_bool="true"
    pt="{}";            [[ "$ltrust" == 1 ]] && pt="$_SW_NET_TRUST"
    _sw_ok "$(_sw_call "$(jq -nc \
      --arg n    "$lname" \
      --arg bind "[::]:${lport}" \
      --arg p    "$lproto" \
      --argjson impl "$impl_bool" \
      --argjson pt   "$pt" \
      --arg acct "$_SW_ACCT_ID" \
      '[["x:NetworkListener/set",{"accountId":$acct,"create":{"l":{
        "name":$n,
        "bind":{($bind):true},
        "protocol":$p,
        "useTls":true,
        "tlsImplicit":$impl,
        "overrideProxyTrustedNetworks":$pt
      }}},"0"]]')")"
    echo "[bootstrap]   created listener ${lname} (:${lport})"
  done

  # ── System settings ───────────────────────────────────────────────────────
  echo "[bootstrap] Setting system hostname (${STALWART_HOSTNAME}) and default domain..."
  _sw_ok "$(_sw_call "$(jq -nc \
    --arg h    "${STALWART_HOSTNAME}" \
    --arg d    "$domain_id" \
    --arg acct "$_SW_ACCT_ID" \
    '[["x:SystemSettings/set",{"accountId":$acct,"update":{"singleton":{
      "defaultHostname":$h,
      "defaultDomainId":$d
    }}},"0"]]')")"

  # ── SSO via Authelia OIDC (opt-in) ────────────────────────────────────────
  if [[ "${STALWART_SSO_ENABLE:-false}" == "true" ]]; then
    [[ -n "${AUTHELIA_PORTAL_URL:-}" ]] || \
      die "STALWART_SSO_ENABLE=true but AUTHELIA_PORTAL_URL is empty"
    [[ -n "${STALWART_OIDC_CLIENT_SECRET:-}" ]] || \
      die "STALWART_SSO_ENABLE=true but STALWART_OIDC_CLIENT_SECRET is empty"
    echo "[bootstrap] Configuring OIDC directory → Authelia (${AUTHELIA_PORTAL_URL})..."
    if [[ -z "$(_sw_find_id x:Directory authelia)" ]]; then
      _sw_ok "$(_sw_call "$(jq -nc \
        --arg iss  "${AUTHELIA_PORTAL_URL}" \
        --arg ud   "${STALWART_DOMAIN}" \
        --arg acct "$_SW_ACCT_ID" \
        '[["x:Directory/set",{"accountId":$acct,"create":{"d":{
          "@type":"Oidc",
          "description":"authelia",
          "issuerUrl":$iss,
          "claimUsername":"preferred_username",
          "claimName":"name",
          "claimGroups":"groups",
          "usernameDomain":$ud
        }}},"0"]]')")"
      echo "[bootstrap]   OIDC directory created"
    else
      echo "[bootstrap]   OIDC directory present"
    fi
    cat <<OIDCEOF

[bootstrap] Add to authelia/configuration.yml under identity_providers.oidc.clients
[bootstrap] (hash the secret first):
[bootstrap]   docker exec federated-authelia-authelia-1 \\
[bootstrap]     authelia crypto hash generate pbkdf2 --password '${STALWART_OIDC_CLIENT_SECRET}'

    - client_id: stalwart
      client_name: Stalwart Mail
      client_secret: '<PBKDF2-HASH-OF-STALWART_OIDC_CLIENT_SECRET>'
      public: false
      authorization_policy: two_factor
      redirect_uris:
        - https://${STALWART_HOSTNAME}/auth/oauth
      scopes: [openid, profile, email, groups]

[bootstrap] admin and ${relay_addr} retain password auth as break-glass.
OIDCEOF
  fi

  # ── DNS records (always tier-1: print for manual publish) ─────────────────
  echo ""
  echo "[bootstrap] ============================================================"
  echo "[bootstrap]  DNS records to publish for ${STALWART_DOMAIN}"
  echo "[bootstrap] ============================================================"
  _sw_call "$(jq -nc \
    --arg id   "$domain_id" \
    --arg acct "$_SW_ACCT_ID" \
    '[["x:Domain/get",{"accountId":$acct,"ids":[$id],"properties":["dnsZoneFile"]},"0"]]')" \
    | jq -r '.methodResponses[0][1].list[0].dnsZoneFile //
             "  (not yet available — DKIM keys may still be generating; re-run in a moment)"'
  echo "[bootstrap] ============================================================"
  echo ""
  echo "[bootstrap] Done. Next steps:"
  echo "[bootstrap]   1. Publish the DNS records above."
  echo "[bootstrap]   2. Configure ACME (DNS-01) in the admin UI:"
  echo "[bootstrap]      http://${STALWART_MAGIC_NAME}.${TS_TAILNET}:8080"
  echo "[bootstrap]      Settings → TLS → ACME Providers → Add"
  echo "[bootstrap]   3. Restart Stalwart to activate newly-created listeners:"
  echo "[bootstrap]      ./bootstrap.sh restart stalwart"
}

_cmd_up_caddy() {
  local caddy_bin="${CADDY_BIN:-/usr/local/bin/caddy}"
  local caddyfile="${REPO_ROOT}/caddy/Caddyfile"

  # 1. Verify the custom binary exists and includes the layer4 module.
  if [[ ! -x "$caddy_bin" ]]; then
    die "Custom Caddy binary not found at ${caddy_bin}.
  Download it with the caddy-l4 plugin from caddyserver.com/api/download
  See caddy/README.md for the exact command."
  fi
  if ! "$caddy_bin" list-modules 2>/dev/null | grep -q 'layer4'; then
    die "Caddy at ${caddy_bin} lacks the caddy-l4 module.
  See caddy/README.md for the download command with required plugins."
  fi
  echo "[bootstrap] Caddy binary OK (layer4 module present)."

  # 2. Validate the Caddyfile before touching the live system config.
  if ! "$caddy_bin" validate --config "$caddyfile" --adapter caddyfile; then
    die "Caddyfile validation failed. Fix ${caddyfile} before deploying."
  fi
  echo "[bootstrap] Caddyfile valid."

  # 3. Deploy and reload.
  sudo cp "$caddyfile" /etc/caddy/Caddyfile
  sudo systemctl reload caddy
  echo "[bootstrap] Caddy reloaded. Check: sudo journalctl -u caddy -n 50"
}

# ---------------------------------------------------------------------------
# Postgres high availability (see README "Postgres high availability")
# ---------------------------------------------------------------------------

# Ensure the replication role + physical slot on the PRIMARY. Idempotent.
_pg_ensure_replication() {
  : "${REPLICATION_PASSWORD:?REPLICATION_PASSWORD must be set in .env}"
  local user="${REPLICATION_USER:-replicator}" slot="${PG_REPLICATION_SLOT:-standby_slot}"
  echo "[bootstrap] Ensuring replication role '${user}' and slot '${slot}'..."
  _pg_exec --dbname postgres <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${user}') THEN
    CREATE ROLE "${user}" WITH REPLICATION LOGIN PASSWORD '${REPLICATION_PASSWORD}';
  ELSE
    ALTER ROLE "${user}" WITH REPLICATION LOGIN PASSWORD '${REPLICATION_PASSWORD}';
  END IF;
END
\$\$;
SELECT pg_create_physical_replication_slot('${slot}')
WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = '${slot}');
SQL
  echo "[bootstrap] Replication role + slot ready."
}

# Bring up shared-db as a standby: Postgres only (no Redis), cloning from the
# primary on first boot via the pg-entrypoint wrapper.
_cmd_up_pg_standby() {
  local missing=()
  for v in PG_NODE_MAGIC_NAME PG_PRIMARY_MAGIC_NAME TS_TAILNET REPLICATION_PASSWORD; do
    [[ -n "${!v:-}" ]] || missing+=("$v")
  done
  [[ ${#missing[@]} -eq 0 ]] || die "shared-db standby needs these in .env: ${missing[*]}
  PG_ROLE=standby; PG_NODE_MAGIC_NAME=this node (e.g. pg-standby);
  PG_PRIMARY_MAGIC_NAME=the primary (e.g. pg-primary)."

  echo "[bootstrap] shared-db STANDBY: Postgres only (no Redis)."
  echo "[bootstrap]   this node = ${PG_NODE_MAGIC_NAME}, primary = ${PG_PRIMARY_MAGIC_NAME}"

  echo "[bootstrap] Starting ts-postgres sidecar..."
  if ! dc shared-db up -d ts-postgres; then _check_ts_auth shared-db; exit 1; fi

  echo "[bootstrap] Starting Postgres standby (clones from the primary on first boot)..."
  if ! dc shared-db up -d postgres; then
    echo "[bootstrap] Standby failed to start. Common causes:" >&2
    echo "[bootstrap]   - primary not reachable at ${PG_PRIMARY_MAGIC_NAME}.${TS_TAILNET}:5432" >&2
    echo "[bootstrap]   - replication role/slot missing on primary ('up shared-db' there first)" >&2
    echo "[bootstrap]   - ACL missing tag:db-postgres -> tag:db-postgres:5432" >&2
    echo "[bootstrap]   Logs: ./bootstrap.sh logs shared-db postgres" >&2
    exit 1
  fi
  echo "[bootstrap] Standby up. Confirm streaming ON THE PRIMARY:"
  echo "[bootstrap]   docker exec <primary-pg> psql -U postgres -c 'SELECT client_addr,state FROM pg_stat_replication;'"
}

# Generate the pg-router nginx config from the current primary and (re)start it.
# Also the failover repoint step: change PG_PRIMARY_MAGIC_NAME, re-run this.
_cmd_up_pg_router() {
  local missing=()
  for v in DB_MAGIC_NAME PG_PRIMARY_MAGIC_NAME TS_TAILNET; do
    [[ -n "${!v:-}" ]] || missing+=("$v")
  done
  [[ ${#missing[@]} -eq 0 ]] || die "pg-router needs these in .env: ${missing[*]}
  DB_MAGIC_NAME = the app-facing endpoint apps already dial;
  PG_PRIMARY_MAGIC_NAME = the CURRENT primary node (e.g. pg-primary)."

  local addr="${PG_PRIMARY_MAGIC_NAME}.${TS_TAILNET}:5432"
  sed "s|__PG_PRIMARY_ADDR__|${addr}|" \
    "${REPO_ROOT}/pg-router/nginx.conf" > "${REPO_ROOT}/pg-router/nginx.runtime.conf"
  echo "[bootstrap] Generated pg-router/nginx.runtime.conf (${DB_MAGIC_NAME} -> ${addr})."

  echo "[bootstrap] Starting pg-router..."
  if ! dc pg-router up -d; then _check_ts_auth pg-router; exit 1; fi
  # If only the mounted config changed (failover repoint), 'up -d' won't
  # recreate the container — reload nginx so it re-reads the new upstream.
  local rc; rc=$(dc pg-router ps -q pg-router 2>/dev/null | head -1)
  [[ -n "$rc" ]] && docker exec "$rc" nginx -s reload >/dev/null 2>&1 || true
  echo "[bootstrap] pg-router up. Apps reach ${DB_MAGIC_NAME}.${TS_TAILNET}:5432 -> ${PG_PRIMARY_MAGIC_NAME}."
}

# Promote this standby to primary (run ON THE STANDBY host during a failover).
cmd_pg_promote() {
  [[ "${PG_ROLE:-primary}" == "standby" ]] || \
    die "Run this on the STANDBY host (PG_ROLE=standby). This host is '${PG_ROLE:-primary}'."
  local c; c=$(dc shared-db ps -q postgres 2>/dev/null | head -1)
  [[ -n "$c" ]] || die "Postgres standby not running here. ./bootstrap.sh up shared-db"
  if ! docker exec "$c" psql -U postgres -tAc "SELECT pg_is_in_recovery();" 2>/dev/null | grep -qi '^t'; then
    die "This Postgres is NOT in recovery (already a primary?). Refusing to promote."
  fi
  echo "[bootstrap] Promoting this standby to primary..."
  docker exec "$c" psql -U postgres -c "SELECT pg_promote(wait => true);" \
    || die "pg_promote failed — see ./bootstrap.sh logs shared-db postgres"
  echo "[bootstrap] Promoted. This node (${PG_NODE_MAGIC_NAME:-this host}) is now PRIMARY."
  echo "[bootstrap]"
  echo "[bootstrap] FINISH FAILOVER — on the pg-router host:"
  echo "[bootstrap]   1. set PG_PRIMARY_MAGIC_NAME=${PG_NODE_MAGIC_NAME:-<this node>} in its .env"
  echo "[bootstrap]   2. ./bootstrap.sh up pg-router     # repoints apps at the new primary"
  echo "[bootstrap]   3. set PG_ROLE=primary in THIS host's .env (tidy-up for restarts)"
  echo "[bootstrap] When the old primary's host returns, re-clone it as the new standby:"
  echo "[bootstrap]   ./bootstrap.sh pg-rejoin        (on that host)"
}

# Re-clone THIS host as a fresh standby of the current primary. Destructive.
cmd_pg_rejoin() {
  [[ "${PG_ROLE:-primary}" == "standby" ]] || \
    die "Set PG_ROLE=standby in this host's .env first (it is rejoining as the new standby)."
  local missing=()
  for v in PG_NODE_MAGIC_NAME PG_PRIMARY_MAGIC_NAME TS_TAILNET REPLICATION_PASSWORD; do
    [[ -n "${!v:-}" ]] || missing+=("$v")
  done
  [[ ${#missing[@]} -eq 0 ]] || die "pg-rejoin needs these in .env: ${missing[*]}"

  echo "[bootstrap] pg-rejoin: re-clone THIS host as a fresh standby of ${PG_PRIMARY_MAGIC_NAME}."
  echo "[bootstrap] This DESTROYS this host's local Postgres data volume and streams a clean"
  echo "[bootstrap] copy from the current primary. Use it on a FORMER primary that came back"
  echo "[bootstrap] after a failover. (pg_rewind is faster but needs wal_log_hints/checksums;"
  echo "[bootstrap] a full re-clone always works and is fine for a rare event.)"
  local ans
  read -r -p "  Type RECLONE to proceed: " ans
  [[ "$ans" == "RECLONE" ]] || die "Aborted."

  echo "[bootstrap] Stopping shared-db and removing the pg-data volume..."
  dc shared-db down
  local vol
  vol=$(docker volume ls -q | grep -E 'shared-db_pg-data$' | head -1)
  if [[ -n "$vol" ]]; then
    docker volume rm "$vol" >/dev/null 2>&1 && echo "[bootstrap]   removed volume ${vol}"
  else
    echo "[bootstrap]   (no pg-data volume found — cloning fresh)"
  fi
  _cmd_up_pg_standby
}

# ---------------------------------------------------------------------------
# Stalwart Redis high availability (see README "Stalwart Redis high availability")
# ---------------------------------------------------------------------------

# Bring up stalwart-redis as a standby. Unlike Postgres, there is no manual
# clone step — redis-stalwart-entrypoint.sh passes --replicaof at container
# start and redis-server performs the full sync itself in the background.
_cmd_up_stalwart_redis_standby() {
  local missing=()
  for v in STALWART_REDIS_NODE_MAGIC_NAME STALWART_REDIS_PRIMARY_MAGIC_NAME TS_TAILNET STALWART_REDIS_PASSWORD; do
    [[ -n "${!v:-}" ]] || missing+=("$v")
  done
  [[ ${#missing[@]} -eq 0 ]] || die "stalwart-redis standby needs these in .env: ${missing[*]}
  STALWART_REDIS_ROLE=standby; STALWART_REDIS_NODE_MAGIC_NAME=this node (e.g. stalwart-redis-standby);
  STALWART_REDIS_PRIMARY_MAGIC_NAME=the primary (e.g. stalwart-redis-primary)."

  echo "[bootstrap] stalwart-redis STANDBY: this node = ${STALWART_REDIS_NODE_MAGIC_NAME}, primary = ${STALWART_REDIS_PRIMARY_MAGIC_NAME}"

  echo "[bootstrap] Starting ts-stalwart-redis sidecar..."
  if ! dc stalwart-redis up -d ts-stalwart-redis; then _check_ts_auth stalwart-redis; exit 1; fi

  echo "[bootstrap] Starting Redis standby (replicaof the primary at startup)..."
  if ! dc stalwart-redis up -d stalwart-redis; then
    echo "[bootstrap] Standby failed to start. Common causes:" >&2
    echo "[bootstrap]   - primary not reachable at ${STALWART_REDIS_PRIMARY_MAGIC_NAME}.${TS_TAILNET}:6379" >&2
    echo "[bootstrap]   - STALWART_REDIS_PASSWORD doesn't match the primary's (it doubles as masterauth)" >&2
    echo "[bootstrap]   - ACL missing tag:stalwart-redis -> tag:stalwart-redis:6379" >&2
    echo "[bootstrap]   Logs: ./bootstrap.sh logs stalwart-redis stalwart-redis" >&2
    exit 1
  fi
  echo "[bootstrap] Standby up. Confirm streaming ON THE PRIMARY:"
  echo "[bootstrap]   docker exec <primary-redis> redis-cli -a \"\$STALWART_REDIS_PASSWORD\" --no-auth-warning info replication"
}

# Generate the stalwart-redis-router nginx config from the current primary
# and (re)start it. Also the failover repoint step: change
# STALWART_REDIS_PRIMARY_MAGIC_NAME, re-run this.
_cmd_up_stalwart_redis_router() {
  local missing=()
  for v in STALWART_REDIS_MAGIC_NAME STALWART_REDIS_PRIMARY_MAGIC_NAME TS_TAILNET; do
    [[ -n "${!v:-}" ]] || missing+=("$v")
  done
  [[ ${#missing[@]} -eq 0 ]] || die "stalwart-redis-router needs these in .env: ${missing[*]}
  STALWART_REDIS_MAGIC_NAME = the endpoint Stalwart already dials;
  STALWART_REDIS_PRIMARY_MAGIC_NAME = the CURRENT primary node (e.g. stalwart-redis-primary)."

  local addr="${STALWART_REDIS_PRIMARY_MAGIC_NAME}.${TS_TAILNET}:6379"
  sed "s|__STALWART_REDIS_PRIMARY_ADDR__|${addr}|" \
    "${REPO_ROOT}/stalwart-redis-router/nginx.conf" > "${REPO_ROOT}/stalwart-redis-router/nginx.runtime.conf"
  echo "[bootstrap] Generated stalwart-redis-router/nginx.runtime.conf (${STALWART_REDIS_MAGIC_NAME} -> ${addr})."

  echo "[bootstrap] Starting stalwart-redis-router..."
  if ! dc stalwart-redis-router up -d; then _check_ts_auth stalwart-redis-router; exit 1; fi
  # If only the mounted config changed (failover repoint), 'up -d' won't
  # recreate the container — reload nginx so it re-reads the new upstream.
  local rc; rc=$(dc stalwart-redis-router ps -q stalwart-redis-router 2>/dev/null | head -1)
  [[ -n "$rc" ]] && docker exec "$rc" nginx -s reload >/dev/null 2>&1 || true
  echo "[bootstrap] stalwart-redis-router up. Stalwart reaches ${STALWART_REDIS_MAGIC_NAME}.${TS_TAILNET}:6379 -> ${STALWART_REDIS_PRIMARY_MAGIC_NAME}."
}

# Promote this standby to primary (run ON THE STANDBY host during a
# failover). Unlike Postgres, no data-consistency ceremony is needed:
# REPLICAOF NO ONE just stops replicating and starts accepting writes.
cmd_stalwart_redis_promote() {
  [[ "${STALWART_REDIS_ROLE:-primary}" == "standby" ]] || \
    die "Run this on the STANDBY host (STALWART_REDIS_ROLE=standby). This host is '${STALWART_REDIS_ROLE:-primary}'."
  local c; c=$(dc stalwart-redis ps -q stalwart-redis 2>/dev/null | head -1)
  [[ -n "$c" ]] || die "stalwart-redis standby not running here. ./bootstrap.sh up stalwart-redis"
  echo "[bootstrap] Promoting this standby to primary..."
  docker exec "$c" redis-cli -a "${STALWART_REDIS_PASSWORD}" --no-auth-warning REPLICAOF NO ONE \
    || die "REPLICAOF NO ONE failed — see ./bootstrap.sh logs stalwart-redis stalwart-redis"
  echo "[bootstrap] Promoted. This node (${STALWART_REDIS_NODE_MAGIC_NAME:-this host}) is now PRIMARY."
  echo "[bootstrap]"
  echo "[bootstrap] FINISH FAILOVER — on the stalwart-redis-router host:"
  echo "[bootstrap]   1. set STALWART_REDIS_PRIMARY_MAGIC_NAME=${STALWART_REDIS_NODE_MAGIC_NAME:-<this node>} in its .env"
  echo "[bootstrap]   2. ./bootstrap.sh up stalwart-redis-router   # repoints Stalwart at the new primary"
  echo "[bootstrap]   3. set STALWART_REDIS_ROLE=primary in THIS host's .env (tidy-up for restarts)"
  echo "[bootstrap] When the old primary's host returns: set STALWART_REDIS_ROLE=standby and point"
  echo "[bootstrap] STALWART_REDIS_PRIMARY_MAGIC_NAME at the new primary in its .env, then"
  echo "[bootstrap] ./bootstrap.sh restart stalwart-redis — it resyncs automatically. No"
  echo "[bootstrap] pg-rejoin-style re-clone command needed. NEVER let it resume as a second"
  echo "[bootstrap] primary — that's split-brain, just quieter than Postgres about it."
}

cmd_up() {
  local stack="${1:-}"
  [[ -n "$stack" ]] || die "Usage: ./bootstrap.sh up <stack>"

  # caddy is a system service, not a Docker Compose stack — handle separately.
  if [[ "$stack" == "caddy" ]]; then
    _cmd_up_caddy
    return 0
  fi

  require_stack "$stack"

  # Ensure a per-stack .env symlink exists so operators can also run
  # docker compose directly inside the stack directory.
  local stack_env="${REPO_ROOT}/${stack}/.env"
  if [[ ! -e "$stack_env" ]]; then
    ln -s "../.env" "$stack_env"
    echo "[bootstrap] Created ${stack}/.env -> ../.env"
  fi

  # pg-router (HA Postgres endpoint): generate the runtime nginx config from
  # the current primary, then bring the small proxy up. Nothing else to do.
  if [[ "$stack" == "pg-router" ]]; then
    _cmd_up_pg_router
    return 0
  fi

  # stalwart-redis-router (HA Stalwart Redis endpoint): same trick as
  # pg-router, for Stalwart's dedicated Redis pair.
  if [[ "$stack" == "stalwart-redis-router" ]]; then
    _cmd_up_stalwart_redis_router
    return 0
  fi

  # shared-db STANDBY: a different bring-up (Postgres only, clone from the
  # primary — no Redis, no app-DB provisioning). Primary falls through.
  if [[ "$stack" == "shared-db" && "${PG_ROLE:-primary}" == "standby" ]]; then
    _cmd_up_pg_standby
    return 0
  fi

  # shared-db preflight: both Redis instances refuse to be brought up
  # without their passwords — an empty ${VAR} would silently expand to
  # `--requirepass ''`, which DISABLES Redis auth.
  if [[ "$stack" == "shared-db" ]]; then
    for v in REDIS_APPS_PASSWORD REDIS_AUTHELIA_PASSWORD; do
      [[ -n "${!v:-}" ]] || \
        die "${v} is not set in .env. Generate one: openssl rand -hex 32"
    done
  fi

  # stalwart-redis STANDBY: redis-stalwart-entrypoint.sh handles replicaof at
  # startup — no separate clone step. Primary falls through.
  if [[ "$stack" == "stalwart-redis" && "${STALWART_REDIS_ROLE:-primary}" == "standby" ]]; then
    _cmd_up_stalwart_redis_standby
    return 0
  fi

  # stalwart-redis preflight: refuses to start without a password — an empty
  # ${VAR} would silently expand to `--requirepass ''`, disabling auth.
  if [[ "$stack" == "stalwart-redis" ]]; then
    [[ -n "${STALWART_REDIS_PASSWORD:-}" ]] || \
      die "STALWART_REDIS_PASSWORD is not set in .env. Generate one: openssl rand -hex 32"
  fi

  # Provision DB for app stacks (idempotent — safe on fresh or existing
  # volumes). Skip for shared-db and garage; skip gracefully if shared-db
  # isn't up yet.
  local is_db_stack=0
  for s in "${DB_STACKS[@]}"; do [[ "$s" == "$stack" ]] && is_db_stack=1; done
  if [[ $is_db_stack -eq 1 ]]; then
    local pg_container
    pg_container=$(dc shared-db ps -q postgres 2>/dev/null | head -1)
    if [[ -n "$pg_container" ]]; then
      cmd_provision_db "$stack"
    else
      echo "[bootstrap] Warning: shared-db postgres not running — skipping DB provisioning."
      echo "[bootstrap] Bring up shared-db first: ./bootstrap.sh up shared-db"
    fi
  fi

  # After Garage comes up: single node self-provisions immediately; a cluster
  # node comes up and defers layout formation to one coordinated
  # provision-garage run (see cmd_provision_garage).
  if [[ "$stack" == "garage" ]]; then
    [[ -n "${GARAGE_RPC_SECRET:-}" ]] || \
      die "GARAGE_RPC_SECRET is not set in .env. Generate one: openssl rand -hex 32"

    local rf="${GARAGE_REPLICATION_FACTOR:-1}"
    [[ "$rf" =~ ^[0-9]+$ ]] || die "GARAGE_REPLICATION_FACTOR must be a positive integer (got '${rf}')."

    # Generate garage.runtime.toml from the tracked template, substituting
    # .env values for fields Garage can't read from environment variables.
    # The runtime file is gitignored; the template stays clean for git pulls.
    local region="${GARAGE_REGION:-garage}"
    local runtime="${REPO_ROOT}/garage/garage.runtime.toml"
    sed -e "s|__GARAGE_REPLICATION_FACTOR__|${rf}|" \
        -e "s|^s3_region *=.*|s3_region     = \"${region}\"|" \
        "${REPO_ROOT}/garage/garage.toml" > "$runtime"

    if [[ "$rf" -gt 1 ]]; then
      # Cluster mode: advertise a STABLE rpc address (this node's MagicDNS
      # name, never its ephemeral tailnet IP) and, once known, the peer list.
      [[ -n "${GARAGE_MAGIC_NAME:-}" && -n "${TS_TAILNET:-}" ]] || \
        die "Cluster mode (GARAGE_REPLICATION_FACTOR=${rf}) needs GARAGE_MAGIC_NAME and TS_TAILNET set in .env."
      sed -i "s|__GARAGE_RPC_PUBLIC_ADDR__|rpc_public_addr = \"${GARAGE_MAGIC_NAME}.${TS_TAILNET}:3901\"|" "$runtime"
      if [[ -n "${GARAGE_BOOTSTRAP_PEERS:-}" ]]; then
        local _peer _peer_arr=() _peers_toml=""
        IFS=',' read -ra _peer_arr <<< "${GARAGE_BOOTSTRAP_PEERS}"
        for _peer in "${_peer_arr[@]}"; do
          _peer="$(echo "$_peer" | xargs)"; [[ -n "$_peer" ]] || continue
          _peers_toml+="\"${_peer}\", "
        done
        _peers_toml="${_peers_toml%, }"
        sed -i "s|__GARAGE_BOOTSTRAP_PEERS__|bootstrap_peers = [${_peers_toml}]|" "$runtime"
      else
        sed -i "/__GARAGE_BOOTSTRAP_PEERS__/d" "$runtime"
      fi
      echo "[bootstrap] Generated garage.runtime.toml (cluster: replication_factor=${rf}, node=${GARAGE_MAGIC_NAME}, s3_region=${region})."
    else
      # Single node: strip the cluster-only tokens.
      sed -i "/__GARAGE_RPC_PUBLIC_ADDR__/d; /__GARAGE_BOOTSTRAP_PEERS__/d" "$runtime"
      echo "[bootstrap] Generated garage.runtime.toml (single-node, s3_region=${region})."
    fi

    echo "[bootstrap] Starting Garage..."
    if ! dc garage up -d; then
      _check_ts_auth garage
      exit 1
    fi

    # Poll until the Garage admin API responds (i.e. 'garage node id' exits 0).
    # This matches the container healthcheck and is immune to Docker health
    # state lag or healthcheck misconfiguration.
    echo "[bootstrap] Waiting for Garage to be ready (up to 90 s)..."
    local elapsed=0 interval=5 timeout=90
    while true; do
      local container
      container=$(dc garage ps -q garage 2>/dev/null | head -1)
      if [[ -n "$container" ]]; then
        if docker exec "$container" /garage node id >/dev/null 2>&1; then
          break
        fi
      fi
      elapsed=$(( elapsed + interval ))
      if [[ $elapsed -ge $timeout ]]; then
        die "Garage did not become ready after ${timeout}s.
  Check logs: ./bootstrap.sh logs garage
  Ensure GARAGE_RPC_SECRET is set correctly in .env"
      fi
      sleep "$interval"
    done

    if [[ "$rf" -le 1 ]]; then
      cmd_provision_garage
      return 0
    fi

    # Cluster node is up. Layout formation + bucket/key creation is a single
    # coordinated step run ONCE (on any node) after every node is up — so we
    # do NOT auto-provision here on each host.
    local gcontainer gpubkey=""
    gcontainer=$(dc garage ps -q garage 2>/dev/null | head -1)
    [[ -n "$gcontainer" ]] && gpubkey=$(docker exec "$gcontainer" /garage node id 2>/dev/null | head -1 | cut -d@ -f1)
    echo ""
    echo "[bootstrap] Garage node '${GARAGE_MAGIC_NAME}' is up (cluster mode, replication_factor=${rf})."
    if [[ -z "${GARAGE_BOOTSTRAP_PEERS:-}" ]]; then
      echo "[bootstrap] ------------------------------------------------------------"
      echo "[bootstrap] This node's peer id (for GARAGE_BOOTSTRAP_PEERS):"
      echo ""
      echo "    ${gpubkey}@${GARAGE_MAGIC_NAME}.${TS_TAILNET}:3901"
      echo ""
      echo "[bootstrap] NEXT: bring every node up once, collect all peer ids"
      echo "[bootstrap]   (./bootstrap.sh garage-peer-id on each host), set the"
      echo "[bootstrap]   combined comma-separated list as GARAGE_BOOTSTRAP_PEERS in"
      echo "[bootstrap]   EVERY host's .env, then re-run 'up garage' on each host."
      echo "[bootstrap] ------------------------------------------------------------"
    else
      echo "[bootstrap] Peers configured. Once ALL nodes are up, form the cluster"
      echo "[bootstrap] and create buckets/keys by running ONCE on any node:"
      echo "[bootstrap]     ./bootstrap.sh provision-garage"
    fi
    return 0
  fi

  # Generate stalwart/config/config.runtime.json from the tracked template,
  # substituting .env values. Pattern mirrors garage.runtime.toml.
  if [[ "$stack" == "stalwart" ]]; then
    local db_host="${DB_MAGIC_NAME}.${TS_TAILNET}"
    local db_name="${STALWART_DB_NAME:-stalwart}"
    local db_user="${STALWART_DB_USER:-stalwart}"
    sed \
      -e "s|__DB_HOST__|${db_host}|g" \
      -e "s|__STALWART_DB_NAME__|${db_name}|g" \
      -e "s|__STALWART_DB_USER__|${db_user}|g" \
      "${REPO_ROOT}/stalwart/config/config.json" \
      > "${REPO_ROOT}/stalwart/config/config.runtime.json"
    echo "[bootstrap] Generated stalwart/config/config.runtime.json (host=${db_host}, db=${db_name}, user=${db_user})."
  fi

  # Generate lemmy/lemmy.runtime.hjson from the tracked template.
  # Pattern mirrors garage.runtime.toml and stalwart config.runtime.json.
  if [[ "$stack" == "lemmy" ]]; then
    [[ -n "${LEMMY_DB_PASSWORD:-}" ]] || die "LEMMY_DB_PASSWORD is not set in .env"
    [[ -n "${LEMMY_PICTRS_API_KEY:-}" ]] || die "LEMMY_PICTRS_API_KEY is not set in .env"
    sed \
      -e "s|__LEMMY_DOMAIN__|${LEMMY_DOMAIN:-lemmy.example.com}|g" \
      -e "s|__DB_HOST__|${DB_MAGIC_NAME}.${TS_TAILNET}|g" \
      -e "s|__LEMMY_DB_NAME__|${LEMMY_DB_NAME:-lemmy}|g" \
      -e "s|__LEMMY_DB_USER__|${LEMMY_DB_USER:-lemmy}|g" \
      -e "s|__LEMMY_DB_PASSWORD__|${LEMMY_DB_PASSWORD}|g" \
      -e "s|__LEMMY_PICTRS_API_KEY__|${LEMMY_PICTRS_API_KEY}|g" \
      "${REPO_ROOT}/lemmy/lemmy.hjson" \
      > "${REPO_ROOT}/lemmy/lemmy.runtime.hjson"
    echo "[bootstrap] Generated lemmy/lemmy.runtime.hjson (domain=${LEMMY_DOMAIN:-lemmy.example.com}, host=${DB_MAGIC_NAME}.${TS_TAILNET})."
  fi

  # Authelia preflight: generate runtime config and fail fast on missing
  # operator-created files rather than letting Docker create empty directories
  # in their place (which silently breaks the container with confusing errors).
  if [[ "$stack" == "authelia" ]]; then
    # Generate configuration.runtime.yml from the tracked template.
    # Pattern mirrors garage.runtime.toml and stalwart config.runtime.json.
    # The tracked template ships placeholders only — no secrets or real domains.
    local authelia_domain="${AUTHELIA_DOMAIN:-auth.example.com}"
    local gts_url="${GOTOSOCIAL_URL:-gotosocial.example.com}"

    # GoToSocial OIDC client_secret: Authelia stores a pbkdf2 HASH; GTS holds the
    # plaintext (GOTOSOCIAL_OIDC_CLIENT_SECRET). Derive the hash here so only the
    # gitignored runtime config ever contains it. SSO must have a secret when
    # enabled; when off we hash a throwaway so the client stays valid-but-unused
    # (Authelia requires >=1 client).
    if [[ "${GOTOSOCIAL_OIDC_ENABLED:-false}" == "true" && -z "${GOTOSOCIAL_OIDC_CLIENT_SECRET:-}" ]]; then
      die "GOTOSOCIAL_OIDC_ENABLED=true but GOTOSOCIAL_OIDC_CLIENT_SECRET is empty.
  Generate one: openssl rand -hex 32"
    fi
    local gts_oidc_secret="${GOTOSOCIAL_OIDC_CLIENT_SECRET:-$(openssl rand -hex 16)}"
    local gts_oidc_hash
    gts_oidc_hash="$(docker run --rm "authelia/authelia:${AUTHELIA_VERSION:-4.39.20}" \
      authelia crypto hash generate pbkdf2 --variant sha512 --password "${gts_oidc_secret}" \
      2>/dev/null | sed -n 's/^Digest: //p')"
    [[ -n "$gts_oidc_hash" ]] || die "Failed to derive GoToSocial OIDC client secret hash (is docker + the authelia image available?)."

    # Mastodon OIDC client_secret: same pattern as GoToSocial — Authelia stores a
    # pbkdf2 HASH, Mastodon holds the plaintext (MASTODON_OIDC_CLIENT_SECRET).
    local mastodon_url="${MASTODON_DOMAIN:-mastodon.example.com}"
    if [[ "${MASTODON_OIDC_ENABLED:-false}" == "true" && -z "${MASTODON_OIDC_CLIENT_SECRET:-}" ]]; then
      die "MASTODON_OIDC_ENABLED=true but MASTODON_OIDC_CLIENT_SECRET is empty.
  Generate one: openssl rand -hex 32"
    fi
    local mastodon_oidc_secret="${MASTODON_OIDC_CLIENT_SECRET:-$(openssl rand -hex 16)}"
    local mastodon_oidc_hash
    mastodon_oidc_hash="$(docker run --rm "authelia/authelia:${AUTHELIA_VERSION:-4.39.20}" \
      authelia crypto hash generate pbkdf2 --variant sha512 --password "${mastodon_oidc_secret}" \
      2>/dev/null | sed -n 's/^Digest: //p')"
    [[ -n "$mastodon_oidc_hash" ]] || die "Failed to derive Mastodon OIDC client secret hash (is docker + the authelia image available?)."

    # --- PeerTube + heart-of-gold apps (console, babelfish) ---
    # Same pattern as GTS/Mastodon: Authelia stores the pbkdf2 HASH; the app holds
    # the plaintext (in its own .env, mirrored into this .env so we can hash it).
    # PeerTube was previously hand-added to the runtime — templating it here fixes
    # that fragility. An empty secret hashes a throwaway so the client stays a
    # valid-but-unused registration until it's wired (matches the SSO-off path).
    _oidc_hash() {
      docker run --rm "authelia/authelia:${AUTHELIA_VERSION:-4.39.20}" \
        authelia crypto hash generate pbkdf2 --variant sha512 --password "$1" \
        2>/dev/null | sed -n 's/^Digest: //p'
    }
    local peertube_url="${PEERTUBE_DOMAIN:-peertube.example.com}"
    local peertube_oidc_hash;  peertube_oidc_hash="$(_oidc_hash "${PEERTUBE_OIDC_CLIENT_SECRET:-$(openssl rand -hex 16)}")"
    local console_url="${CONSOLE_URL:-console.example.com}"
    local console_oidc_hash;   console_oidc_hash="$(_oidc_hash "${CONSOLE_OIDC_CLIENT_SECRET:-$(openssl rand -hex 16)}")"
    local babelfish_url="${BABELFISH_URL:-babelfish.example.com}"
    local babelfish_oidc_hash; babelfish_oidc_hash="$(_oidc_hash "${BABELFISH_OIDC_CLIENT_SECRET:-$(openssl rand -hex 16)}")"
    for _h in "$peertube_oidc_hash" "$console_oidc_hash" "$babelfish_oidc_hash"; do
      [[ -n "$_h" ]] || die "Failed to derive an OIDC client secret hash (docker + the authelia image available?)."
    done

    sed -e "s|__AUTHELIA_DOMAIN__|${authelia_domain}|g" \
        -e "s|__GOTOSOCIAL_URL__|${gts_url}|g" \
        -e "s|__GTS_OIDC_HASH__|${gts_oidc_hash}|g" \
        -e "s|__MASTODON_URL__|${mastodon_url}|g" \
        -e "s|__MASTODON_OIDC_HASH__|${mastodon_oidc_hash}|g" \
        -e "s|__PEERTUBE_URL__|${peertube_url}|g" \
        -e "s|__PEERTUBE_OIDC_HASH__|${peertube_oidc_hash}|g" \
        -e "s|__CONSOLE_URL__|${console_url}|g" \
        -e "s|__CONSOLE_OIDC_HASH__|${console_oidc_hash}|g" \
        -e "s|__BABELFISH_URL__|${babelfish_url}|g" \
        -e "s|__BABELFISH_OIDC_HASH__|${babelfish_oidc_hash}|g" \
      "${REPO_ROOT}/authelia/configuration.yml" \
      > "${REPO_ROOT}/authelia/configuration.runtime.yml"
    echo "[bootstrap] Generated authelia/configuration.runtime.yml (domain=${authelia_domain}, gts=${gts_url}/oidc=${GOTOSOCIAL_OIDC_ENABLED:-false}, mastodon=${mastodon_url}/oidc=${MASTODON_OIDC_ENABLED:-false})."

    local pem="${REPO_ROOT}/authelia/private.pem"
    local users="${REPO_ROOT}/authelia/users.yml"
    if [[ ! -f "$pem" ]]; then
      die "authelia/private.pem not found.
  Generate it once and keep it safe (it's gitignored):
    openssl genrsa -out ${REPO_ROOT}/authelia/private.pem 4096"
    fi
    if [[ ! -f "$users" ]]; then
      echo "[bootstrap] Warning: authelia/users.yml not found — creating empty placeholder."
      echo "[bootstrap] Add users with: ./bootstrap.sh user-create authelia"
      printf 'users: {}\n' > "$users"
    fi
  fi

  echo "[bootstrap] Starting ${stack}..."
  if ! dc "$stack" up -d; then
    _check_ts_auth "$stack"
    exit 1
  fi
  echo "[bootstrap] ${stack} is up. Tip: ./bootstrap.sh logs ${stack}"

  # Primary Postgres HA: once REPLICATION_PASSWORD is set, ensure the
  # replication role + physical slot exist so a standby can clone and stream.
  # No-op (skipped) for a single-node deployment that leaves it unset.
  if [[ "$stack" == "shared-db" && -n "${REPLICATION_PASSWORD:-}" ]]; then
    # Wait for the local Postgres socket before provisioning the role.
    local _pgc _tries=0
    while :; do
      _pgc=$(dc shared-db ps -q postgres 2>/dev/null | head -1)
      if [[ -n "$_pgc" ]] && docker exec "$_pgc" pg_isready -U postgres >/dev/null 2>&1; then
        break
      fi
      _tries=$(( _tries + 1 )); [[ $_tries -ge 30 ]] && { echo "[bootstrap] Postgres not ready — skipping replication role (run 'up shared-db' again)."; break; }
      sleep 2
    done
    [[ -n "$_pgc" ]] && _pg_ensure_replication
  fi

  # After Stalwart comes up, auto-run provision-stalwart (idempotent).
  # This wires stores, domain, listeners, and accounts from .env — same as
  # provision-garage auto-runs after 'up garage'. Run standalone any time:
  #   ./bootstrap.sh provision-stalwart
  if [[ "$stack" == "stalwart" ]]; then
    cmd_provision_stalwart
  fi

  # Lemmy has no admin CLI — the FIRST visitor to the site claims the admin
  # account via the web setup wizard. Surface that here so the operator isn't
  # left guessing (do NOT pre-create an admin; it consumes site_setup and the
  # real first visitor then lands on a login page instead of the wizard).
  if [[ "$stack" == "lemmy" ]]; then
    echo ""
    echo "[bootstrap] Lemmy admin is created on FIRST web visit (no CLI)."
    echo "[bootstrap] Visit https://${LEMMY_DOMAIN:-lemmy.example.com} and complete"
    echo "[bootstrap] the setup wizard to claim the admin account."
  fi
}

cmd_down() {
  local stack="${1:-}"
  [[ -n "$stack" ]] || die "Usage: ./bootstrap.sh down <stack>"
  require_stack "$stack"
  dc "$stack" down
}

# Restart a stack the SAFE way. Do NOT use `docker compose restart` on these
# stacks: every data service runs with `network_mode: "service:ts-<role>"` and
# borrows its Tailscale sidecar's network namespace. `docker compose restart`
# ignores `depends_on` ordering, so restarting the whole stack (or the sidecar)
# races the data container against the sidecar recreating its netns — the data
# container fails to join the namespace, exits 128, and `restart: unless-stopped`
# does NOT revive a *start* failure. Result: a dead DB behind a healthy-looking
# sidecar. down + up cycles in dependency order (sidecar healthy → then the data
# container) and reuses all the runtime-config generation / provisioning in
# cmd_up. (Bouncing a single app service — `docker compose restart <appservice>`,
# sidecar untouched — is fine; this subcommand just removes the footgun.)
cmd_restart() {
  local stack="${1:-}"
  [[ -n "$stack" ]] || die "Usage: ./bootstrap.sh restart <stack>"
  require_stack "$stack"
  echo "[bootstrap] Restarting ${stack} (down + ordered up — never 'compose restart')..."
  cmd_down "$stack"
  cmd_up "$stack"
}

cmd_logs() {
  local stack="${1:-}"
  [[ -n "$stack" ]] || die "Usage: ./bootstrap.sh logs <stack> [service]"
  require_stack "$stack"
  local service="${2:-}"
  dc "$stack" logs -f $service
}

cmd_ps() {
  local stack="${1:-}"
  if [[ -n "$stack" ]]; then
    require_stack "$stack"
    dc "$stack" ps
  else
    for s in "${ALL_STACKS[@]}"; do
      echo "=== ${s} ==="
      dc "$s" ps 2>/dev/null || true
    done
  fi
}

cmd_user_create() {
  local app="${1:-}"  username="${2:-}"  email="${3:-}"
  [[ -n "$app" && -n "$username" && -n "$email" ]] ||
    die "Usage: ./bootstrap.sh user-create <app> <username> <email>"

  # Generate a strong random password for apps that need one passed in.
  local password
  password="$(openssl rand -base64 24)"

  case "$app" in

    mastodon)
      echo "[bootstrap] Creating Mastodon admin: ${username} <${email}>"
      echo "[bootstrap] tootctl will print a generated password below. Save it."
      echo ""
      dc mastodon run --rm web \
        bundle exec tootctl accounts create "$username" \
          --email "$email" --confirmed --approve --role Owner
      dc mastodon run --rm web \
        bundle exec tootctl accounts modify "$username" --enable
      ;;

    pixelfed)
      echo "[bootstrap] Creating Pixelfed admin: ${username} <${email}>"
      echo "[bootstrap] Generated password: ${password}"
      echo "[bootstrap] Change it at: https://${PIXELFED_DOMAIN:-your-domain}/settings"
      echo "[bootstrap] NOTE: password reset requires SMTP to be configured (no reset CLI exists)."
      echo ""
      dc pixelfed run --rm web \
        php artisan user:create \
          --name="$username" \
          --username="$username" \
          --email="$email" \
          --password="$password" \
          --confirm_email=1
      dc pixelfed run --rm web \
        php artisan user:admin "$username"
      ;;

    diaspora)
      # Diaspora has no user:create CLI. Uses rails runner via exec into the
      # running container.
      #
      # Three quirks solved here:
      # 1. bundle lives in RVM dirs (~/.rvm/gems/.../bin) only added to PATH
      #    by a login shell sourcing ~/.bash_profile. `/bin/bash -lc` does that.
      # 2. Must run as the `diaspora` user (--user) so RVM reads the right home.
      # 3. Ruby code is passed via env var (BOOTSTRAP_RUBY) so we don't embed
      #    Ruby single-quotes inside bash single-quotes inside a shell command.
      local ruby_code
      read -r -d '' ruby_code << 'RUBY' || true
u = User.build(
  username: ENV["BOOTSTRAP_USERNAME"],
  email:    ENV["BOOTSTRAP_EMAIL"],
  password: ENV["BOOTSTRAP_PASSWORD"],
  password_confirmation: ENV["BOOTSTRAP_PASSWORD"]
)
u.getting_started = false
u.save! or raise u.errors.full_messages.join(", ")
u.person.profile = Profile.new(first_name: ENV["BOOTSTRAP_USERNAME"])
u.person.save!
Role.add_admin(u.person)
puts "Created: " + u.username + " <" + u.email + ">"
RUBY
      echo "[bootstrap] Creating Diaspora admin: ${username} <${email}>"
      echo "[bootstrap] Generated password: ${password}"
      echo "[bootstrap] Change it at: ${DIASPORA_URL:-https://your-diaspora-domain/}profile/edit"
      echo ""
      BOOTSTRAP_USERNAME="$username" \
      BOOTSTRAP_EMAIL="$email" \
      BOOTSTRAP_PASSWORD="$password" \
      BOOTSTRAP_RUBY="$ruby_code" \
      dc diaspora exec \
        --user diaspora \
        -e BOOTSTRAP_USERNAME \
        -e BOOTSTRAP_EMAIL \
        -e BOOTSTRAP_PASSWORD \
        -e BOOTSTRAP_RUBY \
        diaspora \
        /bin/bash -lc 'cd /home/diaspora/diaspora && bundle exec rails runner "$BOOTSTRAP_RUBY"'
      ;;

    funkwhale)
      echo "[bootstrap] Creating Funkwhale admin: ${username} <${email}>"
      echo "[bootstrap] Generated password: ${password}"
      echo "[bootstrap] Change it at: https://${FUNKWHALE_DOMAIN:-your-domain}/settings"
      echo ""
      dc funkwhale run --rm api \
        funkwhale-manage fw users create \
          --superuser \
          --username "$username" \
          --email "$email" \
          --password "$password"
      ;;

    peertube)
      # PeerTube auto-creates the "root" admin on first boot and prints a
      # random password to the container logs. There is no admin-create CLI;
      # the username/email args are ignored. After first login change the
      # password and email via the web UI.
      echo "[bootstrap] Retrieving auto-generated PeerTube root password from logs..."
      echo "[bootstrap] (Provided username/email args are ignored — root is the only auto-created user.)"
      echo ""
      dc peertube logs peertube 2>&1 | grep -iE "user.*password|root.*password|admin.*password" \
        || die "Could not find password in logs. Try: ./bootstrap.sh logs peertube peertube | grep -i password
If the container has been restarted many times, the boot-time log line may have rolled off.
You can reset the root password instead:
  docker exec -it federated-peertube-peertube-1 npm run reset-password -- -u root"
      ;;

    gotosocial)
      echo "[bootstrap] Creating GoToSocial admin: ${username} <${email}>"
      echo "[bootstrap] Generated password: ${password}"
      echo "[bootstrap] Change it at: https://${GOTOSOCIAL_URL:-your-domain}/settings"
      echo ""
      # docker compose run swallows --username as its own -u/--user flag.
      # Use docker exec into the running container instead — same approach as
      # the user's working manual command.
      local cid
      cid=$(dc gotosocial ps -q gotosocial 2>/dev/null | head -1)
      [[ -n "$cid" ]] || die "GoToSocial is not running. Start it first: ./bootstrap.sh up gotosocial"
      docker exec "$cid" \
        /gotosocial/gotosocial admin account create \
          --username "$username" \
          --email "$email" \
          --password "$password"
      docker exec "$cid" \
        /gotosocial/gotosocial admin account promote --username "$username"
      ;;

    lemmy)
      echo "[bootstrap] Lemmy creates the admin account on first web visit."
      echo "[bootstrap] Navigate to https://${LEMMY_DOMAIN:-lemmy.example.com} and follow the setup wizard."
      echo "[bootstrap] (No CLI user-create — the web setup wizard is the only path.)"
      ;;

    authelia)
      echo "[bootstrap] Authelia has no CLI user-create flow."
      echo "[bootstrap] Steps to add users:"
      echo "[bootstrap]   1. Bring up the authelia stack first: ./bootstrap.sh up authelia"
      echo "[bootstrap]   2. Generate a password hash:"
      echo "[bootstrap]      docker exec federated-authelia-authelia-1 authelia crypto hash generate argon2 --password 'yourpassword'"
      echo "[bootstrap]   3. Edit authelia/users.yml with the hashed password."
      echo "[bootstrap]      (users.yml is gitignored — it is operator-managed)"
      ;;

    *)
      die "Unknown app '${app}'. Valid: mastodon pixelfed diaspora funkwhale gotosocial peertube authelia lemmy"
      ;;

  esac
}

cmd_backup_cron() {
  # Wizard step: install/update the nightly pg-backup cron in the operator's
  # OWN crontab. Rootless by design — logs to the repo-local log/ dir, never
  # /var/log — so it works for an unprivileged shell account.
  local script="${REPO_ROOT}/backup/pg-backup.sh"
  [[ -f "$script" ]] || die "Not found: ${script}"

  echo "[bootstrap] Configure the nightly Postgres backup (pg-backup.sh)."
  echo ""

  # --- Alert email (cron MAILTO) -------------------------------------------
  # Default to SMTP_FROM_NAME from .env; require something email-shaped so a
  # placeholder like 'Federated Social' can't slip in as the recipient.
  local default_email="${SMTP_FROM_NAME:-}" email=""
  while :; do
    if [[ -n "$default_email" ]]; then
      read -r -p "  Email for failure alerts [${default_email}]: " email
      email="${email:-$default_email}"
    else
      read -r -p "  Email for failure alerts: " email
    fi
    [[ "$email" == *@* ]] && break
    echo "  '${email}' isn't an email address (need name@domain) — try again."
    default_email=""
  done

  # --- Run time -------------------------------------------------------------
  local default_hour=3 hour
  read -r -p "  Hour to run, 0-23 [${default_hour}]: " hour
  hour="${hour:-$default_hour}"
  [[ "$hour" =~ ^([0-9]|1[0-9]|2[0-3])$ ]] || die "Invalid hour '${hour}' — must be 0-23."

  # --- Compose the managed crontab block -----------------------------------
  # cron emails OUTPUT, not exit codes — with everything redirected into the
  # log, a failure would never reach MAILTO. The || echo puts one line on
  # stdout only when the script fails, so that's the only mail cron sends.
  local cmd_line="cd ${REPO_ROOT} && ./backup/pg-backup.sh >> log/pg-backup.log 2>&1 || echo \"pg-backup FAILED on \$(hostname) — see ${REPO_ROOT}/log/pg-backup.log\""
  local cron_line="0 ${hour} * * * ${cmd_line}"
  local begin="# >>> federatedSocial pg-backup (managed by bootstrap.sh) >>>"
  local end="# <<< federatedSocial pg-backup (managed by bootstrap.sh) <<<"

  # Idempotent: strip any previously-managed block, then append the fresh one.
  # (MAILTO lives INSIDE the block on its own line — no inline comment, since
  # cron treats the whole RHS of a MAILTO= line as the value.)
  local current rest
  current="$(crontab -l 2>/dev/null || true)"
  rest="$(printf '%s\n' "$current" | awk -v b="$begin" -v e="$end" '
    $0==b {skip=1; next} $0==e {skip=0; next} skip!=1 {print}')"

  # Warn about a pre-existing hand-written pg-backup line outside our markers,
  # so the operator can remove it rather than end up running the backup twice.
  if printf '%s\n' "$rest" | grep -q 'pg-backup\.sh'; then
    echo ""
    echo "[bootstrap] Note: found an existing (unmanaged) pg-backup line in your crontab."
    echo "[bootstrap]   Leaving it untouched; remove it with 'crontab -e' to avoid double runs."
  fi

  {
    [[ -n "${rest//[[:space:]]/}" ]] && printf '%s\n' "$rest"
    echo "$begin"
    echo "MAILTO=${email}"
    echo "$cron_line"
    echo "$end"
  } | crontab -

  echo ""
  echo "[bootstrap] Installed in $(whoami)'s crontab:"
  echo "             ${cron_line}"
  echo "[bootstrap]   alerts → ${email}"
  echo "[bootstrap]   logs   → ${REPO_ROOT}/log/pg-backup.log"
  echo "[bootstrap] Inspect: crontab -l   ·   Edit/remove: crontab -e"
}

usage() {
  cat <<EOF
Usage: ./bootstrap.sh <command> [args]

  up                  <stack>               Bring up a stack
  down                <stack>               Tear down a stack
  restart             <stack>               Safely restart a stack (down + ordered up)
  logs                <stack> [service]     Tail logs (Ctrl-C to stop)
  ps                  [stack]               Show container status for one or all stacks
  provision-db        <app>                 Idempotent DB role + database setup
  provision-garage                          Idempotent Garage layout + bucket + key setup
  garage-peer-id                            Print this host's Garage cluster peer id
  provision-stalwart                        Configure Stalwart via JMAP (auto-run by 'up stalwart')
  pg-promote                                Promote this Postgres standby to primary (failover)
  pg-rejoin                                 Re-clone this host as a fresh standby (post-failover)
  stalwart-redis-promote                    Promote this Stalwart Redis standby to primary (failover)
  user-create         <app> <user> <email>  Create an admin user
  backup-cron                               Install the nightly pg-backup cron (interactive)

Stacks: ${ALL_STACKS[*]}

Postgres HA (see README "Postgres high availability"):
  ./bootstrap.sh up shared-db          # primary: also creates the replication role/slot
  ./bootstrap.sh up shared-db          # standby host (PG_ROLE=standby): clones + streams
  ./bootstrap.sh up pg-router          # app-facing endpoint -> current primary
  ./bootstrap.sh pg-promote            # on the standby, during a failover
  ./bootstrap.sh pg-rejoin             # re-clone a returned old primary as the new standby

Stalwart Redis HA (see README "Stalwart Redis high availability"):
  ./bootstrap.sh up stalwart-redis            # primary (default) or standby host (STALWART_REDIS_ROLE)
  ./bootstrap.sh up stalwart-redis-router     # Stalwart-facing endpoint -> current primary
  ./bootstrap.sh stalwart-redis-promote       # on the standby, during a failover

Examples:
  ./bootstrap.sh up shared-db
  ./bootstrap.sh up mastodon
  ./bootstrap.sh provision-db peertube
  ./bootstrap.sh user-create mastodon alice alice@example.com
  ./bootstrap.sh user-create funkwhale alice alice@example.com
  ./bootstrap.sh ps
  ./bootstrap.sh logs mastodon web
  ./bootstrap.sh backup-cron

Note: 'up' calls provision-db automatically when shared-db is running.
      Run shared-db first, then 'up <app>' — the DB will be ready.
EOF
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

command="${1:-help}"
shift || true

case "$command" in
  up)           cmd_up "$@" ;;
  down)         cmd_down "$@" ;;
  restart)      cmd_restart "$@" ;;
  logs)         cmd_logs "$@" ;;
  ps)           cmd_ps "$@" ;;
  provision-db)          cmd_provision_db "$@" ;;
  provision-garage)      cmd_provision_garage ;;
  garage-peer-id)        cmd_garage_peer_id ;;
  provision-stalwart)    cmd_provision_stalwart ;;
  pg-promote)            cmd_pg_promote ;;
  pg-rejoin)             cmd_pg_rejoin ;;
  stalwart-redis-promote) cmd_stalwart_redis_promote ;;
  user-create)           cmd_user_create "$@" ;;
  backup-cron)           cmd_backup_cron ;;
  help|--help|-h) usage ;;
  *) echo "Unknown command: ${command}"; echo ""; usage; exit 1 ;;
esac
