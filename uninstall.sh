#!/bin/sh
# Remove kavita-sync scripts and the optional timer.
# Books, and by default the config and manifest, are left in place.

set -eu -f

PREFIX=${PREFIX:-/home/root}
PROFILE=${PROFILE:-$PREFIX/.profile}
PURGE_CONFIG=0
PURGE_STATE=0
REMOVE_WGET=0

usage() {
    cat <<'EOF'
Usage: uninstall.sh [--prefix DIR] [--purge-config] [--purge-state] [--remove-wget]

Removes $PREFIX/kavita-sync, the symlink, the PATH block, and systemd units.
Downloaded books are not removed. The config and manifest stay unless you
pass --purge-config or --purge-state.
EOF
}

die() {
    printf 'uninstall.sh: %s\n' "$*" >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        --prefix)
            if [ $# -lt 2 ]; then
                die "--prefix needs a directory"
            fi
            PREFIX=$2
            PROFILE=$PREFIX/.profile
            shift 2
            ;;
        --prefix=*)
            PREFIX=${1#--prefix=}
            PROFILE=$PREFIX/.profile
            shift
            ;;
        --purge-config)
            PURGE_CONFIG=1
            shift
            ;;
        --purge-state)
            PURGE_STATE=1
            shift
            ;;
        --remove-wget)
            REMOVE_WGET=1
            shift
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

case $PREFIX in
    ""|/)
        die "refusing prefix '$PREFIX'"
        ;;
esac

unit_dir=${SYSTEMD_UNIT_DIR:-/etc/systemd/system}
if [ "$unit_dir" = /etc/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now kavita-sync.timer >/dev/null 2>&1 || true
fi
rm -f -- "$unit_dir/kavita-sync.service" "$unit_dir/kavita-sync.timer"

rm -f -- "$PREFIX/.local/bin/kavita-sync"
if [ "$REMOVE_WGET" = 1 ]; then
    rm -f -- "$PREFIX/.local/bin/wget"
fi

if [ -d "$PREFIX/kavita-sync" ]; then
    rm -rf -- "$PREFIX/kavita-sync"
fi

if [ -f "$PROFILE" ]; then
    tmp=$PROFILE.kavita-sync.tmp
    awk '
        BEGIN { skip = 0 }
        $0 == "# kavita-sync PATH begin" { skip = 1; next }
        $0 == "# kavita-sync PATH end" { skip = 0; next }
        skip != 1 { print }
    ' "$PROFILE" > "$tmp"
    mv -f -- "$tmp" "$PROFILE"
fi

if [ "$PURGE_CONFIG" = 1 ]; then
    rm -f -- "$PREFIX/.config/kavita-sync.conf"
fi
if [ "$PURGE_STATE" = 1 ]; then
    rm -rf -- "$PREFIX/.local/share/kavita-sync"
fi

printf 'uninstall.sh: removed scripts from %s\n' "$PREFIX" >&2
printf 'uninstall.sh: books were left in place\n' >&2
