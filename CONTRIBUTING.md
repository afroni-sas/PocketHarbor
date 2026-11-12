# Contributing to PocketHarbor

Thanks for helping. Bug reports, fixes, documentation and new features are all welcome.

## Reporting a bug

Open an [issue](https://github.com/afroni-sas/PocketHarbor/issues) with:

- what you did, what you expected and what happened;
- the output of `pharbor version` and `pdock version`;
- the device: phone model and Android version, or Linux distribution, and whether it runs in Termux, adb or systemd;
- the relevant server logs, and the deployment's log if a deploy failed. With `serve -d`, server logs are in `$PHARBOR_ROOT/proxy.log` (by default `~/.pocketharbor/proxy.log`); with foreground `serve`, use the terminal output. For a systemd user service, use `journalctl --user -u pocketharbor`; for a system service, use `journalctl -u pocketharbor`.

Remove tokens, passwords and domain names you want to keep private before posting.

For a security problem, do not open an issue: write to contact@afroni.com.

## Proposing a change

For anything bigger than a fix, open an issue or a [discussion](https://github.com/afroni-sas/PocketHarbor/discussions) first. Agreeing on the approach early saves rewriting a pull request.

## Setting up

| You need | For |
|---|---|
| [Zig](https://ziglang.org/download/) 0.17.1, the `minimum_zig_version` of `build.zig.zon` | The program |
| [PocketDock](https://github.com/afroni-sas/PocketDock), installed or built | Running containers |
| Node 24 and pnpm 12, as in CI | The web interface, only when you change it |

```bash
git clone https://github.com/afroni-sas/PocketHarbor.git
cd PocketHarbor
zig build
```

The program is `zig-out/bin/pharbor`. It runs on any 64-bit Linux, so a phone is only needed to test what is specific to Android.

## Running a development instance

Give it its own data directories, so that it never touches a PocketHarbor you already run:

```bash
export PHARBOR_ROOT="$(mktemp -d /tmp/pharbor-dev.XXXXXX)"
export POCKETDOCK_ROOT="$PHARBOR_ROOT/engine"
export PDOCK_BIN="$(command -v pdock)"
printf 'a-password\n' | ./zig-out/bin/pharbor user add you@example.com
./zig-out/bin/pharbor serve --listen 127.0.0.1:8080
```

The dashboard is then at <http://127.0.0.1:8080>. Use a free port if 8080 is already taken, and adjust the proxy in `web/vite.config.js` to match. Stop it with Ctrl+C. Keep the value of `PHARBOR_ROOT` if you want to reuse this instance in another shell; each `mktemp` call creates a fresh directory.

## The web interface

It lives in `web/`: Vite, Preact and [@preact/signals](https://preactjs.com/guide/v10/signals/). State is kept in signals; the code uses no hooks.

```bash
cd web
pnpm install --frozen-lockfile
pnpm dev
```

`pnpm dev` serves the interface from its sources, and passes `/api` to the instance on port 8080.

The build is committed, so that `zig build` never needs Node. After a change, run `pnpm build` and commit what it writes to `src/web` and `src/web_assets.zig`. CI fails when the committed build does not match the sources.

## Before opening a pull request

```bash
zig build test --summary all
zig build android
zig build --release
./zig-out/bin/pharbor version
for f in install.sh uninstall.sh; do
  dash -n "$f"
  sh "$f" --help > /dev/null
done
```

These are the native build and script checks in [CI](.github/workflows/ci.yml). For web changes, also run `pnpm install --frozen-lockfile` and `pnpm build` from `web/`, and include the generated files described above.

Format changed Zig files with `zig fmt path/to/changed-file.zig`, using the project's Zig version. Keep unrelated formatting changes out of the pull request.

The install scripts run under toybox and busybox `sh` on phones: keep them POSIX.

Also:

- **Behaviour:** try the change on a development instance, and say in the pull request how you tested it.
- **Documentation:** update the [README](README.md) when a feature changes, and [docs/API.md](docs/API.md) when the API does.
- **Release notes:** a change users will notice gets a line in `.github/changes/vX.Y.Z.md`, for the next version.
- **Interface:** keep it simple and quiet, in the style of the existing pages.
- **Comments:** say why the code does what it does, not what it does.

## Pull requests

- Branch from `main`, with one change per pull request.
- The title says what changes for the user.
- The description says what changes and how it was tested.
- CI must pass. Pull requests are squash merged, so the commits inside one do not need to be tidy.

## License of contributions

PocketHarbor is under the [PolyForm Noncommercial License 1.0.0](LICENSE.md).

By sending a contribution, you agree that:

- it is your own work, or you have the right to send it;
- it is licensed under the same license;
- AFRONI SAS may also distribute it under other terms, including commercial licenses.

For a commercial use of PocketHarbor, ask for a license at contact@afroni.com.
