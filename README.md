# PocketHarbor

Deploy and serve applications from an Android phone, without root. PocketHarbor
runs on top of the [PocketDock](https://github.com/afroni-sas/PocketDock) engine
and needs `pdock` installed.

## Quick start

```sh
pharbor serve -d
pharbor deploy web --image nginx:alpine --port 80 --domain web.example.com
pharbor tunnel quick web     # a temporary public https:// URL, no account needed
```

## What it does

| | |
|---|---|
| **Routing** | One proxy serves every service by hostname, exact names and `*.example.com`. HTTP and WebSocket. |
| **Zero-downtime deploys** | The new version must open its port and pass its health check before traffic moves. The old one then drains and stops. A failed deployment leaves the running version alone. |
| **Public access** | Cloudflare Tunnel: works behind a carrier's NAT, with HTTPS and no open port. |
| **Domains** | Custom hostnames per service, or `NAME.yourdomain` for all of them with `pharbor domain base`. |
| **Idle sleep** | `--sleep-after 10m` stops a service nobody uses. The next request starts it and waits for it. |
| **HTTP logs** | One JSON line per request: method, host, path, status, duration, bytes and the real client address. Query strings are left out, since they often hold tokens. |

## Deploying

```sh
pharbor deploy NAME --image IMAGE [--port N] [--domain NAME]... [-e KEY=VALUE]...
                    [--health /path] [--sleep-after 10m] [--timeout SEC]
```

Later deployments of the same service only need what changes: its image, port,
domains and variables are remembered. Your app is given `$PORT`. Without
`--port`, PocketHarbor uses that port if the app opened it, or else the first one
it opens. Without `--health`, a deployment counts as healthy once its port
accepts connections.

## A permanent public address

Create a tunnel in the Cloudflare dashboard and copy its token, then:

```sh
pharbor tunnel start TOKEN
```

In the dashboard, point each public hostname at the origin the command prints.
Add the same hostname to the service with `--domain` or `pharbor domain add`.
To send every subdomain of a zone here, use `*.example.com` in the dashboard and
`pharbor domain base example.com`.

## Keeping it running

```sh
pdock daemon -d && pdock daemon install   # revive services after a crash or reboot
pharbor serve -d && pharbor install       # the same for the proxy
```

`serve -d` restarts the proxy if it dies, and the proxy follows a service whose
port changes when it comes back. The `install` commands need the Termux:Boot app.

## How requests flow

The proxy is one event loop. It reads a request's head, picks a service by
hostname, and forwards it with `Connection: close`, then copies bytes until the
service closes. Serving one request per connection means it never has to find
where a body ends, which is also what request smuggling depends on. WebSockets
are the same copying.

Anything slow, like starting a container, runs in a separate process that
reports back by rewriting `routes.json` and sending `SIGHUP`. Requests that
arrived meanwhile wait in the proxy.

| File | Purpose |
|---|---|
| [src/proxy.zig](src/proxy.zig) | The event loop, parked requests, idle sleep, access logs |
| [src/http.zig](src/http.zig) | Request parsing and rewriting |
| [src/routes.zig](src/routes.zig) | Hostname lookup |
| [src/deploy.zig](src/deploy.zig) | Zero-downtime deployments, waking, sleeping |
| [src/tunnel.zig](src/tunnel.zig) | Cloudflare Tunnel |
| [src/store.zig](src/store.zig) | Services, settings and the generated routes |
| [src/engine.zig](src/engine.zig) | Talks to `pdock` |
