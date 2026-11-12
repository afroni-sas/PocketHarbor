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
#   --cloudflare-token T    connect Cloudflare: tunnel and DNS   PHARBOR_CLOUDFLARE_TOKEN
#                           records are then set up by PocketHarbor
#   --tunnel-token TOKEN    start a Cloudflare tunnel            PHARBOR_TUNNEL_TOKEN
#   --boot, --no-boot       start at boot (Termux:Boot, systemd) PHARBOR_BOOT=1|0
#   --no-start              install and set up, do not start     PHARBOR_START=0
#   --from DIR              take the files from DIR, not GitHub (for adb push);
#                           the checksums are read from its SHA256SUMS* files
#   -h, --help
#
# uninstall.sh, next to this script in each release, removes it again.
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
PORT_GIVEN=0
[ -z "$PORT" ] || PORT_GIVEN=1
BIND=${PHARBOR_BIND:-}
EMAIL=${PHARBOR_EMAIL:-}
PASSWORD=${PHARBOR_PASSWORD:-}
DOMAIN=${PHARBOR_DOMAIN:-}
PANEL_DOMAIN=${PHARBOR_PANEL_DOMAIN:-}
TUNNEL_TOKEN=${PHARBOR_TUNNEL_TOKEN:-}
CLOUDFLARE_TOKEN=${PHARBOR_CLOUDFLARE_TOKEN:-}
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
  --cloudflare-token T  connect your Cloudflare account: PocketHarbor makes its
                        tunnel and writes the DNS records of your domains
  --tunnel-token TOKEN  start a Cloudflare tunnel made by hand instead
  --boot, --no-boot     start at boot (Termux:Boot or systemd)
  --no-start            install and set up, but do not start
  --from DIR            take the files from DIR instead of GitHub (adb push)

Each option has a variable: PHARBOR_YES, PHARBOR_VERSION, PHARBOR_INSTALL_DIR,
PHARBOR_ROOT, PHARBOR_PORT, PHARBOR_BIND, PHARBOR_EMAIL, PHARBOR_PASSWORD,
PHARBOR_DOMAIN, PHARBOR_PANEL_DOMAIN, PHARBOR_CLOUDFLARE_TOKEN,
PHARBOR_TUNNEL_TOKEN, PHARBOR_BOOT,
PHARBOR_START. A private repository is read with gh's token or GITHUB_TOKEN.

To remove PocketHarbor: sh uninstall.sh (it keeps the data unless --purge).
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
        die "could not download $2. Check the connection${VERSION:+, and that release $VERSION exists}."
    }
    if [ -n "$FROM" ]; then
        # The checksums of both releases: SHA256SUMS, SHA256SUMS.pdock...
        cat "$FROM"/SHA256SUMS* >"$WORK/sums" 2>/dev/null || die "no SHA256SUMS in $FROM"
    else
        get "$1" SHA256SUMS "$WORK/sums" "${4:-}" || die "could not download the checksums of $2"
    fi
    expected=$(grep " $2\$" "$WORK/sums" | cut -d' ' -f1)
    [ -n "$expected" ] || die "SHA256SUMS has no entry for $2"
    actual=$(sha256 "$tmp")
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

PD() {
    if [ -n "$ENGINE_ROOT" ]; then
        POCKETDOCK_ROOT=$ENGINE_ROOT "$INSTALL_DIR/pdock" "$@"
    else
        "$INSTALL_DIR/pdock" "$@"
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

# Checks -----------------------------------------------------------------------

# listening PORT: true when a program listens on PORT. The kernel's table
# first; Android 10 and later hide it from apps, so then ss or netstat, and
# at last a connection attempt.
listening() {
    hex=$(printf ':%04X' "$1")
    readable=0
    for f in /proc/net/tcp /proc/net/tcp6; do
        table=$(cat "$f" 2>/dev/null) || continue
        [ "$(printf '%s\n' "$table" | wc -l)" -gt 1 ] || continue
        readable=1
        printf '%s\n' "$table" | awk -v h="$hex" 'NR > 1 && $4 == "0A" && substr($2, length($2) - 4) == h { found = 1 } END { exit !found }' && return 0
    done
    [ $readable = 0 ] || return 1
    if command -v ss >/dev/null 2>&1 && out=$(ss -ltn 2>/dev/null); then
        printf '%s\n' "$out" | awk 'NR > 1 { print $4 }' | grep -qE "[:.]$1\$"
        return
    fi
    if command -v netstat >/dev/null 2>&1 && out=$(netstat -ltn 2>/dev/null) && [ -n "$out" ]; then
        printf '%s\n' "$out" | awk '{ print $4 }' | grep -qE "[:.]$1\$"
        return
    fi
    if command -v curl >/dev/null 2>&1; then
        code=0
        curl -s -o /dev/null -m 2 "http://127.0.0.1:$1/" 2>/dev/null || code=$?
        # 7: nothing accepted the connection.
        [ $code != 7 ]
        return
    fi
    return 1
}

# The program listening on PORT, when the system says.
port_owner() {
    command -v ss >/dev/null 2>&1 || return 0
    ss -ltnp 2>/dev/null | awk -v p=":$1" '$4 ~ p"$" { print $NF; exit }' | sed -n 's/.*(("\([^"]*\)".*/\1/p'
}

# True when PORT is the one this installation's proxy already holds.
own_port() {
    proxy_pid >/dev/null || return 1
    [ "$(sed -n 's/.*"proxy_port": *\([0-9]*\).*/\1/p' "$DATA/settings.json" 2>/dev/null | head -n 1)" = "$1" ]
}

# What is wrong with PORT, or nothing.
port_problem() {
    case "$1" in '' | *[!0-9]*)
        echo "The port must be a number."
        return
        ;;
    esac
    if [ "$1" -lt 1 ] || [ "$1" -gt 65535 ]; then
        echo "The port must be between 1 and 65535."
        return
    fi
    if [ "$1" -lt 1024 ] && [ "$(id -u)" != 0 ]; then
        echo "Ports below 1024 need root; choose 1024 or above."
        return
    fi
    own_port "$1" && return
    if listening "$1"; then
        who=$(port_owner "$1")
        echo "Port $1 is already in use${who:+ by $who}."
    fi
}

# The first free port from N on.
free_port() {
    p=$1
    case "$p" in '' | *[!0-9]*) p=8080 ;; esac
    [ "$p" -ge 1024 ] || p=8080
    while [ "$p" -le 65535 ]; do
        [ -n "$(port_problem "$p")" ] || {
            echo "$p"
            return
        }
        p=$((p + 1))
    done
    echo 8080
}

valid_email() {
    case "$1" in
        *' '* | *@*@* | @* | *@) return 1 ;;
        *@*.*) return 0 ;;
        *) return 1 ;;
    esac
}

# "https://App.Example.com/" → "app.example.com"; empty when it is not a name.
clean_domain() {
    d=$(printf '%s' "$1" | tr 'A-Z' 'a-z' | sed 's#^[a-z]*://##; s#/.*$##; s#:[0-9]*$##; s#\.$##')
    case "$d" in
        '' | *[!a-z0-9.*-]* | .* | *..* | *-.* | *.-*) return 0 ;;
        *.*) echo "$d" ;;
    esac
}

# Makes DIR and checks that it can be written to.
writable() {
    mkdir -p "$1" 2>/dev/null && [ -w "$1" ] && [ -d "$1" ]
}

# Free space, in MB, where DIR is.
free_mb() {
    df -Pk "$1" 2>/dev/null | awk 'NR == 2 { print int($4 / 1024) }'
}

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        toybox sha256sum "$1" 2>/dev/null | cut -d' ' -f1
    fi
}

# Waits for the dashboard to answer on this device.
answers() {
    i=0
    while [ $i -lt 50 ]; do
        if command -v curl >/dev/null 2>&1; then
            curl -fs -o /dev/null -m 2 "http://127.0.0.1:$1/api/status" 2>/dev/null && return 0
        elif wget -q -T 2 -O /dev/null "http://127.0.0.1:$1/api/status" 2>/dev/null; then
            return 0
        fi
        sleep 0.2
        i=$((i + 1))
    done
    return 1
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
            --port) need "$@"; PORT=$2; PORT_GIVEN=1; shift ;;
            --local-only) BIND=127.0.0.1 ;;
            --email) need "$@"; EMAIL=$2; shift ;;
            --domain) need "$@"; DOMAIN=$2; shift ;;
            --panel-domain) need "$@"; PANEL_DOMAIN=$2; shift ;;
            --tunnel-token) need "$@"; TUNNEL_TOKEN=$2; shift ;;
            --cloudflare-token) need "$@"; CLOUDFLARE_TOKEN=$2; shift ;;
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
    # An earlier install keeps its port.
    if [ -z "$PORT" ] && [ -f "$DATA/settings.json" ]; then
        PORT=$(sed -n 's/.*"proxy_port": *\([0-9]*\).*/\1/p' "$DATA/settings.json" | head -n 1)
    fi
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
        while :; do
            ask INSTALL_DIR "Install the programs in" "$INSTALL_DIR"
            writable "$INSTALL_DIR" && break
            say "${RED}Cannot write to $INSTALL_DIR.$RESET Choose a folder of yours$( [ "$(id -u)" = 0 ] || echo ', or run the installer as root')."
            INSTALL_DIR=$(default_install_dir)
        done
        while :; do
            ask DATA "Keep the data in" "$DATA"
            writable "$DATA" && break
            say "${RED}Cannot write to $DATA.$RESET Choose another folder."
            DATA=$(default_data_dir)
        done
        [ -f "$DATA/settings.json" ] && upgrade=1
        [ $upgrade = 0 ] || say "${DIM}An installation is already there: it is updated, and its data and settings stay.$RESET"
        while :; do
            ask PORT "Port of the proxy and the dashboard" "$PORT"
            problem=$(port_problem "$PORT")
            [ -n "$problem" ] || break
            say "${RED}$problem$RESET"
            PORT=$(free_port "$PORT")
            say "Port $PORT is free; press Enter to take it."
        done
        if [ "$BIND" = 0.0.0.0 ]; then local_default=n; else local_default=y; fi
        if agree "Only reachable from this device (choose this with a tunnel)?" "$local_default"; then BIND=127.0.0.1; else BIND=0.0.0.0; fi
        if [ $upgrade = 1 ] && [ -x "$INSTALL_DIR/pharbor" ] && has_owner; then
            say "${DIM}The owner account already exists.$RESET"
            EMAIL=""
        elif agree "Create the owner account now (otherwise the first visit does)?" y; then
            while :; do
                ask EMAIL "Email" "$EMAIL"
                valid_email "$EMAIL" && break
                say "${RED}That is not an email address.$RESET"
                EMAIL=""
            done
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
        while :; do
            ask DOMAIN "Domain for the services, as NAME.DOMAIN (empty for none)" "$DOMAIN"
            [ -n "$DOMAIN" ] || break
            d=$(clean_domain "$DOMAIN")
            if [ -n "$d" ]; then
                DOMAIN=$d
                break
            fi
            say "${RED}\"$DOMAIN\" is not a domain name, like apps.example.com.$RESET"
            DOMAIN=""
        done
        while :; do
            ask PANEL_DOMAIN "Domain of the dashboard (empty for none)" "$PANEL_DOMAIN"
            [ -n "$PANEL_DOMAIN" ] || break
            d=$(clean_domain "$PANEL_DOMAIN")
            if [ -n "$d" ]; then
                PANEL_DOMAIN=$d
                break
            fi
            say "${RED}\"$PANEL_DOMAIN\" is not a domain name, like harbor.example.com.$RESET"
            PANEL_DOMAIN=""
        done
        say "${DIM}With a Cloudflare API token, PocketHarbor makes its tunnel and writes the DNS records of your domains."
        say "Create one at dash.cloudflare.com/profile/api-tokens with: Account: Cloudflare Tunnel: Edit, Zone: DNS: Edit, Zone: Zone: Read.$RESET"
        if [ -z "$CLOUDFLARE_TOKEN" ] && agree "Connect your Cloudflare account now?" n; then
            while :; do
                secret CLOUDFLARE_TOKEN "Cloudflare API token"
                [ ${#CLOUDFLARE_TOKEN} -ge 20 ] && break
                [ -n "$CLOUDFLARE_TOKEN" ] || break
                say "${RED}That is too short for an API token; paste the whole token, or press Enter to skip.$RESET"
            done
        fi
        if [ -z "$CLOUDFLARE_TOKEN" ] && agree "Or start a tunnel you made by hand (needs its token)?" n; then
            while :; do
                secret TUNNEL_TOKEN "Tunnel token (Zero Trust > Networks > Tunnels > your tunnel)"
                [ ${#TUNNEL_TOKEN} -ge 40 ] && break
                [ -n "$TUNNEL_TOKEN" ] || break
                say "${RED}That is too short for a tunnel token; paste the whole token, or press Enter to skip.$RESET"
            done
        fi
        if can_boot; then
            if agree "Start PocketHarbor when the device boots?" y; then BOOT=1; else BOOT=0; fi
        fi
        if [ "$START" = 1 ]; then
            agree "Start it now?" y || START=0
        fi
    fi

    writable "$INSTALL_DIR" || die "cannot write to $INSTALL_DIR; choose another folder with --dir$( [ "$(id -u)" = 0 ] || echo ', or run as root')"
    writable "$DATA" || die "cannot write to $DATA; choose another folder with --data"
    problem=$(port_problem "$PORT")
    if [ -n "$problem" ]; then
        case "$problem" in
            *"in use"*)
                [ $PORT_GIVEN = 0 ] || die "$problem Choose another one with --port, for instance --port $(free_port "$PORT")."
                PORT=$(free_port "$PORT")
                say "$problem PocketHarbor takes port $PORT instead."
                ;;
            *) die "$problem" ;;
        esac
    fi
    if [ -n "$EMAIL" ]; then valid_email "$EMAIL" || die "\"$EMAIL\" is not an email address"; fi
    if [ -n "$DOMAIN" ]; then
        d=$(clean_domain "$DOMAIN")
        [ -n "$d" ] || die "\"$DOMAIN\" is not a domain name, like apps.example.com"
        DOMAIN=$d
    fi
    if [ -n "$PANEL_DOMAIN" ]; then
        d=$(clean_domain "$PANEL_DOMAIN")
        [ -n "$d" ] || die "\"$PANEL_DOMAIN\" is not a domain name, like harbor.example.com"
        PANEL_DOMAIN=$d
    fi
    if [ -n "$PASSWORD" ] && [ ${#PASSWORD} -lt 8 ]; then die "the password needs 8 characters or more"; fi
    space=$(free_mb "$DATA")
    if [ -n "$space" ]; then
        [ "$space" -ge 200 ] || die "only $space MB are free in $DATA; PocketHarbor and the images of its services need at least 200 MB"
        [ "$space" -ge 1024 ] || say "${DIM}Only $space MB are free in $DATA: a few images will fill it.$RESET"
    fi
    if [ -n "$EMAIL" ] && [ -z "$PASSWORD" ]; then
        PASSWORD=$(random_password)
        [ ${#PASSWORD} -ge 8 ] || die "could not generate a password; set PHARBOR_PASSWORD"
        GENERATED=1
    fi
    if [ -z "$BOOT" ]; then
        if can_boot; then BOOT=1; else BOOT=0; fi
    fi

    step "Installing"
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
        if answers "$PORT"; then
            ok "running on $BIND:$PORT"
        else
            say "${RED}PocketHarbor started but the dashboard does not answer on port $PORT yet.$RESET Its log:"
            tail -n 15 "$DATA/proxy.log" 2>/dev/null || true
        fi
        # Services that uninstall.sh stopped, when it kept the data.
        if [ -f "$DATA/stopped-by-uninstall" ]; then
            back=0
            while IFS= read -r name; do
                [ -n "$name" ] || continue
                PD start "$name" >/dev/null 2>&1 && back=$((back + 1))
            done <"$DATA/stopped-by-uninstall"
            rm -f "$DATA/stopped-by-uninstall"
            [ $back = 0 ] || ok "started $back services again"
        fi
        if [ -n "$CLOUDFLARE_TOKEN" ]; then
            if printf '%s\n' "$CLOUDFLARE_TOKEN" | PH cloudflare connect >"$WORK/cf" 2>&1; then
                ok "Cloudflare connected: PocketHarbor sets up the tunnel and the DNS records"
            else
                say "${RED}Cloudflare was not connected:$RESET $(sed 's/^error: //' "$WORK/cf" | tail -n 1)"
                say "Connect it later in Settings > Public access, or: pharbor cloudflare connect"
            fi
        elif [ -n "$TUNNEL_TOKEN" ]; then
            PH tunnel start "$TUNNEL_TOKEN" >/dev/null && ok "Cloudflare tunnel started" || say "The tunnel did not start; see: pharbor tunnel status"
        fi
    elif [ -n "$CLOUDFLARE_TOKEN" ] || [ -n "$TUNNEL_TOKEN" ]; then
        say "Start it, then connect Cloudflare in Settings > Public access"
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
