# CLAUDE.md

Guidance for Claude Code working in this repository. Read this fully before editing any file.

## What this repo is

A Tailscale-native, "play-not-work" deployment template for self-hosted federated social services (Pixelfed, Mastodon, Funkwhale, etc.) on a single Debian host (with a clean path to multi-host clustering later).

The design goal: an unseasoned operator should be able to clone this repo, edit one `.env` file, paste one ACL JSON into the Tailscale admin console, and run `docker compose up -d` in each stack directory. They should never need to touch iptables, learn Docker networking internals, or hand-configure TLS for internal services.

The security model is **Tailscale ACLs over Docker network namespaces**, not host firewall rules. Internal services (Postgres, Redis) publish no ports and are unreachable from the internet or LAN; their reachable interface is `tailscale0` inside their sidecar's namespace (plus the compose project's bridge, visible only to the host and same-project containers — see SECURITY.md §1.1). The host Nginx terminates public TLS and proxies to public-facing app tiers via MagicDNS.

## Architecture

### Topology

- **Shared services stack** (`shared-db/`): Postgres + Redis, each behind its own Tailscale sidecar. No host port bindings. Tagged `tag:db-postgres` and `tag:db-redis`. Reachable only via tailnet.
- **Per-app stacks** (`pixelfed/`, `mastodon/`, `funkwhale/`, ...): Each app's web/worker/streaming components run behind their own Tailscale sidecars, tagged per role. They reach Postgres/Redis via MagicDNS hostnames over the tailnet.
- **Host Nginx** (not containerized, see "Host Nginx" below): terminates public TLS, proxies to app web tiers by MagicDNS name.
- **Host-level Tailscale**: already installed and authenticated on the Debian host. Independent of the sidecars. Used by host Nginx to resolve MagicDNS and reach app web tiers, and used by Syncthing (separate concern, do not touch).

### The sidecar pattern

Every container that needs tailnet identity gets its own `tailscale/tailscale` sidecar. The app container uses `network_mode: "service:<sidecar-name>"` to share the sidecar's network namespace. This means:

- The app container has no network interfaces of its own.
- The app's "localhost" is the sidecar's localhost.
- The app's tailnet path is `tailscale0`. (The shared netns also has the compose project's default bridge — the sidecar needs it to reach the Tailscale coordination server. It is NATed egress only, reachable inbound solely from the host and same-project containers; see SECURITY.md §1.1. Postgres additionally rejects non-tailnet sources via `pg_hba.conf`.)
- No explicit `networks:` are attached to these containers, and no `ports:` mapping is possible or appropriate.

This is the security boundary. **Do not break it.**

### Auth model

- Single OAuth client registered in Tailscale admin console, scoped to the tags this repo uses.
- Client ID + client secret stored in top-level `.env`.
- Every sidecar passes `TS_AUTHKEY=${TS_OAUTH_CLIENT_SECRET}?ephemeral=true` and advertises its tag via `TS_EXTRA_ARGS=--advertise-tags=tag:<role>`.
- Nodes are **ephemeral**: `docker compose down` self-cleans them from the admin console. No `TS_STATE_DIR` volumes.
- Ephemeral nodes get new tailnet IPs on each restart. **MagicDNS hostnames are stable.** Always reference services by MagicDNS name, never by IP.

## Repo layout

```
federated-social/
├── CLAUDE.md                   # this file
├── README.md                   # operator-facing setup guide
├── .env.example                # template; operators copy to .env
├── acl.example.hujson          # Tailscale ACL template
├── shared-db/
│   └── docker-compose.yml      # postgres + redis + sidecars
├── pixelfed/
│   └── docker-compose.yml
├── mastodon/
│   └── docker-compose.yml
├── funkwhale/
│   └── docker-compose.yml
└── nginx/
    └── sites-available/        # host nginx snippets, reference only
```

Each app directory is self-contained and copy-pasteable. Adding a new app means copying an existing app directory, renaming, updating tags, and adding the tag to the ACL.

## The `.env` contract

The `.env` file at the repo root is the entire operator surface. Every compose file reads from it. Never hardcode values that belong in `.env`.

Required keys:

```bash
# Tailscale OAuth (from admin console, one-time)
TS_OAUTH_CLIENT_ID=
TS_OAUTH_CLIENT_SECRET=
TS_TAILNET=                     # e.g. tailfe8c.ts.net

# MagicDNS hostnames (operator picks these once)
DB_MAGIC_NAME=pgsql-prod
REDIS_MAGIC_NAME=redis-prod
PIXELFED_MAGIC_NAME=pixelfed
MASTODON_WEB_MAGIC_NAME=mastodon
MASTODON_STREAMING_MAGIC_NAME=mastodon-streaming
# ... one per public-facing app component

# Database credentials
POSTGRES_PASSWORD=
PIXELFED_DB_NAME=pixelfed
PIXELFED_DB_USER=pixelfed
PIXELFED_DB_PASSWORD=
MASTODON_DB_NAME=mastodon
MASTODON_DB_USER=mastodon
MASTODON_DB_PASSWORD=
# ... one set per app

# App-specific (varies)
PIXELFED_DOMAIN=
MASTODON_DOMAIN=
```

When adding a new app or component, add its env vars to `.env.example` with sensible defaults or empty placeholders, and document any non-obvious value in a comment.

### Shared infrastructure credentials

Two cross-cutting concerns are configured **once** and mapped into every app, rather than per-app:

- **SMTP relay**: `SMTP_HOST` / `SMTP_PORT` / `SMTP_USER` / `SMTP_PASSWORD` / `SMTP_FROM_NAME`. Each app's compose maps these into the app-specific names it expects (Mastodon `SMTP_SERVER`, GoToSocial `GTS_SMTP_HOST`, PeerTube `PEERTUBE_SMTP_HOSTNAME`, Pixelfed `MAIL_HOST`, Diaspora `CONFIGURATION_MAIL_SMTP_HOST`). Funkwhale is the exception — it takes a single `EMAIL_CONFIG` connection string, so it can't read the discrete vars; document the `smtp+tls://` form with the URL-encoding caveat instead.
- **Garage S3**: `GARAGE_REGION` is shared; access keys are **per-app** (`<APP>_GARAGE_KEY_ID` / `<APP>_GARAGE_KEY_SECRET`, minted by `bootstrap.sh provision-garage`, each scoped to only that app's buckets — SECURITY.md §5.7). When adding a new app with object storage, add its bucket + key mapping to `provision-garage` and its key pair to `.env.example`; never point a new app at another app's key.
- **Redis**: two password-protected instances behind the one `ts-redis` sidecar — main (`:6379`, `REDIS_APPS_PASSWORD`, fediverse apps + Stalwart) and Authelia-only (`:6380`, `REDIS_AUTHELIA_PASSWORD`, its own ACL grant). Redis logical DB indices are namespacing, not a security boundary; anything session/identity-critical belongs on a separate instance behind a port-scoped grant, not on another index.

Per-app values that legitimately differ (sender addresses, bucket names, enable toggles) stay in the app's own section. When adding a new app, wire its SMTP and S3 to the shared vars; only add a new per-app var when the value genuinely can't be shared.

**Compose can't nest variable defaults** (`${A:-${B}}` is unreliable — see the pitfalls section), so you can't do "per-app override falling back to shared." Map the shared var directly; if an operator needs a different relay for one app, they edit that compose file.

## Sidecar boilerplate

Every Tailscale sidecar service uses this skeleton. Deviations need a stated reason.

```yaml
ts-<role>:
  image: tailscale/tailscale:latest
  hostname: ${<ROLE>_MAGIC_NAME}
  environment:
    TS_AUTHKEY: ${TS_OAUTH_CLIENT_SECRET}?ephemeral=true
    TS_EXTRA_ARGS: --advertise-tags=tag:<role>
    TS_HOSTNAME: ${<ROLE>_MAGIC_NAME}
    TS_ACCEPT_DNS: "true"
    TS_AUTH_ONCE: "true"
    TS_USERSPACE: "false"
    TS_ENABLE_HEALTH_CHECK: "true"
    TS_LOCAL_ADDR_PORT: "127.0.0.1:9002"
  devices:
    - /dev/net/tun:/dev/net/tun
  cap_add:
    - NET_ADMIN
    - NET_RAW
  # containerboot (PID 1) never reaps: orphans from the healthcheck or a
  # `docker exec` would zombie forever. tini reaps; SIGTERM still forwards.
  init: true
  healthcheck:
    test: ["CMD", "wget", "-qO-", "http://127.0.0.1:9002/healthz"]
    interval: 10s
    timeout: 5s
    retries: 6
    start_period: 30s
  restart: unless-stopped
```

Notes on each setting (do not change without reason):

- `TS_USERSPACE: "false"` + `cap_add: [NET_ADMIN, NET_RAW]` + `/dev/net/tun` — kernel networking. Userspace would work but is slower and Postgres/Redis benefit from kernel mode.
- `TS_ACCEPT_DNS: "true"` — required for MagicDNS resolution inside the namespace. Without this, `${DB_MAGIC_NAME}.${TS_TAILNET}` won't resolve. **Never omit.**
- `TS_ENABLE_HEALTH_CHECK: "true"` + `TS_LOCAL_ADDR_PORT: "127.0.0.1:9002"` — exposes `/healthz` for Compose to wait on. Bind to 127.0.0.1, never `0.0.0.0` or `[::]`, so it isn't reachable across the tailnet.
- Ephemeral auth: the `?ephemeral=true` suffix on the auth key is required. Do not remove it without also adding `TS_STATE_DIR` and a persistent volume.
- `init: true` — containerboot (the Tailscale image's PID 1) never reaps child processes. The healthcheck above forks a `wget`/`nc` pipeline; if Docker kills it mid-run on timeout, the orphaned child reparents to PID 1 and zombies for the container's lifetime (confirmed empirically, not just in theory — see the commit that added this). `tini` still forwards `SIGTERM`, so nothing about shutdown changes. Any app container whose healthcheck also forks a helper (`ps | grep`, etc.) and whose PID 1 isn't already an init (check the image's own `ENTRYPOINT` — Mastodon's is `tini --`, so its containers are already covered) needs the same `init: true`.

## App container pattern

Every app container that needs tailnet presence:

```yaml
<app>:
  image: <app-image>
  network_mode: "service:ts-<role>"
  environment:
    DB_HOST: ${DB_MAGIC_NAME}.${TS_TAILNET}
    REDIS_HOST: ${REDIS_MAGIC_NAME}.${TS_TAILNET}
    # ... other app env
  depends_on:
    ts-<role>:
      condition: service_healthy
  restart: unless-stopped
```

Hard rules:

- **No `ports:` directive on app containers using `network_mode: "service:..."`**. It's a Compose error and exposes nothing useful.
- **No `networks:` directive on these containers** — they share the sidecar's namespace.
- **`depends_on` must use `condition: service_healthy`**, not the bare form. Bare `depends_on` only waits for container start, not tailnet authentication, and the app will crash-loop trying to dial MagicDNS names that haven't resolved yet.
- **DB/Redis hostnames are always `${VAR_NAME}.${TS_TAILNET}` form**. Never `db`, never `localhost`, never an IP.

## The leak-resistance invariant

This is the most important property of the repo. Internal services (Postgres, Redis, anything in `shared-db/` or future internal stacks) must satisfy all three:

1. **No `ports:` mapping anywhere in their compose file.**
2. **The data container uses `network_mode: "service:<sidecar>"`** so it cannot publish ports or join extra networks; its externally reachable interface is `tailscale0` (SECURITY.md §1.1 covers the host-only bridge caveat).
3. **Tailscale ACLs gate access by tag**, not by IP or hostname.

If a change would violate any of these, stop and surface it to the user. Do not "just add a port for debugging" — operators should debug via `tailscale ssh` or a temporary admin tag in the ACL, never by exposing a host port.

Public-facing app web tiers are different: they are reached by host Nginx via MagicDNS, and the host Nginx is the only thing that should reach them. They still don't bind host ports — Nginx proxies to their tailnet hostname.

## Host Nginx

Nginx stays on the host (not containerized) for now. The host has Tailscale installed and can resolve MagicDNS, so configs look like:

```nginx
server {
    listen 443 ssl http2;
    server_name pixelfed.example.com;
    # ... ssl config ...

    location / {
        proxy_pass http://pixelfed.tailfe8c.ts.net:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Reference snippets live in `nginx/sites-available/` for operators to copy. Do not propose containerizing Nginx without explicit user request — the operator's existing legacy infrastructure depends on host Nginx.

## ACL conventions

The Tailscale ACL is the security policy. It lives in `acl.example.hujson` as a template, and operators paste it into the admin console.

Tag naming convention: `tag:<app>-<role>` where role is one of `web`, `streaming`, `worker`, or for shared services `tag:db-<engine>`.

Examples in use:

- `tag:db-postgres`, `tag:db-redis` — shared services
- `tag:pixelfed-web`, `tag:pixelfed-worker`
- `tag:mastodon-web`, `tag:mastodon-streaming`, `tag:mastodon-sidekiq`

ACL rules follow the principle: **app tiers can reach exactly the shared services they need, on exactly the ports they need, and nothing else**. Admin group can reach everything for debugging.

```hujson
{
  "tagOwners": {
    "tag:db-postgres":         ["autogroup:admin"],
    "tag:db-redis":            ["autogroup:admin"],
    "tag:pixelfed-web":        ["autogroup:admin"],
    "tag:pixelfed-worker":     ["autogroup:admin"],
    "tag:mastodon-web":        ["autogroup:admin"],
    "tag:mastodon-streaming":  ["autogroup:admin"],
    "tag:mastodon-sidekiq":    ["autogroup:admin"],
  },
  "acls": [
    {
      "action": "accept",
      "src": [
        "tag:pixelfed-web", "tag:pixelfed-worker",
        "tag:mastodon-web", "tag:mastodon-streaming", "tag:mastodon-sidekiq",
      ],
      "dst": ["tag:db-postgres:5432", "tag:db-redis:6379"],
    },
    {
      "action": "accept",
      "src": ["autogroup:admin"],
      "dst": ["*:*"],
    },
  ],
}
```

When adding a new app, add its tags to `tagOwners` and add its web/worker tags to the `src` list of the DB-access rule. Don't broaden the `dst` ports without reason.

## Bring-up order

`shared-db/` must be up and healthy before any app stack. The DB sidecars must be reachable on the tailnet (visible in admin console, MagicDNS resolves) before app sidecars try to dial them.

Documented operator order in `README.md`:

1. `cd shared-db && docker compose up -d`
2. Wait for both DB sidecars to appear in admin console.
3. `cd pixelfed && docker compose up -d` (or any other app stack).

Compose `depends_on` cannot enforce this across separate compose files. The healthcheck on the app sidecar will catch a missing DB at app boot, but the failure mode is a crash loop, not a clean message. Document the order; don't try to engineer around it.

## When editing compose files

- Preserve the sidecar boilerplate exactly. If a Tailscale parameter changes, update every sidecar consistently in one pass.
- Every new env var added to a compose file must also appear in `.env.example` with a comment.
- Every new tag must be added to `acl.example.hujson` with a corresponding rule.
- Every new app must include `TS_ACCEPT_DNS: "true"` on its sidecar. Forgetting this is the single most common breakage.
- Healthchecks are mandatory on sidecars. Don't remove them to "simplify."
- Volumes for stateful containers (Postgres data, Redis if persistent, app uploads) must be named volumes declared at the bottom of the compose file. Never bind-mount to host paths without explicit user instruction.

## When adding a new federated app

1. Copy the closest existing app directory (e.g. `pixelfed/` for a single-web-tier app, `mastodon/` for a multi-component app).
2. Rename services and update `TS_HOSTNAME` / `--advertise-tags` for each sidecar.
3. Add new env vars to `.env.example`.
4. Add new tags to `acl.example.hujson` and add them to the DB-access rule's `src` list.
5. Add a host Nginx reference snippet in `nginx/sites-available/`.
6. Update `README.md` operator instructions.
7. Verify: no `ports:` directives, every sidecar has `TS_ACCEPT_DNS: "true"`, every app has `depends_on: condition: service_healthy`, all hostnames use `${VAR}.${TS_TAILNET}` form.

### Pitfalls learned the hard way

- **Compose does not expand variables inside other variables.** Writing `MY_HOST=${DB_MAGIC_NAME}.${TS_TAILNET}` and then referencing `${MY_HOST}` produces an empty string. Always inline `${DB_MAGIC_NAME}.${TS_TAILNET}` directly in the consuming env var (e.g. `GTS_DB_ADDRESS`, `DATABASE_HOST`).
- **Check the app's actual env-var → config-key mapping before naming variables.** Apps derive env-var names in different ways and a wrong name is silently ignored. Examples caught in this repo: GoToSocial maps `db-address` → `GTS_DB_ADDRESS` (not `GTS_DB_HOST`); PeerTube maps `secrets.peertube` → `PEERTUBE_SECRET` (not `PEERTUBE_SECRETS_PEERTUBE`). Always verify against the app's `custom-environment-variables.yaml` or equivalent before writing a new env var.
- **Many official images set the binary as `ENTRYPOINT`.** When invoking via `docker compose run <svc> <cmd>`, do NOT prefix with the binary name — that becomes the first argv and scrambles the CLI parser. Pass subcommands directly.
- **`docker compose run` parses its own flags interspersedly** and will swallow app flags that overlap (notably `--user`/`--username`). For app admin commands that take `--username`, use `docker exec` into the already-running container instead of `docker compose run`.
- **Bind-mounted cache directories inherit host ownership.** For caches that the app writes to as a non-root uid (e.g. GTS Wazero cache), use a named volume instead — Docker manages ownership from the image filesystem.
- **`shared-db/initdb/*.sh` only runs on an empty pg-data volume.** Use `bootstrap.sh provision-db <app>` instead — it is idempotent and works on any volume state.
- **Passwords with `/` or `+` break `DATABASE_URL`-style connection strings.** Apps that assemble a URI from parts (e.g. Funkwhale: `postgresql://user:password@host/db`) will mis-parse a base64 password containing slashes as URI path separators. Use `openssl rand -hex 32` for any password embedded in a URL, and note this constraint in `.env.example` next to the affected variable.

## What not to do

- **Don't add `ports:` to any internal service.** If a port is needed externally, route it through host Nginx + MagicDNS.
- **Don't add Docker bridge networks between sidecar-attached containers.** They share the sidecar netns; bridges are redundant and break the model.
- **Don't suggest containerizing host Nginx** unless the user explicitly asks. The user's legacy infrastructure constrains this choice.
- **Don't replace ephemeral auth with persistent state** unless the user explicitly asks. The play-not-work design depends on `docker compose down` being a clean operation.
- **Don't reference services by tailnet IP.** Always MagicDNS hostnames.
- **Don't add complexity that the operator has to learn.** Complexity belongs in the templates the user (the repo author) maintains, not in the operator's day. If a fix requires the operator to learn a new concept, surface that tradeoff before implementing.
- **Don't bind healthcheck or metrics endpoints to anything other than 127.0.0.1.** Binding to `[::]` or `0.0.0.0` exposes them across the tailnet.

## Editor and tooling notes

- The repo author uses Vim/Neovim. Keep formatting clean and consistent — 2-space indent in YAML, no trailing whitespace.
- Compose file version field: omit it (modern Compose ignores it and warns if present).
- Comments in compose files are welcome where they explain non-obvious choices, especially around the sidecar pattern.

## Open design questions

These are deliberately unresolved and should be flagged to the user when relevant, not silently decided:

- **Multi-host clustering**: partially implemented. **Garage** clusters across multiple hosts today — set `GARAGE_REPLICATION_FACTOR>1`, run the `garage/` stack per host with a per-host `GARAGE_MAGIC_NAME`/`GARAGE_ZONE`, and assemble `GARAGE_BOOTSTRAP_PEERS` from each node's `bootstrap.sh garage-peer-id` (see the Garage cluster block in `.env.example`, the multi-node branch in `bootstrap.sh`'s `cmd_up`/`cmd_provision_garage`, and the `tag:garage → tag:garage:3901` ACL grant). **Postgres** now has an opt-in HA path (uptime, not backups): a `pg_basebackup` streaming hot-standby on a second host (`PG_ROLE=standby`, per-host `PG_NODE_MAGIC_NAME`, shared `REPLICATION_*`), a `pg-router/` nginx-stream sidecar that takes the `DB_MAGIC_NAME` identity and forwards to `PG_PRIMARY_MAGIC_NAME` (so apps are unchanged), manual promotion (`bootstrap.sh pg-promote`) + router repoint on failover, and re-clone via `pg-rejoin`. The `tag:db-postgres → tag:db-postgres:5432` self-grant covers replication + router→primary. Async replication + manual failover is deliberate (no etcd/Patroni) for the single-operator threat model; keep the invariant that the standby entrypoint (`shared-db/pg-entrypoint.sh`) is a strict no-op for a primary so single-node stays byte-identical. **Redis is intentionally left single-instance for the fediverse apps' shared instance** (`REDIS_MAGIC_NAME`) — it's cache/queue there (Authelia sessions are the only stateful bit, and losing them just forces re-login), so the HA complexity isn't worth it for that instance; an outage degrades rather than destroys. **Stalwart's Redis is different and DOES have an opt-in HA path**: it's a separate, dedicated instance (`stalwart-redis/`, not a logical DB on the shared one — see `.env.example`'s Redis section for why), because its Redis connection also gates rate limiting, fail2ban, distributed locks, ACME tokens, OAuth codes, and greylisting on the SMTP/IMAP hot path — Stalwart's docs don't say whether those fail open or fail closed when Redis is unreachable, so "degrades rather than destroys" is confirmed only for the cluster coordinator's best-effort pub/sub (`x:Coordinator/set`), not for that broader dependency; don't repeat the stronger claim without that caveat. The opt-in fix mirrors Postgres HA but is simpler: `stalwart-redis/` (role toggle via `STALWART_REDIS_ROLE`, `--replicaof` at container start — no `pg_basebackup`-style manual clone, Redis does its own full/partial resync) + `stalwart-redis-router/` (nginx-stream, takes the `STALWART_REDIS_MAGIC_NAME` identity, forwards to `STALWART_REDIS_PRIMARY_MAGIC_NAME`) + `bootstrap.sh stalwart-redis-promote` (`REPLICAOF NO ONE` — no `pg-rejoin` equivalent needed either; rejoining is just flipping role + primary pointer and restarting). The `tag:stalwart-redis → tag:stalwart-redis:6379` self-grant covers both standby→primary replication and router→primary, same pattern as the Postgres self-grant. When touching Garage clustering, keep the invariant that peers are addressed by stable MagicDNS name (`rpc_public_addr`/`bootstrap_peers`), never by ephemeral tailnet IP. Apps reach the S3 API at `${GARAGE_S3_ENDPOINT_NAME}.${TS_TAILNET}:3900` (defaults to the single node); for a cluster, HA is optional via a **layer-4 (TCP)** S3 load-balancer on the reverse-proxy host (`nginx/sites-available/garage-s3.conf` or the `caddy/Caddyfile` layer4 block) — it must stay L4, because S3 SigV4 signs the Host header and path and an HTTP proxy that rewrites either breaks the signature. The matching ACL grants are `tag:reverse-proxy → tag:garage:3900` and `<app tags> → tag:reverse-proxy:3900`. **Stalwart** also has an opt-in HA path, and it's the cheapest of the three because Stalwart holds no state of its own — a second node (`STALWART_CLUSTER_ENABLE=true`, per-host `STALWART_MAGIC_NAME` doubling as its cluster node-id, everything else copied identically from node 1) just points at the same shared Postgres (data/config/FTS) and Garage (blobs) this stack already runs, plus Stalwart's own Redis (now optionally HA — see above) for best-effort pub/sub coordination (`x:Coordinator/set` @type `Default`, reusing the in-memory-store connection — this specific piece is documented as degrading to reduced responsiveness, not incorrectness, if Redis is unreachable; the rest of what that connection backs is not). HA here means a **second independent public mail hostname + a second `MX` record** — inbound SMTP gets real failover for free via MX retry semantics; IMAP/JMAP does not (single fixed client hostname), so document that asymmetry rather than pretend it's solved. Node 2 should skip the `:443` SNI/web block in its L4 edge (MTA-STS/autoconfig stay node-1-only) and get its own non-wildcard ACME cert, avoiding any collision with node 1's wildcard.
- **Backup strategy for `pg-data` and similar volumes**: not yet templated. Operator's responsibility for now.
- **Cert management for host Nginx**: assumed to be the operator's existing process (Let's Encrypt via certbot or similar). Not in scope for this repo.
- **Object storage for media**: PeerTube has S3 templated (opt-in via `PEERTUBE_OBJECT_STORAGE_*` env vars in `.env.example`). Pixelfed and Funkwhale are still local-volume only — retrofit them with the same `<APP>_OBJECT_STORAGE_*` pattern when an operator needs it.

If a user request touches one of these, say so and ask before implementing.
