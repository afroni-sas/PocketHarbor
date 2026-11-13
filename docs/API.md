# PocketHarbor HTTP API

Everything the dashboard does goes through this API, so a script, a CI job or an AI agent can do it too. This page lists every endpoint, with what it takes and what it returns.

- **Base URL:** the dashboard's address followed by `/api`, for example `http://192.168.1.20:8080/api` on the local network, or `https://pocketharbor-xxxx.you.workers.dev/api` once Cloudflare is connected.
- **Format:** requests and responses are JSON (`Content-Type: application/json`). The exceptions are log endpoints, which return plain text or JSON lines, and the terminal, which is a WebSocket.
- **Errors:** an error is a non-2xx status with `{"error": "what went wrong, in plain words"}`.
- **Times:** times are Unix seconds, except log lines, which are in milliseconds where noted.

The [LLM skill](../skills/pocketharbor/SKILL.md) teaches an agent to use this API safely.

## Contents

- [Authentication](#authentication)
- [Names and identifiers](#names-and-identifiers)
- [Instance](#instance)
- [Accounts, sessions and tokens](#accounts-sessions-and-tokens)
- [Projects and environments](#projects-and-environments)
- [Services](#services)
- [Deployments](#deployments)
- [Variables](#variables)
- [Logs, metrics and activity](#logs-metrics-and-activity)
- [Domains](#domains)
- [Volumes and backups](#volumes-and-backups)
- [Databases (data view)](#databases-data-view)
- [Terminal (WebSocket)](#terminal-websocket)
- [Templates](#templates)
- [Settings](#settings)
- [Cloudflare (public access)](#cloudflare-public-access)
- [Quick tunnel and hand-made tunnel](#quick-tunnel-and-hand-made-tunnel)
- [GitHub](#github)
- [Private registries](#private-registries)
- [Alerts](#alerts)
- [Status codes](#status-codes)
- [Recipes](#recipes)

## Authentication

There are two ways to authenticate.

**API tokens (scripts and agents).** Create one in the dashboard (Account › API tokens), with `pharbor token create NAME`, or with `POST /api/tokens`. Then send it with every request:

```http
Authorization: Bearer ph_...
```

The token is shown once; PocketHarbor keeps only a hash of it. A token can do everything a signed-in user can, except the `/api/me/...` account actions. Remove it with `DELETE /api/tokens/:id` or `pharbor token rm ID`.

**Sessions (the dashboard).** `POST /api/login` sets an HttpOnly cookie. Requests that change something must come from the dashboard's own origin (the `Origin` header is checked), so cookies are not meant for scripts.

```bash
export PHARBOR_URL=http://192.168.1.20:8080
export PHARBOR_TOKEN=ph_xxxxxxxxxxxxxxxxxxxxxxxx
curl -s -H "Authorization: Bearer $PHARBOR_TOKEN" "$PHARBOR_URL/api/projects"
```

## Names and identifiers

- **Project, environment and service names:** `a-z`, `0-9` and `-`. The defaults are project `default` and environment `production`.
- **Service id:** `project.environment.name`, for example `shop.production.api`. Every `/api/services/:id/...` path uses it.
- **Private name:** `project-name` (for example `shop-api`). Other services of the same environment reach the service at this name, and `${{ api.PHARBOR_PRIVATE_DOMAIN }}` gives it.

## Instance

| Method | Path | Auth | What it does |
|---|---|---|---|
| GET | `/api/status` | none | `{"setup_needed": bool, "version": "0.2.0"}` |
| POST | `/api/setup` | none | Creates the first account: `{"email", "password"}` (8 characters at least). 409 once an account exists. |
| POST | `/api/login` | none | `{"email", "password", "code"?}` → the user, and a session cookie. With two-factor authentication on and no `code`: 401 `{"code_required": true}`. Repeated failures from one address: 429. |
| POST | `/api/logout` | cookie | Ends the session. |

`/__pharbor/check` (outside `/api`) answers the instance's check id. The domain check uses it to tell that a name really reaches this phone.

## Accounts, sessions and tokens

| Method | Path | Body | Returns |
|---|---|---|---|
| GET | `/api/me` | | `{id, email, totp_enabled, created_at}`; with a token: `{token: "name"}` |
| POST | `/api/me/password` | `{current, new}` | Changes the password and ends the other sessions |
| POST | `/api/me/2fa/setup` | | `{secret, uri}` to scan in an authenticator app |
| POST | `/api/me/2fa/enable` | `{code}` | Turns two-factor authentication on |
| POST | `/api/me/2fa/disable` | `{code}` | Turns it off |
| GET | `/api/users` | | `[{id, email, totp_enabled, created_at}]` |
| POST | `/api/users` | `{email, password}` | Adds a member (201) |
| DELETE | `/api/users/:id` | | Removes a member |
| GET | `/api/tokens` | | `[{id, name, hint, created_at}]` |
| POST | `/api/tokens` | `{name}` | `{id, name, token}`: the token, shown this once (201) |
| DELETE | `/api/tokens/:id` | | Revokes it |

## Projects and environments

| Method | Path | Body / query | Returns |
|---|---|---|---|
| GET | `/api/projects` | | `[{name, environments: [..], created_at, services, online}]` |
| POST | `/api/projects` | `{name}` | The project (201); it starts with `production` |
| GET | `/api/projects/:name` | | `{name, environments, created_at}` |
| DELETE | `/api/projects/:name` | | Removes the project, its services, their containers and volumes |
| POST | `/api/projects/:name/environments` | `{name, from?}` | A new environment, a copy of `from` (default `production`): same services and variables, not deployed |
| DELETE | `/api/projects/:name/environments/:env` | | Removes the environment and its services |
| GET | `/api/projects/:name/environments/:env/edges` | | `[{from, to}]`: which service refers to which, through `${{ svc.VAR }}` |
| GET | `/api/projects/:name/environments/:env/activity` | | The latest deployments of the environment, newest first (50 at most) |
| GET | `/api/projects/:name/environments/:env/logs` | `tail` (300), `q`, `service` | Every service's output, merged by time: `[{t (ms), service, stream, text}]` |
| GET, PUT, PATCH | `/api/projects/:name/environments/:env/variables` | | The environment's **shared** variables, as for a service (see [Variables](#variables)) |
| POST | `/api/projects/:name/environments/:env/variables/raw` | `{text, replace}` | Shared variables from `.env` text |

## Services

### List, read, create

| Method | Path | Body / query | Returns |
|---|---|---|---|
| GET | `/api/services` | `project`, `environment` (optional filters) | `[Service]` |
| GET | `/api/services/:id` | | `Service` |
| POST | `/api/services` | `ServiceInput` with `name` | `Service` (201); `"deploy": true` also starts its first deployment |
| PATCH | `/api/services/:id` | `ServiceInput` (only the fields to change) | `Service`; `"deploy": true` also deploys |
| DELETE | `/api/services/:id` | | Stops and removes it, its containers and volumes; its names leave Cloudflare, and its repository's webhook goes when nothing else uses it |

**ServiceInput** (all fields optional except `name` on creation):

| Field | Type | Meaning |
|---|---|---|
| `project`, `environment`, `name` | string | Where it lives, on creation (defaults `default`, `production`) |
| `image` | string | A Docker image (`nginx:alpine`, `ghcr.io/you/app:1.2`). Setting it clears `repo`. |
| `repo` | string | `owner/name` or a GitHub URL: built from source. Setting it clears `image`. |
| `branch` | string | Branch to build and watch (default `main`) |
| `root_dir` | string | Folder of the repository to build (monorepos) |
| `auto_deploy` | bool | Deploy on each push to `branch` (default true) |
| `build_command`, `start_command`, `pre_deploy` | string | Override the detected build, the image's command, and a command run in the new version before it takes traffic (migrations) |
| `port` | int | The port the app listens on; 0 means detect it (`$PORT`, then the first port opened) |
| `domains` | [string] | The custom domains (generated ones included) |
| `env` | ["KEY=VALUE"] | Variables to set on creation |
| `volumes` | [{name, mount}] | Data that survives deployments, e.g. `{"name": "data", "mount": "/var/lib/data"}` |
| `backup_schedule` | string | `daily`, `weekly` or `""` (keeps the 7 latest) |
| `cron` | string | `MIN HOUR DAY MONTH WEEKDAY` (UTC): run on a schedule instead of always |
| `health_path` | string | HTTP path that must answer 2xx or 3xx before traffic moves (default: the port accepting connections) |
| `health_timeout_s` | int | Time allowed to become healthy (default 180) |
| `restart_policy` | string | `on-failure` (default), `always` or `never` |
| `restart_retries` | int | Tries for `on-failure` (default 10) |
| `sleep_after_s` | int | Stop after this many idle seconds; the next request starts it again (0: never) |
| `x`, `y` | int | Position of the card on the canvas |
| `deploy` | bool | Deploy right after saving |

**Service** (what reading returns): the fields above, plus:

- `id` and `status`. Status is one of:
  - `running`, `restarting`, `exited` (crashed), `asleep`, `scheduled` (cron);
  - `completed`: a task that ran and exited with code 0;
  - `failed`: never came up;
  - `new`: never deployed.
- `latest`: the newest deployment, `{number, status, trigger, commit, message, image, created_at}`.
- `deployment` (the current deployment's number) and `deployed_at`.
- `hostnames`: every name it answers to, with the base domain's.
- `generated_domain`.
- `deploy_on_push`: `{repo, status, detail}`, where status is `ready`, `needs_cloudflare`, `needs_token`, `denied`, `failed` or `pending`.
- `last_run`, for cron services.
- `update`: what the last check of its image found, when something is newer (see `GET /api/services/:id/update`).

```bash
# An nginx service, deployed at once
curl -s -X POST -H "Authorization: Bearer $PHARBOR_TOKEN" -H 'Content-Type: application/json' \
  -d '{"project":"shop","name":"web","image":"nginx:alpine","port":80,"deploy":true}' \
  "$PHARBOR_URL/api/services"
```

### Actions

| Method | Path | Body | Returns |
|---|---|---|---|
| POST | `/api/services/:id/deploy` | `{}` | 202: a new deployment starts (pulls the image again, or builds the branch's latest commit) |
| POST | `/api/services/:id/redeploy` | `{number?}` | 202 `{from}`: the image of deployment `number` (default: the current one) with **today's** variables |
| POST | `/api/services/:id/rollback` | `{number}` | 202 `{from}`: deployment `number` again, with **its own** variables |
| POST | `/api/services/:id/restart` | `{}` | Restarts the running container |
| POST | `/api/services/:id/run` | `{}` | 202: runs a cron service now |
| GET | `/api/services/:id/update` | `refresh=1` to ask the registry again | `{image, checked_at, build, newer, major, error}`. `build` means a newer build of the same tag exists, so deploying pulls it. `newer` is a later version in the same line (e.g. `mongo:9.1` for `mongo:9.0`). `major` is a new major version (e.g. `postgres:18-alpine` for `postgres:16-alpine`). Answers are kept for six hours. |
| GET | `/api/services/:id/cron-log` | | The last runs' output (text) |

## Deployments

Deploying is asynchronous: a deploy call answers 202 at once. Follow the work with:

| Method | Path | Returns |
|---|---|---|
| GET | `/api/services/:id/deployments` | `[{number, status, image, trigger, commit, message, container, reason, created_at, finished_at}]`, newest first |
| GET | `/api/services/:id/deployments/:n/log` | That deployment's log: build, start, health check (text) |
| GET | `/api/services/:id/deployments/:n/variables` | The variables it ran with (a snapshot, for rollbacks) |

Deployment statuses:

- `deploying`: building or starting.
- `active`: serving traffic.
- `completed`: a task that ran and exited 0.
- `failed`: `reason` says why. The previous version keeps running.
- `removed`: replaced by a newer one.

`trigger` is `api`, `cli`, `webhook` (a push), `redeploy` or `rollback`.

A deployment goes live only once the new container opens its port and passes its health check within `health_timeout_s`. Traffic then moves, and the old container drains and stops. A failed deployment never interrupts the running one.

## Variables

Values are encrypted on disk. They can refer to other values:

- `${{ KEY }}`: another variable of the same service.
- `${{ shared.KEY }}`: a shared variable of the environment.
- `${{ svc.KEY }}`: a variable of service `svc`, including its built-ins.

**Built-in variables:**
- `PHARBOR_SERVICE_NAME`, `PHARBOR_PROJECT_NAME`, `PHARBOR_ENVIRONMENT_NAME`;
- `PHARBOR_PRIVATE_DOMAIN`, `PHARBOR_PUBLIC_DOMAIN`, `PHARBOR_TCP_PORT`;
- `PORT`, unless the service sets it.

| Method | Path | Body / query | Returns |
|---|---|---|---|
| GET | `/api/services/:id/variables` | | `[{name, value}]` as written, references unresolved |
| GET | `/api/services/:id/variables?resolved=1` | | `{variables: [{name, value}], warnings: [..]}`: final values, and the references that resolve to nothing |
| PUT | `/api/services/:id/variables` | `{variables: [{name, value}]}` | Replaces them all |
| PATCH | `/api/services/:id/variables` | `{set: [{name, value}], unset: [names]}` | Changes some |
| POST | `/api/services/:id/variables/raw` | `{text, replace}` | From `.env` text (`KEY=value` lines, `#` comments, quotes). `replace: true` removes the ones left out. |

Variables apply at the next deployment. Values are secrets: read `?resolved=1` only when the final value is needed.

## Logs, metrics and activity

| Method | Path | Query | Returns |
|---|---|---|---|
| GET | `/api/services/:id/logs` | `tail` (500) | The running container's output (text) |
| GET | `/api/services/:id/http-logs` | `tail` (500) | One JSON line per request through the proxy (`application/x-ndjson`): `{ts, method, host, path, client, status, ms, in, out}`. Query strings are never logged. |
| GET | `/api/services/:id/metrics` | `range` in seconds (3600) | `{interval, step, from, to, points: [{t, cpu, mem, disk, req, err, rx, tx, p95}]}`: CPU in % of a core, memory and disk in bytes, requests and 5xx per step, bytes in and out, p95 response time in ms |
| GET | `/api/projects/:p/environments/:e/logs` | `tail`, `q`, `service` | Every service's lines, merged by time |
| GET | `/api/projects/:p/environments/:e/activity` | | The latest deployments of every service |

## Domains

| Method | Path | Body / query | Returns |
|---|---|---|---|
| GET | `/api/services/:id/domains` | `check=1` to test each name for real | See below |
| POST | `/api/services/:id/generate-domain` | `{}` | `{domain}`: the service's one generated name, on workers.dev or in the zone chosen for generated names (needs Cloudflare). 409 if it has one. |
| PUT | `/api/services/:id/generate-domain` | `{label, zone}` | `{domain}`: renames it: `label` is `a-z0-9-`, `zone` one of the account's zones or `""` for workers.dev |
| GET | `/api/domain-check` | `name`, `service` | `{valid, owner, managed, saas, zone, certificate}`: whether a name is free, and how it would be served |

Custom domains are the service's `domains` field. Add or remove one with `PATCH /api/services/:id {"domains": [...]}`, sending the whole list. With Cloudflare connected, PocketHarbor writes or removes the DNS record during that call.

The domains view returns:

- `managed`: Cloudflare is connected.
- `relay_ready`, `relay_suffix`, `generates_in`, `zones`, `saas_zone`.
- `setup`: `tunnel`, `lan`…
- `origin`, `proxy_port`, `lan`.
- `domains`: one entry per name, with:
  - `domain`, and `kind`: `generated`, `custom` or `base`;
  - `record`: `ready`, `relay`, `foreign`, `conflict`, `no_zone` or `failed`;
  - `records`: the DNS records to add, `[{type, name, value}]`;
  - with `check=1`, the real check: `status` (`active`, `elsewhere`, `cloudflare`, `no_answer`…), `via` and `detail`.

## Volumes and backups

| Method | Path | Body | Returns |
|---|---|---|---|
| GET | `/api/services/:id/volumes` | | `[{name, mount, size}]` |
| GET | `/api/services/:id/backups` | | Every backup of its volumes |
| POST | `/api/services/:id/backups` | `{volume?, live?}` | Backs up one or all volumes (201). `live: true` does not stop the service. |
| POST | `/api/services/:id/backups/:volume/:backup/restore` | `{}` | Restores it: the service stops, the volume is replaced, the service starts |
| DELETE | `/api/services/:id/backups/:volume/:backup` | | Deletes the backup |

## Databases (data view)

For services running PostgreSQL, MySQL, MariaDB, Redis or MongoDB:

| Method | Path | Body | Returns |
|---|---|---|---|
| GET | `/api/services/:id/data` | | `{kind, items: [..], error}`: tables, keys or collections |
| POST | `/api/services/:id/data/query` | `{query}` | The output of the database's own client for that query (SQL, a Redis command, a Mongo shell expression) |

## Terminal (WebSocket)

`GET /api/services/:id/terminal` upgrades to a WebSocket that is a shell in the running container (`ws://` or `wss://`). It opens from the dashboard's origin, or with a token.

- **To the shell:** text frames. `i` followed by input (`"ils\r"`), or `r` followed by `cols,rows` to resize (`"r120,40"`).
- **From the shell:** binary frames, the terminal's output.

## Templates

| Method | Path | Body | Returns |
|---|---|---|---|
| GET | `/api/templates` | | `[{id, name, category, description, image, port, connect}]`: `postgres`, `mysql`, `mariadb`, `redis`, `mongo`, `bucket` (S3), `nats`. The image is the one this device can run: MongoDB falls back to 4.4 on processors without ARMv8.2 or AVX. |
| POST | `/api/templates/:id` | `{project, environment, name?, x?, y?}` | Creates and deploys it, with its volume, a generated password and the variables others refer to (`connect` names the main one, e.g. `DATABASE_URL`) |

## Settings

| Method | Path | Body | Returns |
|---|---|---|---|
| GET | `/api/settings` | | `{base_domain, panel_domain, proxy_port, panel_port, default_service, generated_zone, ...}`. Secrets show only as `"set"`. |
| PATCH | `/api/settings` | `{base_domain?, panel_domain?}` | `base_domain` gives every service `NAME.DOMAIN`; `panel_domain` is where the dashboard answers |

## Cloudflare (public access)

| Method | Path | Body | Returns |
|---|---|---|---|
| GET | `/api/cloudflare` | | `{connected, account, tunnel_id, origin, permissions, create_url, connector, saas_zone, generated_zone, relay: {ready, dashboard, error}, state}`. `create_url` is Cloudflare's token form with the permissions filled in; `state` holds the zones, every public name's outcome and the last error: a sync's, or cloudflared's failure to start, which goes once it runs. |
| PUT | `/api/cloudflare` | `{token, account?}` | Connects: verifies the token, creates the tunnel, deploys the relay, writes the records, starts cloudflared. `account` is needed only for a token an account owns (`cfat_`). |
| PATCH | `/api/cloudflare` | `{generated_zone?, saas_zone?}` | Where generated names go (`""` is workers.dev), and the zone that serves domains kept elsewhere |
| POST | `/api/cloudflare/sync` | `{}` | Puts tunnel routes, DNS records, Workers and webhooks in step now |
| POST | `/api/cloudflare/start` | `{}` | Starts the tunnel connector again |
| DELETE | `/api/cloudflare` | | Disconnects: removes the records, Workers and webhooks PocketHarbor made, and stops the tunnel |

## Quick tunnel and hand-made tunnel

| Method | Path | Body | Returns |
|---|---|---|---|
| GET | `/api/tunnel` | | `{running, status, url, default_service}` |
| POST | `/api/tunnel/quick` | `{service}` | A temporary `trycloudflare.com` address for one service (refused while Cloudflare is connected) |
| POST | `/api/tunnel/named` | `{token}` | Runs a tunnel made by hand in Cloudflare |
| DELETE | `/api/tunnel` | | Stops it |

## GitHub

| Method | Path | Body | Returns |
|---|---|---|---|
| GET | `/api/github` | | `{has_token, token_url, webhook_path, webhook_secret, cloudflare, target, hooks: [{repo, hook_id, status, detail}]}`. `token_url` is GitHub's token form with its permissions filled in. |
| PUT | `/api/github` | `{token}` | Saves the token (`""` removes it) and sets up the webhooks |
| GET | `/api/github/repos` | | `{has_token, repos: [{full_name, private, default_branch, description, pushed_at}], error}` |
| POST | `/api/github/sync` | `{}` | Sets up the push webhooks now: `{hooks}` |
| POST | `/__pharbor/webhooks/github` | GitHub's push event | Where GitHub sends pushes, signed with `webhook_secret` (`X-Hub-Signature-256`) |

## Private registries

| Method | Path | Body | Returns |
|---|---|---|---|
| GET | `/api/registries` | | The registries signed in to |
| POST | `/api/registries` | `{host, username, password}` | Signs in (`ghcr.io`, `docker.io`, …) |
| DELETE | `/api/registries/:host` | | Signs out |

## Alerts

| Method | Path | Body | Returns |
|---|---|---|---|
| GET | `/api/alerts` | | `{channels, thresholds, events, defaults}` |
| POST | `/api/alerts/channels` | `{name, kind, target, events?, projects?, signing?, email_from?, email_to?}` | Adds a channel (201) |
| PATCH | `/api/alerts/channels/:id` | same fields | Changes it |
| DELETE | `/api/alerts/channels/:id` | | Removes it |
| POST | `/api/alerts/channels/:id/test` | `{}` | Sends a test message |
| PUT | `/api/alerts/thresholds` | `{cpu_percent, memory_mb, disk_mb}` | Alert when a service stays above them for five minutes (0: off) |
| GET | `/api/alerts/log` | | The latest alerts sent |

Channels:

| `kind` | `target` |
|---|---|
| `discord` | Webhook URL |
| `slack` | Incoming webhook URL |
| `webhook` | Any URL. Requests are signed with `signing` in `X-PocketHarbor-Signature`. |
| `email` | A Resend API key, with `email_from` and `email_to` |

Events: `deploy_failed`, `deploy_succeeded`, `crashed`, `cron_failed`, `backup_failed`, `high_cpu`, `high_memory`, `high_disk`.

## Status codes

| Code | Meaning |
|---|---|
| 200, 201 | Done |
| 202 | Started, for deployments, runs and redeploys: follow with `/deployments` |
| 400 | The request is wrong: `error` says which field |
| 401 | No valid token or session |
| 403 | Refused: an origin check, or Cloudflare or GitHub refusing the token |
| 404 | No such project, service, deployment or route |
| 409 | Conflict: the name is taken, the service is not deployed, Cloudflare is not connected… |
| 429 | Too many sign-in attempts |
| 502 | Cloudflare or GitHub failed, or could not be reached |

## Recipes

Deploy a new image and wait for the result:

```bash
H="Authorization: Bearer $PHARBOR_TOKEN"; S="$PHARBOR_URL/api/services/shop.production.api"
curl -s -X PATCH -H "$H" -H 'Content-Type: application/json' -d '{"image":"ghcr.io/me/api:1.4","deploy":true}' "$S"
while :; do
  d=$(curl -s -H "$H" "$S/deployments" | jq -r '.[0] | "\(.number) \(.status)"')
  case "$d" in *deploying) sleep 3 ;; *) break ;; esac
done
echo "$d"; curl -s -H "$H" "$S/deployments/${d%% *}/log" | tail -20
```

Set a variable that points at the database, then redeploy:

```bash
curl -s -X PATCH -H "$H" -H 'Content-Type: application/json' \
  -d '{"set":[{"name":"DATABASE_URL","value":"${{ postgres.DATABASE_URL }}"}]}' "$S/variables"
curl -s -X POST -H "$H" -H 'Content-Type: application/json' -d '{}' "$S/deploy"
```

Find what failed in the last hour, across the environment:

```bash
curl -s -H "$H" "$PHARBOR_URL/api/projects/shop/environments/production/logs?tail=2000&q=error"
```

Add a PostgreSQL database:

```bash
curl -s -X POST -H "$H" -H 'Content-Type: application/json' -d '{"project":"shop","environment":"production"}' "$PHARBOR_URL/api/templates/postgres"
```
