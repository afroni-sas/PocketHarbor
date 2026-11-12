# PocketHarbor

Deploy and serve applications from an Android phone, without root, the way
Railway does it in the cloud: projects of services on a canvas, deployments
from GitHub or Docker images, databases in one click, variables, logs,
metrics, custom domains. PocketHarbor runs on top of the
[PocketDock](https://github.com/afroni-sas/PocketDock) engine, which the
installer installs with it.

## What you need

| Required | |
|---|---|
| **A 64-bit device** | An Android phone or tablet with a 64-bit ARM processor (`arm64-v8a`, nearly every recent phone), or an `x86_64` device or emulator. Any 64-bit Linux machine works too. No root. |
| **Termux** | The terminal app the installer runs in. Install it from [F-Droid](https://f-droid.org/packages/com.termux/) or its [GitHub releases](https://github.com/termux/termux-app/releases), not from the Play Store, whose version is outdated. Then `pkg install curl`. Without Termux, a computer with `adb` can install it too (see below). |
| **Storage** | 200 MB at least; 1 GB or more is better, since every image of a service is stored on the phone. |
| **A network connection** | To pull images and reach GitHub. Phones on the same Wi-Fi reach the dashboard at the phone's address. |

| Optional | What it gives | How to get it |
|---|---|---|
| **Termux:Boot** | PocketHarbor and its services start again when the phone restarts. | Install [Termux:Boot](https://f-droid.org/packages/com.termux.boot/) from the same place as Termux, and open it once. The installer then sets it up. |
| **A Cloudflare account** | Your services on the internet, over HTTPS, with no port to open, even behind a carrier's network. Without a domain, they get `workers.dev` addresses. | A free account at [cloudflare.com](https://dash.cloudflare.com/sign-up), then one click in Settings › Public access: see [Public access](#public-access). |
| **A domain name** | Addresses like `app.example.com`, with no request limit. | Any registrar; [Cloudflare Registrar](https://www.cloudflare.com/products/registrar/) sells them at cost. Add the domain to your Cloudflare account, and PocketHarbor writes its records. A domain kept elsewhere works too, with two records: see [Custom domains](#custom-domains). |
| **A GitHub token** | Builds of private repositories, your repositories in the Add dialog, and a deployment on every push. | In Settings › GitHub, **Create the token on GitHub** opens GitHub's form with its permissions filled in (*Contents: Read*, *Webhooks: Read and write*): choose the repositories, generate it and paste it back. With Cloudflare connected, PocketHarbor then adds each repository's push webhook itself. |
| **Alerts** | Messages when a deployment fails, a service crashes or a cron run fails. | A [Discord](https://support.discord.com/hc/en-us/articles/228383668) or [Slack](https://api.slack.com/messaging/webhooks) webhook address, or a [Resend](https://resend.com) API key for email. Settings › Alerts. |
| **Registry credentials** | Images from private registries (GHCR, Docker Hub, others). | A token of the registry; Settings › Registries, or `pharbor registry login HOST -u USER`. |

## Install

In Termux, or on Linux:

```sh
curl -fsSL https://github.com/afroni-sas/PocketHarbor/releases/latest/download/install.sh | sh
```

It asks a few questions, each with a default:

- where to keep the data;
- the port: one already in use is detected, and the next free one is offered;
- the owner account;
- the domains;
- Cloudflare;
- whether to start at boot.

Then it installs `pharbor` and `pdock`, checks their SHA-256 sums, starts everything and checks that the dashboard answers.

`--yes` asks nothing: the defaults, the options and the `PHARBOR_*` variables decide. For instance:

```sh
sh install.sh --yes --email you@example.com --cloudflare-token TOKEN
```

`sh install.sh --help` lists every option; pass them after `sh -s --` when the script comes from curl. Run the installer again to update: the data, the settings and the port stay.

From a computer with adb, push the release files and run the installer with `--from`; the release notes show how. A shell started by adb cannot start PocketHarbor at boot; Termux can.

## Uninstall

```sh
curl -fsSL https://github.com/afroni-sas/PocketHarbor/releases/latest/download/uninstall.sh | sh
```

It stops PocketHarbor and its services, then removes:

- the start at boot;
- the lines the installer added to your shell;
- `pharbor` and `pdock`.

**The data stays.** Installing again brings the projects back, with their services running. `--purge` deletes the data too (projects, volumes, backups, accounts), and `--purge-engine` deletes the images. Without `--yes` it asks before each step.

## Quick start

Open `http://PHONE-ADDRESS:8080/` from a browser on the same network. The first visit creates the owner account, unless the installer already did.

Then create a project. In it, **+ Add** (or `Ctrl K`) deploys any of these:

- a GitHub repository;
- a Docker image;
- a database: PostgreSQL, MySQL, MariaDB, Redis or MongoDB;
- a template;
- a bucket.

The same from the command line:

```sh
pharbor deploy web --image nginx:alpine --port 80 --domain web.example.com
pharbor tunnel quick web     # a temporary public https:// address, no account needed
```

## Public access

In **Settings › Public access**, **Create the token on Cloudflare** opens Cloudflare's form with every permission filled in. Click *Continue to summary*, then *Create Token*, and paste the token back: that is all. The installer offers the same link, and `pharbor cloudflare connect` reads the token on stdin.

The token gets these permissions, on all your accounts and zones:

| Permission | What PocketHarbor does with it |
|---|---|
| Account › Workers Scripts › Edit | Deploys its relay, which gives services `workers.dev` addresses without a domain. |
| Account › Cloudflare Tunnel › Edit | Creates its own tunnel and starts it on the phone. |
| Zone › DNS › Edit | Writes the record of each name, and removes it when the name goes. |
| Zone › Zone › Read | Finds which zone holds a name. |
| Zone › SSL and Certificates › Edit | Domains kept outside your account (optional). |

Once connected, the card shows the tunnel, the relay and your zones, with two choices:

- **Generated domains**: `workers.dev` (no domain needed, 100,000 requests a day on Cloudflare's free plan), or one of your zones (no limit).
- **Outside domains**: lets domains kept in another account or at another provider work with two DNS records, through one of your zones and Cloudflare for SaaS (the first 100 names are free).

PocketHarbor never touches a record it did not write, and **Disconnect** removes what it made.

Without a Cloudflare account, **Without a Cloudflare account** offers a temporary `trycloudflare.com` address for one service, or a tunnel you made by hand.

## Custom domains

In a service's **Settings › Networking**, as on Railway:

- **Generate Domain**: one address per service, named after the service's id, on `workers.dev` or in your zone. Its pencil changes the name and where it lives. Without Cloudflare, it gives a preview address on `trycloudflare.com`, and **Connect Cloudflare** leads to Settings › Public access.
- **Custom Domain**: a name in one of your zones (a subdomain and the zone to pick), or any other name, and the port your app listens on.

While a name is added, renamed or removed, its row says what PocketHarbor is doing (writing the DNS record, deploying or removing the Worker) until it is done.

Until a name works, its row says *Waiting for DNS update*, and **Show DNS records** shows the records it needs. With Cloudflare connected, a name in one of your zones needs nothing: PocketHarbor writes its record. A name kept elsewhere needs the two records shown, added where its DNS is.

The state is checked, not guessed: PocketHarbor asks public DNS, then sends a request through the name, and the domain shows as working only if the request reaches this phone. `pharbor domain check NAME` does the same from the command line.

Cloudflare's free certificate covers a zone and one level below it: `app.example.com` works, `x.app.example.com` does not, and the dashboard warns about it.

Without Cloudflare, a name works on your network only: point an `A` record at the phone's address, and open `http://NAME:8080`.

**A base domain** (Settings › General, or `pharbor domain base example.com`) gives every service `NAME.example.com` at once, through one wildcard record.

## Deploy on push

A service built from GitHub deploys on every push to its branch (Settings › Source › Auto Deploy). Once Cloudflare is connected and a GitHub token is saved, PocketHarbor adds a webhook to each repository a service deploys from, pointed at the dashboard's public name and signed with its secret, and removes it when no service uses the repository any more. Auto Deploy shows whether pushes reach the phone, and what is missing when they do not. Settings › GitHub lists the repositories and their state, and still shows the address and secret to set the webhook up by hand.

## Dashboard

The dashboard looks like Railway's:

- a canvas of the project's services, with their connections; **Auto Layout** arranges it by references (what uses what reads left to right, arrows go around the cards), and every move can be undone;
- per service: deployments and their logs, variables, metrics, a console, volumes and backups, cron runs, settings, in a panel whose edge drags to resize it (a double click puts it back);
- per project: observability, logs and settings.

It installs as an app (Add to Home screen) when opened over HTTPS, through a domain. Browsers only allow that on secure origins.

The interface lives in `web/` (Vite, Preact and signals). Its build is committed in `src/web/` and embedded in the binary, so `zig build` alone is enough. After changing it:

```sh
cd web && pnpm install --frozen-lockfile && pnpm build
```

## What it does

| | |
|---|---|
| **Routing** | One proxy serves every service by hostname, exact names and `*.example.com`. HTTP and WebSocket. |
| **Zero-downtime deploys** | The new version must open its port and pass its health check within the healthcheck timeout before traffic moves. The old one then drains and stops. A failed deployment leaves the running version alone. |
| **Restart policy** | On Failure (10 tries, as on Railway), Always or Never. |
| **Public access** | Through your Cloudflare account, set up by PocketHarbor: its tunnel for your domains, and its relay on Workers for `workers.dev` addresses. It works behind a carrier's NAT, with HTTPS, WebSockets and no open port. |
| **Idle sleep** | A service nobody uses stops; the next request starts it and waits for it. |
| **Metrics** | CPU, memory, volume size and HTTP traffic (requests, 5xx, response time, bytes) of every service, sampled every 30 seconds and kept for a week. |
| **Templates** | PostgreSQL, MySQL, MariaDB, Redis, MongoDB 4.4, MinIO (S3) and NATS in one click, with a volume, a generated password and the variables other services reference, like `${{ postgres.DATABASE_URL }}`. |
| **Data view** | The tables, keys or collections of PostgreSQL, MySQL, MariaDB, Redis and MongoDB services, and a console to query them, with the database's own client. |
| **Alerts** | Discord, Slack, email (Resend) or signed webhooks for failed or finished deploys, crashes, failed cron runs and backups, and CPU, memory or volume thresholds. |
| **Web terminal** | A shell in a running service's container, from the Console tab. |
| **Logs** | The output of every service of an environment, merged by time and searched on the phone, and one JSON line per HTTP request. Query strings are left out, since they often hold tokens. |

## Deploying from the command line

```sh
pharbor deploy NAME --image IMAGE [--port N] [--domain NAME]... [-e KEY=VALUE]...
                    [--health /path] [--timeout SEC] [--restart on-failure[:N]|always|never]
                    [--sleep-after 10m]
```

Later deployments of the same service only need what changes: its image, port, domains and variables are remembered.

Your app is given `$PORT`. Without `--port`, PocketHarbor uses that port if the app opened it, or else the first one it opens. Without `--health`, a deployment counts as healthy once its port accepts connections.

## Keeping it running on Android

Android stops background apps to save battery. With Termux:Boot, the installer sets up both PocketHarbor and the engine's daemon. The daemon revives services that Android killed, and keeps the CPU awake for them.

Also:

- set Termux's battery use to **Unrestricted** in Android's app settings;
- on Android 12 and later, run `pdock doctor`: it says whether Android still limits background processes, and gives the `adb` commands that lift the limit.

## How requests flow

The proxy is one event loop:

- It reads a request's head, picks a service by hostname, and forwards the request with `Connection: close`.
- It then copies bytes until the service closes.
- Serving one request per connection means it never has to find where a body ends, which is also what request smuggling depends on.
- WebSockets are the same copying.

Anything slow, like starting a container, runs in a separate process. That process reports back by rewriting `routes.json` and sending `SIGHUP`. Requests that arrived meanwhile wait in the proxy.

| File | Purpose |
|---|---|
| [src/proxy.zig](src/proxy.zig) | The event loop, parked requests, idle sleep, access logs |
| [src/http.zig](src/http.zig) | Request parsing and rewriting |
| [src/routes.zig](src/routes.zig) | Hostname lookup |
| [src/deploy.zig](src/deploy.zig) | Zero-downtime deployments, waking, sleeping |
| [src/cloudflare.zig](src/cloudflare.zig), [src/edge.zig](src/edge.zig) | The Cloudflare API, and keeping the tunnel and DNS in step |
| [src/domains.zig](src/domains.zig) | DNS records to show, and the check that a name reaches the phone |
| [src/tunnel.zig](src/tunnel.zig) | Cloudflare Tunnel |
| [src/relay.zig](src/relay.zig), [src/relay/worker.js](src/relay/worker.js) | The relay: a Worker and a Durable Object that hold the phone's WebSocket, and the phone's end of it |
| [src/store.zig](src/store.zig) | Services, settings and the generated routes |
| [src/engine.zig](src/engine.zig) | Talks to `pdock` |

Releases are built by `.github/workflows/release.yml` when a `vX.Y.Z` tag matching `src/version.zig` and `build.zig.zon` is pushed.
