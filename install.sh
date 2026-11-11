#!/bin/sh
# Installs and sets up PocketHarbor, with the PocketDock engine it runs on,
# on Android (Termux, or adb shell) or Linux. It asks a few questions; with
# --yes it asks none and uses the defaults and the PHARBOR_* variables.
#
#   curl -fsSL https://raw.githubusercontent.com/afroni-sas/PocketHarbor/main/install.sh | sh
#   curl -fsSL .../install.sh | sh -s -- --yes --email you@example.com
#
# While the repository is private, give a token that can read it in
# GITHUB_TOKEN, or be signed in with gh; the script uses either. Run it again
# to update: the data and the settings stay.
#
# Options (each also has a variable, which the option overrides):
#   -y, --yes               no questions                         PHARBOR_YES=1
#   --version TAG           release to install, e.g. v0.1.0       PHARBOR_VERSION
#   --dir DIR               where pharbor and pdock go           PHARBOR_INSTALL_DIR
#   --data DIR              data directory                       PHARBOR_ROOT
#   --port N                port of the proxy and dashboard      PHARBOR_PORT (8080)
#   --local-only            listen on 127.0.0.1 only (tunnels)   PHARBOR_BIND=127.0.0.1
#   --email EMAIL           create the owner account             PHARBOR_EMAIL
#                           its password: PHARBOR_PASSWORD, asked, or generated
#   --domain DOMAIN         every service at NAME.DOMAIN         PHARBOR_DOMAIN
#   --panel-domain HOST     where the dashboard answers           PHARBOR_PANEL_DOMAIN
#   --tunnel-token TOKEN    start a Cloudflare tunnel            PHARBOR_TUNNEL_TOKEN
#   --boot, --no-boot       start at boot (Termux:Boot, systemd) PHARBOR_BOOT=1|0
#   --no-start              install and set up, do not start     PHARBOR_START=0
#   --from DIR              take the files from DIR, not GitHub (for adb push);
#                           the checksums are read from its SHA256SUMS* files
#   -h, --help
#
# Other variables: PHARBOR_RELEASE_URL and POCKETDOCK_RELEASE_URL replace the
# download locations; PHARBOR_GITHUB_TOKEN, GITHUB_TOKEN or GH_TOKEN reach a
# private repository.

set -eu

REPO="afroni-sas/PocketHarbor"
ENGINE_REPO="afroni-sas/PocketDock"

YES=${PHARBOR_YES:-0}
VERSION=${PHARBOR_VERSION:-}
INSTALL_DIR=${PHARBOR_INSTALL_DIR:-}
DATA=${PHARBOR_ROOT:-}
PORT=${PHARBOR_PORT:-}
BIND=${PHARBOR_BIND:-}
EMAIL=${PHARBOR_EMAIL:-}
PASSWORD=${PHARBOR_PASSWORD:-}
DOMAIN=${PHARBOR_DOMAIN:-}
PANEL_DOMAIN=${PHARBOR_PANEL_DOMAIN:-}
TUNNEL_TOKEN=${PHARBOR_TUNNEL_TOKEN:-}
BOOT=${PHARBOR_BOOT:-}
START=${PHARBOR_START:-1}
FROM=""
GENERATED=""

# Output ---------------------------------------------------------------------

if [ -t 1 ]; then
    BOLD=$(printf '\033[1m') DIM=$(printf '\033[2m') GREEN=$(printf '\033[32m') RED=$(printf '\033[31m') RESET=$(printf '\033[0m')
else
    BOLD="" DIM="" GREEN="" RED="" RESET=""
fi

say() { printf '%s\n' "$*"; }
step() { printf '\n%s==> %s%s\n' "$BOLD" "$*" "$RESET"; }
ok() { printf '%s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
die() {
    printf '%serror:%s %s\n' "$RED" "$RESET" "$*" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
Installs and sets up PocketHarbor and PocketDock. Without --yes it asks.

  sh install.sh [options]

  -y, --yes             no questions: defaults, options and PHARBOR_* variables
  --version TAG         release to install, e.g. v0.1.0 (default: the latest)
  --dir DIR             where pharbor and pdock go
  --data DIR            data directory
  --port N              port of the proxy and the dashboard (8080)
  --local-only          listen on 127.0.0.1 only, for use with a tunnel
  --email EMAIL         create the owner account; its password comes from
                        PHARBOR_PASSWORD, is asked, or is generated
  --domain DOMAIN       every service also answers at NAME.DOMAIN
  --panel-domain HOST   where the dashboard answers
  --tunnel-token TOKEN  start a Cloudflare tunnel
  --boot, --no-boot     start at boot (Termux:Boot or systemd)
  --no-start            install and set up, but do not start
  --from DIR            take the files from DIR instead of GitHub (adb push)

Each option has a variable: PHARBOR_YES, PHARBOR_VERSION, PHARBOR_INSTALL_DIR,
PHARBOR_ROOT, PHARBOR_PORT, PHARBOR_BIND, PHARBOR_EMAIL, PHARBOR_PASSWORD,
PHARBOR_DOMAIN, PHARBOR_PANEL_DOMAIN, PHARBOR_TUNNEL_TOKEN, PHARBOR_BOOT,
PHARBOR_START. A private repository is read with gh's token or GITHUB_TOKEN.
USAGE
}

# Questions ------------------------------------------------------------------

# Questions go to the terminal even under `curl | sh`, whose stdin is the
# script itself.
interactive() {
    [ "$YES" != 1 ] && [ -r /dev/tty ] && [ -w /dev/tty ] && (: </dev/tty) 2>/dev/null
}

# ask VAR "Question" DEFAULT
ask() {
    if [ -n "$3" ]; then
        printf '%s %s[%s]%s: ' "$2" "$DIM" "$3" "$RESET" >/dev/tty
    else
        printf '%s: ' "$2" >/dev/tty
    fi
    IFS= read -r answer </dev/tty || answer=""
    [ -n "$answer" ] || answer=$3
    eval "$1=\$answer"
}

# agree "Question" y|n: true for yes.
agree() {
    if [ "$2" = y ]; then hint="Y/n"; else hint="y/N"; fi
    while :; do
        printf '%s [%s]: ' "$1" "$hint" >/dev/tty
        IFS= read -r answer </dev/tty || answer=""
        case "${answer:-$2}" in
            y | Y | yes | oui | o | O) return 0 ;;
            n | N | no | non) return 1 ;;
        esac
    done
}

# secret VAR "Question": without echo.
secret() {
    printf '%s: ' "$2" >/dev/tty
    (stty -echo </dev/tty) 2>/dev/null || true
    IFS= read -r answer </dev/tty || answer=""
    restore_tty
    printf '\n' >/dev/tty
    eval "$1=\$answer"
}

restore_tty() {
    (stty echo </dev/tty) 2>/dev/null || true
}
trap restore_tty INT TERM

# The device -----------------------------------------------------------------

platform() {
    case "${PREFIX:-}" in
        */com.termux/*)
            echo termux
            return
            ;;
    esac
    if [ -d /system/bin ] && [ -e /system/build.prop ]; then
        if [ "$(id -u)" = 2000 ]; then echo adb; else echo android; fi
        return
    fi
    echo linux
}

detect_abi() {
    case "$(uname -m)" in
        aarch64 | arm64) echo arm64-v8a ;;
        x86_64 | amd64) echo x86_64 ;;
        *) die "unsupported CPU: $(uname -m). PocketHarbor needs a 64-bit ARM or x86 device." ;;
    esac
}

default_install_dir() {
    case "$PLATFORM" in
        termux) echo "$PREFIX/bin" ;;
        # adb shell may only run programs from under /data/local/tmp.
        adb | android) echo /data/local/tmp/pocketharbor ;;
        *) if [ "$(id -u)" = 0 ]; then echo /usr/local/bin; else echo "$HOME/.local/bin"; fi ;;
    esac
}

default_data_dir() {
    case "$PLATFORM" in
        adb | android) echo /data/local/tmp/pocketharbor/data ;;
        *) echo "$HOME/.pocketharbor" ;;
    esac
}

can_boot() {
    case "$PLATFORM" in
        termux) return 0 ;;
        linux) command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] ;;
        *) return 1 ;;
    esac
}

lan_address() {
    addr=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1)
    if [ -z "$addr" ]; then
        addr=$(ip -4 addr show wlan0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -n 1)
    fi
    if [ -z "$addr" ]; then
        addr=$(ifconfig wlan0 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p; s/.*inet \([0-9.]*\) .*/\1/p' | head -n 1)
    fi
    echo "$addr"
}

# Downloads ------------------------------------------------------------------

have_fetcher() {
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1
}

# fetch URL FILE
fetch() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 -o "$2" "$1"
    else
        wget -q -O "$2" "$1"
    fi
}

# fetch_auth URL ACCEPT FILE: with the token, kept out of the command line.
fetch_auth() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 -H @"$HEADERS" -H "Accept: $2" -o "$3" "$1"
    else
        wget -q --header="Authorization: Bearer $TOKEN" --header="Accept: $2" -O "$3" "$1"
    fi
}

github_token() {
    t=${PHARBOR_GITHUB_TOKEN:-${GITHUB_TOKEN:-${GH_TOKEN:-}}}
    if [ -z "$t" ] && command -v gh >/dev/null 2>&1; then
        t=$(gh auth token 2>/dev/null || true)
    fi
    printf '%s' "$t"
}

# The API address of a release asset, from the release's JSON.
asset_url() {
    tr ',{}[]' '\n\n\n\n\n' <"$1" |
        sed -nE 's/^[[:space:]]*"(url|name)":[[:space:]]*"([^"]*)".*$/\1 \2/p' |
        {
            url=""
            while read -r key val; do
                case "$key" in
                    url) case "$val" in */releases/assets/[0-9]*) url=$val ;; esac ;;
                    name) if [ "$val" = "$2" ] && [ -n "$url" ]; then
                        echo "$url"
                        break
                    fi ;;
                esac
            done
        }
}

# get REPO NAME FILE [BASE_URL]: one file of a release.
get() {
    if [ -n "$FROM" ]; then
        [ -f "$FROM/$2" ] || return 1
        cp "$FROM/$2" "$3"
        return
    fi
    if [ -n "${4:-}" ]; then
        fetch "$4/$2" "$3"
        return
    fi
    if [ -n "$TOKEN" ]; then
        if [ -n "$VERSION" ] && [ "$1" = "$REPO" ]; then
            api="https://api.github.com/repos/$1/releases/tags/$VERSION"
        else
            api="https://api.github.com/repos/$1/releases/latest"
        fi
        fetch_auth "$api" application/vnd.github+json "$WORK/release.json" || return 1
        url=$(asset_url "$WORK/release.json" "$2")
        [ -n "$url" ] || return 1
        fetch_auth "$url" application/octet-stream "$3"
        return
    fi
    if [ -n "$VERSION" ] && [ "$1" = "$REPO" ]; then
        fetch "https://github.com/$1/releases/download/$VERSION/$2" "$3"
    else
        fetch "https://github.com/$1/releases/latest/download/$2" "$3"
    fi
}

# install_binary REPO FILE NAME [BASE_URL]: downloads, checks and installs.
install_binary() {
    tmp="$WORK/$2"
    get "$1" "$2" "$tmp" "${4:-}" || {
        if [ "$1" = "$REPO" ] && [ -z "$TOKEN" ] && [ -z "$FROM" ] && [ -z "${4:-}" ]; then
            die "could not download $2. The repository is private: set GITHUB_TOKEN to a token that can read $REPO, or sign in with gh."
        fi
        die "could not download $2"
    }
    if [ -n "$FROM" ]; then
        # The checksums of both releases: SHA256SUMS, SHA256SUMS.pdock...
        cat "$FROM"/SHA256SUMS* >"$WORK/sums" 2>/dev/null || die "no SHA256SUMS in $FROM"
    else
        get "$1" SHA256SUMS "$WORK/sums" "${4:-}" || die "could not download the checksums of $2"
    fi
    expected=$(grep " $2\$" "$WORK/sums" | cut -d' ' -f1)
    [ -n "$expected" ] || die "SHA256SUMS has no entry for $2"
    actual=$(sha256sum "$tmp" | cut -d' ' -f1)
    [ "$actual" = "$expected" ] || die "checksum mismatch for $2; nothing was installed"
    chmod 755 "$tmp"
    "$tmp" version >/dev/null 2>&1 || die "$2 cannot run on this device"
    mv -f "$tmp" "$INSTALL_DIR/$3"
    ok "$3 $("$INSTALL_DIR/$3" version 2>/dev/null | head -n 1 | sed 's/^[a-z]* //')"
}

# Running it -----------------------------------------------------------------

PH() {
    if [ -n "$ENGINE_ROOT" ]; then
        POCKETDOCK_ROOT=$ENGINE_ROOT PHARBOR_ROOT=$DATA PDOCK_BIN="$INSTALL_DIR/pdock" "$INSTALL_DIR/pharbor" "$@"
    else
        PHARBOR_ROOT=$DATA PDOCK_BIN="$INSTALL_DIR/pdock" "$INSTALL_DIR/pharbor" "$@"
    fi
}

proxy_pid() {
    [ -f "$DATA/proxy.pid" ] || return 1
    pid=$(cut -d' ' -f1 "$DATA/proxy.pid")
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && echo "$pid"
}

stop_proxy() {
    pid=$(proxy_pid) || return 0
    kill -TERM "$pid" 2>/dev/null || true
    i=0
    while kill -0 "$pid" 2>/dev/null && [ $i -lt 50 ]; do
        sleep 0.1
        i=$((i + 1))
    done
}

has_owner() {
    PH user ls 2>/dev/null | grep -q @
}

random_password() {
    tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 20
}

systemd_unit() {
    cat <<UNIT
[Unit]
Description=PocketHarbor
After=network-online.target
Wants=network-online.target

[Service]
Environment="PHARBOR_ROOT=$DATA"
Environment="PDOCK_BIN=$INSTALL_DIR/pdock"
ExecStart="$INSTALL_DIR/pharbor" serve --listen $BIND:$PORT
Restart=on-failure
RestartSec=5

[Install]
WantedBy=$1
UNIT
}

# Makes pharbor a command, and remembers a data directory other than the
# default. Only ever touches a startup file in $HOME.
remember() {
    lines=""
    case ":$PATH:" in *":$INSTALL_DIR:"*) ;; *) lines="export PATH=\"$INSTALL_DIR:\$PATH\"" ;; esac
    if [ "$DATA" != "$HOME/.pocketharbor" ]; then
        lines="$lines${lines:+
}export PHARBOR_ROOT=\"$DATA\""
    fi
    if [ -n "$ENGINE_ROOT" ]; then
        lines="$lines${lines:+
}export POCKETDOCK_ROOT=\"$ENGINE_ROOT\""
    fi
    [ -n "$lines" ] || return 0
    case "$PLATFORM" in
        adb | android)
            say "In a new adb shell, first run:"
            say "$lines"
            return
            ;;
    esac
    case "${SHELL:-}" in
        *zsh) rc="$HOME/.zshrc" ;;
        *bash) rc="$HOME/.bashrc" ;;
        *) rc="$HOME/.profile" ;;
    esac
    printf '%s\n' "$lines" | while IFS= read -r line; do
        grep -qxF "$line" "$rc" 2>/dev/null || printf '%s\n' "$line" >>"$rc"
    done
    say "Added to $rc (open a new shell to use it):"
    say "$lines"
}

# Main -----------------------------------------------------------------------

need() {
    [ $# -ge 2 ] || die "$1 needs a value"
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -y | --yes) YES=1 ;;
            --version) need "$@"; VERSION=$2; shift ;;
            --dir) need "$@"; INSTALL_DIR=$2; shift ;;
            --data) need "$@"; DATA=$2; shift ;;
            --port) need "$@"; PORT=$2; shift ;;
            --local-only) BIND=127.0.0.1 ;;
            --email) need "$@"; EMAIL=$2; shift ;;
            --domain) need "$@"; DOMAIN=$2; shift ;;
            --panel-domain) need "$@"; PANEL_DOMAIN=$2; shift ;;
            --tunnel-token) need "$@"; TUNNEL_TOKEN=$2; shift ;;
            --boot) BOOT=1 ;;
            --no-boot) BOOT=0 ;;
            --no-start) START=0 ;;
            --from) need "$@"; FROM=$2; shift ;;
            -h | --help)
                usage
                exit 0
                ;;
            *) die "unknown option: $1 (see --help)" ;;
        esac
        shift
    done

    PLATFORM=$(platform)
    ABI=$(detect_abi)
    [ -n "$INSTALL_DIR" ] || INSTALL_DIR=$(default_install_dir)
    [ -n "$DATA" ] || DATA=$(default_data_dir)
    # An adb shell has HOME=/, where pdock cannot keep its images.
    ENGINE_ROOT=${POCKETDOCK_ROOT:-}
    case "$PLATFORM" in
        adb | android) [ -n "$ENGINE_ROOT" ] || ENGINE_ROOT=/data/local/tmp/pocketharbor/engine ;;
    esac
    [ -n "$PORT" ] || PORT=8080
    [ -n "$BIND" ] || BIND=0.0.0.0
    if [ -z "$FROM" ] && ! have_fetcher; then
        case "$PLATFORM" in
            adb | android) die "this shell has neither curl nor wget. Push the files with adb and use --from DIR (see the README)." ;;
            termux) die "neither curl nor wget is available. Run: pkg install curl" ;;
            *) die "neither curl nor wget is available" ;;
        esac
    fi

    say "${BOLD}PocketHarbor${RESET} installer: $PLATFORM, $ABI"

    # An earlier install keeps its answers.
    upgrade=0
    [ -f "$DATA/settings.json" ] && upgrade=1

    if interactive; then
        step "A few questions (Enter keeps the value in brackets)"
        ask INSTALL_DIR "Install the programs in" "$INSTALL_DIR"
        ask DATA "Keep the data in" "$DATA"
        [ -f "$DATA/settings.json" ] && upgrade=1
        ask PORT "Port of the proxy and the dashboard" "$PORT"
        if [ "$BIND" = 0.0.0.0 ]; then local_default=n; else local_default=y; fi
        if agree "Only reachable from this device (choose this with a tunnel)?" "$local_default"; then BIND=127.0.0.1; else BIND=0.0.0.0; fi
        if [ $upgrade = 1 ] && [ -x "$INSTALL_DIR/pharbor" ] && has_owner; then
            say "${DIM}The owner account already exists.$RESET"
            EMAIL=""
        elif agree "Create the owner account now (otherwise the first visit does)?" y; then
            ask EMAIL "Email" "$EMAIL"
            while :; do
                secret PASSWORD "Password (8 characters or more)"
                [ ${#PASSWORD} -ge 8 ] || {
                    say "Too short."
                    continue
                }
                secret again "Again"
                [ "$PASSWORD" = "$again" ] && break
                say "They differ; once more."
            done
        else
            EMAIL=""
        fi
        ask DOMAIN "Domain for the services, as NAME.DOMAIN (empty for none)" "$DOMAIN"
        ask PANEL_DOMAIN "Domain of the dashboard (empty for none)" "$PANEL_DOMAIN"
        if agree "Connect a Cloudflare tunnel now (needs its token)?" n; then
            secret TUNNEL_TOKEN "Tunnel token"
        fi
        if can_boot; then
            if agree "Start PocketHarbor when the device boots?" y; then BOOT=1; else BOOT=0; fi
        fi
        if [ "$START" = 1 ]; then
            agree "Start it now?" y || START=0
        fi
    fi

    case "$PORT" in '' | *[!0-9]*) die "the port must be a number" ;; esac
    [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "the port must be between 1 and 65535"
    if [ -n "$EMAIL" ] && [ -z "$PASSWORD" ]; then
        PASSWORD=$(random_password)
        [ ${#PASSWORD} -ge 8 ] || die "could not generate a password; set PHARBOR_PASSWORD"
        GENERATED=1
    fi
    if [ -z "$BOOT" ]; then
        if can_boot; then BOOT=1; else BOOT=0; fi
    fi

    step "Installing"
    mkdir -p "$INSTALL_DIR" "$DATA" || die "cannot create $INSTALL_DIR or $DATA"
    WORK=$(mktemp -d "$INSTALL_DIR/.pocketharbor-install.XXXXXX" 2>/dev/null) || {
        WORK="$INSTALL_DIR/.pocketharbor-install.$$"
        mkdir -p "$WORK"
    }
    HEADERS="$WORK/headers"
    trap 'rm -rf "$WORK"; restore_tty' EXIT
    TOKEN=""
    if [ -z "$FROM" ] && [ -z "${PHARBOR_RELEASE_URL:-}" ]; then
        TOKEN=$(github_token)
        if [ -n "$TOKEN" ]; then
            (umask 077 && printf 'Authorization: Bearer %s\n' "$TOKEN" >"$HEADERS")
        fi
    fi
    install_binary "$ENGINE_REPO" "pdock-android-$ABI" pdock "${POCKETDOCK_RELEASE_URL:-}"
    install_binary "$REPO" "pharbor-android-$ABI" pharbor "${PHARBOR_RELEASE_URL:-}"

    step "Setting up"
    # A running proxy still runs the old program; it starts again below.
    was_running=0
    if proxy_pid >/dev/null; then
        was_running=1
        stop_proxy
    fi
    if [ -n "$EMAIL" ]; then
        if has_owner && PH user ls 2>/dev/null | grep -qF "$EMAIL"; then
            say "The account $EMAIL already exists; its password is unchanged."
            GENERATED=""
        else
            printf '%s\n' "$PASSWORD" | PH user add "$EMAIL" >/dev/null 2>"$WORK/err" ||
                die "could not create the account $EMAIL: $(sed 's/^error: //' "$WORK/err")"
            ok "account $EMAIL"
        fi
    fi
    if [ -n "$DOMAIN" ]; then PH domain base "$DOMAIN" && ok "services at NAME.$DOMAIN"; fi
    if [ -n "$PANEL_DOMAIN" ]; then PH domain panel "$PANEL_DOMAIN" && ok "dashboard at $PANEL_DOMAIN"; fi

    service=""
    if [ "$BOOT" = 1 ]; then
        case "$PLATFORM" in
            termux)
                PH install --listen "$BIND:$PORT" >/dev/null
                ok "starts at boot (open the Termux:Boot app once so that Android allows it)"
                ;;
            linux)
                if [ "$(id -u)" = 0 ]; then
                    systemd_unit multi-user.target >/etc/systemd/system/pocketharbor.service
                    systemctl daemon-reload
                    systemctl enable pocketharbor >/dev/null 2>&1
                    service="systemctl"
                else
                    mkdir -p "$HOME/.config/systemd/user"
                    systemd_unit default.target >"$HOME/.config/systemd/user/pocketharbor.service"
                    systemctl --user daemon-reload
                    systemctl --user enable pocketharbor >/dev/null 2>&1
                    service="systemctl --user"
                    say "${DIM}To keep it running after you log out: loginctl enable-linger $(id -un)$RESET"
                fi
                ok "starts at boot (systemd)"
                ;;
            *) say "Starting at boot is not possible from an adb shell; use Termux for that." ;;
        esac
    fi

    if [ "$START" = 1 ] || [ $was_running = 1 ]; then
        if [ -n "$service" ]; then
            $service restart pocketharbor || die "systemd could not start it; see: $service status pocketharbor"
        else
            PH serve -d --listen "$BIND:$PORT" || die "PocketHarbor did not start"
        fi
        # Both detach before the proxy writes its pid file.
        i=0
        while ! proxy_pid >/dev/null && [ $i -lt 50 ]; do
            sleep 0.1
            i=$((i + 1))
        done
        proxy_pid >/dev/null || die "PocketHarbor did not start; try: PHARBOR_ROOT=$DATA $INSTALL_DIR/pharbor serve"
        ok "running on $BIND:$PORT"
        if [ -n "$TUNNEL_TOKEN" ]; then
            PH tunnel start "$TUNNEL_TOKEN" >/dev/null && ok "Cloudflare tunnel started" || say "The tunnel did not start; see: pharbor tunnel status"
        fi
    elif [ -n "$TUNNEL_TOKEN" ]; then
        say "Start it, then run: pharbor tunnel start TOKEN"
    fi

    step "Done"
    remember
    if [ "$BIND" = 0.0.0.0 ]; then
        addr=$(lan_address)
        say "Dashboard:  http://${addr:-THIS-DEVICE-ADDRESS}:$PORT/"
    else
        say "Dashboard:  http://127.0.0.1:$PORT/ on this device"
    fi
    [ -z "$PANEL_DOMAIN" ] || say "            https://$PANEL_DOMAIN/ through your tunnel"
    if [ -n "$EMAIL" ]; then
        say "Account:    $EMAIL"
        [ -z "$GENERATED" ] || say "Password:   $PASSWORD   (generated; change it in Account, it is not shown again)"
    elif ! has_owner; then
        say "Account:    the first visit to the dashboard creates it"
    fi
    say "Commands:   pharbor --help"
    [ "$START" = 1 ] || [ $was_running = 1 ] || say "Start it:   PHARBOR_ROOT=$DATA $INSTALL_DIR/pharbor serve -d --listen $BIND:$PORT"
}

main "$@"
