#!/bin/sh
# Removes PocketHarbor from this device: stops it and its services, removes
# its start at boot, the lines install.sh added to the shell's startup file,
# and the pharbor and pdock programs. The data stays unless you ask for it to
# go, so that installing again brings everything back.
#
#   curl -fsSL https://raw.githubusercontent.com/afroni-sas/PocketHarbor/main/uninstall.sh | sh
#   sh uninstall.sh --yes --purge
#
# Options (each also has the variable install.sh uses):
#   -y, --yes          no questions; keeps the data unless --purge
#   --dir DIR          where pharbor and pdock are            PHARBOR_INSTALL_DIR
#   --data DIR         data directory                         PHARBOR_ROOT
#   --purge            also delete the data: projects, volumes, backups, accounts
#   --purge-engine     also delete the engine's directory (images, containers)
#   -h, --help

set -eu

YES=${PHARBOR_YES:-0}
INSTALL_DIR=${PHARBOR_INSTALL_DIR:-}
DATA=${PHARBOR_ROOT:-}
PURGE=0
PURGE_ENGINE=0

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
Removes PocketHarbor and the PocketDock engine it installed. Without --yes it
asks; the data stays unless you choose to delete it.

  sh uninstall.sh [options]

  -y, --yes          no questions; keeps the data unless --purge is given
  --dir DIR          where pharbor and pdock are installed
  --data DIR         the data directory
  --purge            also delete the data: projects, volumes, backups, accounts
  --purge-engine     also delete the engine's directory: images and containers
USAGE
}

interactive() {
    [ "$YES" != 1 ] && [ -r /dev/tty ] && [ -w /dev/tty ] && (: </dev/tty) 2>/dev/null
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

# Where install.sh puts things, unless told otherwise.
default_install_dir() {
    case "$PLATFORM" in
        termux) echo "$PREFIX/bin" ;;
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

PD() {
    POCKETDOCK_ROOT=$ENGINE_ROOT "$INSTALL_DIR/pdock" "$@"
}

# The value of a "key": "value" pair in a JSON file written by pharbor.
json_value() {
    sed -n "s/.*\"$1\": *\"\\([^\"]*\\)\".*/\\1/p" "$2" 2>/dev/null | head -n 1
}

# Processes whose command line starts with PROGRAM ARG.
pids_of() {
    for d in /proc/[0-9]*; do
        line=$(tr '\0' ' ' <"$d/cmdline" 2>/dev/null) || continue
        case "$line" in "$1 $2"*) echo "${d#/proc/}" ;; esac
    done
}

# Ends a process, gently first.
end() {
    kill -TERM "$1" 2>/dev/null || return 0
    i=0
    while kill -0 "$1" 2>/dev/null && [ $i -lt 50 ]; do
        sleep 0.1
        i=$((i + 1))
    done
    kill -KILL "$1" 2>/dev/null || true
}

# The containers PocketHarbor made: of its services, of their deployments, and
# its tunnel.
containers() {
    {
        for f in "$DATA"/services/*.json "$DATA"/deployments/*/*.json; do
            [ -f "$f" ] && json_value container "$f"
        done
        echo pharbor-tunnel
    } | sed '/^$/d' | sort -u
}

# Removes lines that install.sh added to a startup file, keeping the others.
forget_lines() {
    rc=$1
    [ -f "$rc" ] || return 0
    tmp="$rc.pocketharbor-uninstall.$$"
    grep -vxF -e "export PATH=\"$INSTALL_DIR:\$PATH\"" -e "export PHARBOR_ROOT=\"$DATA\"" -e "export POCKETDOCK_ROOT=\"$ENGINE_ROOT\"" "$rc" >"$tmp" || true
    if cmp -s "$rc" "$tmp"; then
        rm -f "$tmp"
    else
        cat "$tmp" >"$rc" && rm -f "$tmp"
        ok "removed the PocketHarbor lines from $rc"
    fi
}

need() {
    [ $# -ge 2 ] || die "$1 needs a value"
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -y | --yes) YES=1 ;;
            --dir) need "$@"; INSTALL_DIR=$2; shift ;;
            --data) need "$@"; DATA=$2; shift ;;
            --purge) PURGE=1 ;;
            --purge-engine) PURGE_ENGINE=1 ;;
            -h | --help)
                usage
                exit 0
                ;;
            *) die "unknown option: $1 (see --help)" ;;
        esac
        shift
    done

    PLATFORM=$(platform)
    if [ -z "$INSTALL_DIR" ]; then
        found=$(command -v pharbor 2>/dev/null || true)
        case "$found" in
            /*) INSTALL_DIR=$(dirname "$found") ;;
            *) INSTALL_DIR=$(default_install_dir) ;;
        esac
    fi
    [ -n "$DATA" ] || DATA=$(default_data_dir)
    ENGINE_ROOT=${POCKETDOCK_ROOT:-}
    if [ -z "$ENGINE_ROOT" ]; then
        case "$PLATFORM" in
            adb | android) ENGINE_ROOT=/data/local/tmp/pocketharbor/engine ;;
            *) ENGINE_ROOT="$HOME/.pocketdock" ;;
        esac
    fi

    if [ ! -e "$INSTALL_DIR/pharbor" ] && [ ! -d "$DATA" ]; then
        say "PocketHarbor is not installed in $INSTALL_DIR, and there is no data in $DATA."
        say "If it is elsewhere, give --dir and --data."
        exit 0
    fi

    say "${BOLD}PocketHarbor${RESET} uninstaller: $PLATFORM"
    say "Programs:  $INSTALL_DIR/pharbor, $INSTALL_DIR/pdock"
    say "Data:      $DATA"
    say "Engine:    $ENGINE_ROOT"

    if interactive; then
        printf '\n' >/dev/tty
        agree "Remove PocketHarbor from this device?" n || {
            say "Nothing was changed."
            exit 0
        }
        if [ -d "$DATA" ] && [ $PURGE = 0 ]; then
            say "${DIM}Kept by default, so that installing again brings your projects back.$RESET"
            agree "Also delete the data (projects, volumes, backups, accounts)? This cannot be undone" n && PURGE=1
        fi
        if [ -d "$ENGINE_ROOT" ] && [ $PURGE_ENGINE = 0 ]; then
            agree "Also delete the engine's images and containers in $ENGINE_ROOT?" "$([ $PURGE = 1 ] && echo y || echo n)" && PURGE_ENGINE=1
        fi
    fi

    step "Stopping PocketHarbor"
    # systemd would start it again.
    if command -v systemctl >/dev/null 2>&1; then
        if [ -f /etc/systemd/system/pocketharbor.service ] && [ "$(id -u)" = 0 ]; then
            systemctl disable --now pocketharbor >/dev/null 2>&1 || true
            rm -f /etc/systemd/system/pocketharbor.service
            systemctl daemon-reload || true
            ok "removed the systemd service"
        fi
        if [ -f "$HOME/.config/systemd/user/pocketharbor.service" ]; then
            systemctl --user disable --now pocketharbor >/dev/null 2>&1 || true
            rm -f "$HOME/.config/systemd/user/pocketharbor.service"
            systemctl --user daemon-reload 2>/dev/null || true
            ok "removed the systemd user service"
        fi
    fi
    if [ -f "$DATA/proxy.pid" ]; then
        pid=$(cut -d' ' -f1 "$DATA/proxy.pid")
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            end "$pid"
            ok "stopped the proxy and the dashboard"
        fi
    fi
    # A proxy started by hand, with another data directory in its environment.
    # The dashboard goes away with it.
    for pid in $(pids_of "$INSTALL_DIR/pharbor" serve); do end "$pid"; done

    if [ -x "$INSTALL_DIR/pdock" ]; then
        running=$(PD ps 2>/dev/null | awk 'NR > 1 { print $2 }')
        stopped=0
        for name in $(containers); do
            if [ $PURGE = 1 ]; then
                PD rm -f "$name" >/dev/null 2>&1 && stopped=$((stopped + 1)) || true
            elif printf '%s\n' "$running" | grep -qxF "$name"; then
                # install.sh starts them again.
                PD stop "$name" >/dev/null 2>&1 && stopped=$((stopped + 1)) && printf '%s\n' "$name" >>"$DATA/stopped-by-uninstall"
            fi
        done
        if [ $PURGE = 1 ]; then
            ok "removed $stopped containers"
        elif [ $stopped -gt 0 ]; then
            ok "stopped $stopped running services; installing again starts them"
        fi
    fi
    for pid in $(pids_of "$INSTALL_DIR/pdock" daemon); do end "$pid"; done

    step "Removing"
    for f in "$HOME/.termux/boot/pocketharbor" "$HOME/.termux/boot/pocketdock"; do
        # Only what points at these programs.
        if [ -f "$f" ] && grep -qF "$INSTALL_DIR/p" "$f"; then
            rm -f "$f"
            ok "removed $f"
        fi
    done
    for rc in "$HOME/.profile" "$HOME/.bashrc" "$HOME/.zshrc"; do forget_lines "$rc"; done
    for program in pharbor pdock; do
        if [ -e "$INSTALL_DIR/$program" ]; then
            rm -f "$INSTALL_DIR/$program"
            ok "removed $INSTALL_DIR/$program"
        fi
    done
    if [ $PURGE = 1 ] && [ -d "$DATA" ]; then
        rm -rf "$DATA"
        ok "deleted the data in $DATA"
    fi
    if [ $PURGE_ENGINE = 1 ] && [ -d "$ENGINE_ROOT" ]; then
        rm -rf "$ENGINE_ROOT"
        ok "deleted the engine's directory $ENGINE_ROOT"
    fi
    # The directory adb installs use, once empty; never a shared one like bin.
    case "$INSTALL_DIR" in */pocketharbor) rmdir "$INSTALL_DIR" 2>/dev/null || true ;; esac

    step "Done"
    if [ $PURGE = 1 ]; then
        say "PocketHarbor is gone."
    else
        say "PocketHarbor is removed. Its data is still in $DATA:"
        say "installing again brings your projects back; delete it with: sh uninstall.sh --purge"
    fi
}

main "$@"
