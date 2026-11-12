## Install

In Termux, or on Linux. The installer asks a few questions (data directory, port, owner account, domains, Cloudflare tunnel, start at boot), installs PocketDock with it, and starts everything:

```bash
curl -fsSL ${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/releases/download/${GITHUB_REF_NAME}/install.sh | sh -s -- --version ${GITHUB_REF_NAME}
```

Add `--yes` to skip the questions, for instance `sh -s -- --yes --email you@example.com`; `sh install.sh --help` lists the options. Running it again updates PocketHarbor and keeps the data.

From a computer, through adb, push the files and run it there:

```bash
mkdir ph && cd ph
gh release download ${GITHUB_REF_NAME} -R ${GITHUB_REPOSITORY} -p 'pharbor-android-arm64-v8a' -p install.sh -p SHA256SUMS
gh release download -R afroni-sas/PocketDock -p 'pdock-android-arm64-v8a'
gh release download -R afroni-sas/PocketDock -p SHA256SUMS -O SHA256SUMS.pdock
adb push . /data/local/tmp/ph
adb shell sh /data/local/tmp/ph/install.sh --from /data/local/tmp/ph
```

A shell started by adb cannot start PocketHarbor at boot; Termux can.

## Uninstall

```bash
curl -fsSL ${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/releases/download/${GITHUB_REF_NAME}/uninstall.sh | sh
```

It stops PocketHarbor and its services and removes the programs, the start at boot and the lines the installer added to your shell. The data stays, and installing again brings the projects back, unless you choose to delete it (`--purge`; `--purge-engine` also deletes the images).

## Files

| Device | File |
|---|---|
| Phones and tablets (64-bit ARM) | `pharbor-android-arm64-v8a` |
| Emulators, x86 devices and Linux PCs | `pharbor-android-x86_64` |
| Everything | `install.sh`, `uninstall.sh` |
| AI agents | `pocketharbor-skill.tar.gz`: the skill and the API reference |

The binaries are static: they also run on any 64-bit Linux.

## For AI agents

The skill teaches an agent (Claude Code and others that read `SKILL.md`) to drive PocketHarbor through its API:

```bash
mkdir -p ~/.claude/skills && curl -fsSL ${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/releases/download/${GITHUB_REF_NAME}/pocketharbor-skill.tar.gz | tar -xz -C ~/.claude/skills
```

Then give it `PHARBOR_URL` and an API token (`PHARBOR_TOKEN`, from Account › API tokens).

## Verify

```bash
sha256sum -c --ignore-missing SHA256SUMS
```

Built from commit ${GITHUB_SHA} by [this workflow run](${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}).
