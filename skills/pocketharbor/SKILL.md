---
name: pocketharbor
description: Operate a PocketHarbor instance (a self-hosted platform that deploys and serves apps from an Android phone) through its HTTP API. Lists projects and services; deploys Docker images or GitHub repositories and follows deployments; reads logs, HTTP logs and metrics; manages variables, domains, volumes and backups, databases, Cloudflare public access, GitHub deploy-on-push and alerts. Use when the user mentions PocketHarbor, pharbor, a PocketHarbor dashboard URL, or deploying or debugging something running on their phone.
---

# PocketHarbor

PocketHarbor runs containers on an Android phone: projects hold environments, environments hold services, and each deploy creates a numbered deployment. The full API reference is in [references/api.md](references/api.md). Read the section you need before calling an endpoint you have not used yet.

## Connect

You need two things from the user:

- `PHARBOR_URL`: the dashboard's address, for example `http://192.168.1.20:8080` or `https://pocketharbor-xxxx.name.workers.dev`.
- `PHARBOR_TOKEN`: an API token starting with `ph_`. The user creates it in the dashboard (Account › API tokens), or on the phone with `pharbor token create agent`.

Never ask for the account password, and never print the token back.

Check the connection first:

```bash
curl -s "$PHARBOR_URL/api/status"                                  # {"setup_needed":false,"version":"..."}
curl -s -H "Authorization: Bearer $PHARBOR_TOKEN" "$PHARBOR_URL/api/projects"
```

`scripts/ph` wraps curl: `ph GET /services`, `ph PATCH /services/ID '{"port":80}'`, and `ph wait ID`, which waits for a deployment and prints its log if it failed.

## How it fits together

- **Service id:** `project.environment.name`, for example `shop.production.api`. Every service call uses `/api/services/:id`.
- **Deploying is asynchronous.** A deploy answers 202. Poll `GET /api/services/:id/deployments` until the newest one is no longer `deploying`:
  - `active`: it serves traffic.
  - `completed`: a task that ran and exited 0.
  - `failed`: read `reason` and `GET .../deployments/:n/log`.

  A failed deploy never stops the version already running.
- **Variables:**
  - They apply at the next deploy. Change them, then `POST .../deploy`.
  - References: `${{ svc.KEY }}` for another service, `${{ shared.KEY }}` for the environment's shared variables, `${{ svc.PHARBOR_PRIVATE_DOMAIN }}` for the service's private hostname.
- **Service status** (`GET /api/services/:id`, field `status`):
  - `running`, `completed`, `asleep`, `scheduled`: normal states.
  - `exited`: it crashed.
  - `failed`: it never came up.
  - `new`: it was never deployed.

## Common tasks

Deploy an image, or a new version of it:

```bash
ph POST /services '{"project":"shop","name":"web","image":"nginx:alpine","port":80,"deploy":true}'
ph PATCH /services/shop.production.web '{"image":"nginx:1.27-alpine","deploy":true}'
ph wait shop.production.web
```

Build from GitHub, which deploys on every push once Cloudflare and a GitHub token are set:

```bash
ph POST /services '{"project":"shop","name":"api","repo":"owner/api","branch":"main","deploy":true}'
```

Add a database, then point a service at it:

```bash
ph POST /templates/postgres '{"project":"shop","environment":"production"}'
ph PATCH /services/shop.production.api/variables '{"set":[{"name":"DATABASE_URL","value":"${{ postgres.DATABASE_URL }}"}]}'
ph POST /services/shop.production.api/deploy
```

Debug a service that does not work:

1. `ph GET /services/ID` gives `status` and `latest`.
2. `ph GET /services/ID/deployments`, then `ph GET /services/ID/deployments/N/log`: why a deploy failed.
3. `ph GET "/services/ID/logs?tail=200"`: what the app prints now.
4. `ph GET "/services/ID/http-logs?tail=50"`: the requests and their status codes.
5. `ph GET "/services/ID/variables?resolved=1"`: unresolved references show in `warnings`. Do not print the values.
6. `ph GET "/services/ID/metrics?range=3600"`: CPU, memory, disk, requests, 5xx and p95.

Typical causes:

- The wrong `port`: set it, or let it be detected with `0`.
- A `health_path` that never answers 2xx.
- A missing variable.
- A dependency not running.
- A private image without registry credentials (`POST /registries`).

Make a service public:

- **With Cloudflare connected** (`GET /cloudflare` shows `connected: true`):
  - `POST /services/ID/generate-domain` gives a workers.dev or zone address;
  - a custom domain is added by sending the whole list: `PATCH /services/ID {"domains":[...]}`.
- **Without Cloudflare:** ask the user to connect it in Settings › Public access. The token is created on Cloudflare's site, never by you.

Search the logs of a whole environment:

```bash
ph GET "/projects/shop/environments/production/logs?tail=2000&q=timeout"
```

## Rules

- **Confirm with the user before anything destructive or hard to undo.** That covers:
  - deleting a project, environment, service, volume, backup or token;
  - restoring a backup, which replaces the volume's data;
  - `rollback`;
  - disconnecting Cloudflare;
  - changing `domains`, `panel_domain` or `base_domain`, which changes what is public;
  - removing members.
- **Variable values, tokens, webhook secrets and database contents are secrets.** Use `?resolved=1` only when a value is needed, and never echo secrets in replies or commits.
- **Database queries** (`POST /services/ID/data/query`) run against real data. Read freely; write only when the user asks.
- **Changes happen on a phone** with limited CPU, memory and storage. Do not start many deploys at once, and do not leave a log follow loop running.
- **Act through the API.** If a call fails with 409 or 403, report the `error` message rather than trying another route around it.

## On the phone itself

With a shell on the phone (Termux, `adb shell`), the `pharbor` command does the same as the API: `pharbor ls`, `pharbor deploy NAME --image IMAGE`, `pharbor logs NAME -f`, `pharbor var set NAME KEY=VALUE`, `pharbor deployments NAME`, `pharbor rollback NAME N`. `pharbor --help` lists everything.
