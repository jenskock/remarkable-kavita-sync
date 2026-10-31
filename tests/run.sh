#!/bin/sh
# Exercise kavita-sync against a local OPDS fixture. POSIX sh.
# The outer invocation also runs shellcheck and repeats the suite under
# BusyBox sh + BusyBox awk.

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

if [ "${1:-}" != "--inner" ]; then
    shellcheck -s sh \
        "$ROOT/kavita-sync" \
        "$ROOT/install.sh" \
        "$ROOT/uninstall.sh" \
        "$ROOT/lib/util.sh" \
        "$ROOT/lib/http.sh" \
        "$ROOT/lib/sync.sh" \
        "$ROOT/tests/run.sh"
    "$0" --inner
    awkdir=$(mktemp -d)
    cat > "$awkdir/awk" <<'EOF'
#!/bin/sh
exec busybox awk "$@"
EOF
    chmod 755 "$awkdir/awk"
    PATH="$awkdir:$PATH" KAVITA_TEST_SH="busybox sh" SKIP_INSTALL=1 SKIP_WGET=1 "$0" --inner
    rm -rf "$awkdir"
    exit 0
fi

if [ -z "${KAVITA_TEST_SH:-}" ]; then
    KAVITA_TEST_SH=/bin/sh
fi

WORK=$(mktemp -d)
ERR=$WORK/err
OUT=$WORK/out
CONTROL=$WORK/control
mkdir -p "$CONTROL"
: > "$CONTROL/stats.tsv"
printf '1\n' > "$CONTROL/version"
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
python3 "$ROOT/tests/mock_opds.py" "$PORT" "$CONTROL" >/dev/null 2>&1 &
MOCK_PID=$!

finish_tests() {
    if [ -n "${MOCK_PID:-}" ]; then
        kill "$MOCK_PID" >/dev/null 2>&1 || true
        wait "$MOCK_PID" >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK"
}
trap finish_tests EXIT INT TERM

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    printf '%s\n' '--- stdout ---' >&2
    cat "$OUT" >&2 2>/dev/null || true
    printf '%s\n' '--- stderr ---' >&2
    cat "$ERR" >&2 2>/dev/null || true
    exit 1
}

wait_health() {
    local i
    i=0
    while [ "$i" -lt 50 ]; do
        if curl -sf -o /dev/null "http://127.0.0.1:$PORT/health"; then
            return 0
        fi
        i=$((i + 1))
        sleep 0.05
    done
    fail "mock server did not start"
}

reset_control() {
    rm -f "$CONTROL/fail-libraries" "$CONTROL/fail-chapter-100" "$CONTROL/include-evil"
    printf '%s\n' "$1" > "$CONTROL/version"
}

hits() {
    local code part
    code=$1
    part=$2
    awk -F '\t' -v c="$code" -v p="$part" '
        $1 == c && index($2, p) > 0 { n++ }
        END { print n + 0 }
    ' "$CONTROL/stats.tsv"
}

sync_run() {
    local want allow_stdout rc
    want=$1
    shift
    allow_stdout=0
    if [ "${1:-}" = "--allow-stdout" ]; then
        allow_stdout=1
        shift
    fi
    set +e
    # shellcheck disable=SC2086
    env KAVITA_RETRY_SLEEP=0 $KAVITA_TEST_SH "$ROOT/kavita-sync" "$@" >"$OUT" 2>"$ERR"
    rc=$?
    set -e
    if [ "$rc" != "$want" ]; then
        fail "exit $rc, want $want"
    fi
    if [ "$allow_stdout" != 1 ] && [ -s "$OUT" ]; then
        fail "unexpected stdout"
    fi
    if grep -F -q -- "test-key" "$ERR"; then
        fail "API key leaked into the log"
    fi
}

write_cfg() {
    local cfg dest state layout
    cfg=$1
    dest=$2
    state=$3
    layout=$4
    cat > "$cfg" <<EOF
SERVER_URL=http://127.0.0.1:$PORT
API_KEY=test-key
DEST=$dest
LAYOUT=$layout
STATE_DIR=$state
DELETE_MISSING=0
USER_AGENT=kavita-sync-test
INSECURE=0
EOF
}

tree_of() {
    python3 - "$1" <<'PY'
import os, sys
root = sys.argv[1]
rows = []
if os.path.isdir(root):
    for dirpath, dirs, files in os.walk(root):
        dirs.sort()
        for name in sorted(files):
            rows.append(os.path.relpath(os.path.join(dirpath, name), root))
print("\n".join(rows))
PY
}

assert_tree() {
    local got
    got=$(tree_of "$1")
    if [ "$got" != "$2" ]; then
        printf 'tree mismatch\nwant:\n%s\ngot:\n%s\n' "$2" "$got" >&2
        fail "tree"
    fi
}

read_file() {
    python3 -c 'import pathlib,sys; sys.stdout.write(pathlib.Path(sys.argv[1]).read_bytes().decode())' "$1"
}

# --- parser and pure helpers ---
parser_out=$WORK/parsed
LC_ALL=C awk -f "$ROOT/lib/opds.awk" "$ROOT/tests/fixtures/feed.xml" > "$parser_out"
tr -d '\n\r' < "$ROOT/tests/fixtures/feed.xml" > "$WORK/mini.xml"
LC_ALL=C awk -f "$ROOT/lib/opds.awk" "$WORK/mini.xml" > "$WORK/parsed.mini"
if ! cmp -s "$parser_out" "$WORK/parsed.mini"; then
    fail "minified feed did not parse like the pretty feed"
fi
books=$(awk -v US="$(printf '\037')" 'BEGIN{FS=US} $1=="BOOK"{n++} END{print n+0}' "$parser_out")
navs=$(awk -v US="$(printf '\037')" 'BEGIN{FS=US} $1=="NAV"{n++} END{print n+0}' "$parser_out")
nexts=$(awk -v US="$(printf '\037')" 'BEGIN{FS=US} $1=="NEXT"{n++} END{print n+0}' "$parser_out")
[ "$books" = 2 ] || fail "parser book count $books"
[ "$navs" = 1 ] || fail "parser nav count $navs"
[ "$nexts" = 1 ] || fail "parser next count $nexts"
author=$(awk -v US="$(printf '\037')" 'BEGIN{FS=US} $1=="BOOK" && $2=="200"{print $4}' "$parser_out")
python3 -c 'import sys; assert sys.argv[1]=="Jörg & Söhne", sys.argv[1]' "$author" || fail "author entity"
title=$(awk -v US="$(printf '\037')" 'BEGIN{FS=US} $1=="BOOK" && $2=="200"{print $3}' "$parser_out")
python3 -c 'import sys; assert sys.argv[1]=="Über den Berg", sys.argv[1]' "$title" || fail "title entity"
grep -q 'pageNumber=2' "$parser_out" || fail "missing next href"
grep -q 'chapter/100/download' "$parser_out" || fail "missing acquisition link"
grep -q 'opds-pse/stream' "$parser_out" && fail "stream link was treated as a book"

# shellcheck disable=SC1091
. "$ROOT/lib/util.sh"
API_KEY=test-key
SERVER_URL=http://127.0.0.1:9
san=$(sanitize_component 'a/b:c*?"<>|' 'x')
[ "$san" = "a-b-c------" ] || fail "sanitize got $san"
san=$(sanitize_component '  ..hidden  ' 'x')
[ "$san" = "hidden" ] || fail "sanitize dots got $san"
dec=$(urldecode '%43%20')
[ "$dec" = "C " ] || fail "urldecode got [$dec]"
[ "$(classify_url "http://127.0.0.1:9/api/opds/test-key/libraries/12")" = "library" ] || fail "classify library"
[ "$(classify_url "http://127.0.0.1:9/api/opds/test-key/series/12")" = "series" ] || fail "classify series"
[ "$(classify_url "http://127.0.0.1:9/api/opds/test-key/series/12/volume/1/chapter/3")" = "nested" ] || fail "classify chapter"
[ "$(classify_url "http://127.0.0.1:9/api/opds/test-key/series/12/volume/1/chapter/3/download/Nested.cbz")" = "download" ] || fail "classify download"
[ "$(book_key "/api/opds/test-key/series/10/volume/1/chapter/101/download/A.epub" 101)" = "s10/v1/c101" ] || fail "book key"

if [ "${SKIP_INSTALL:-}" != 1 ]; then
    iprefix=$WORK/inst
    mkdir -p "$iprefix"
    SYSTEMD_UNIT_DIR=$WORK/units
    export SYSTEMD_UNIT_DIR
    mkdir -p "$SYSTEMD_UNIT_DIR"
    sh "$ROOT/install.sh" --prefix "$iprefix" --timer >/dev/null 2>&1
    sh "$ROOT/install.sh" --prefix "$iprefix" --timer >/dev/null 2>&1
    [ -x "$iprefix/kavita-sync/kavita-sync" ] || fail "install missing script"
    [ -L "$iprefix/.local/bin/kavita-sync" ] || fail "install missing symlink"
    [ -f "$iprefix/.config/kavita-sync.conf" ] || fail "install missing config"
    [ -f "$WORK/units/kavita-sync.timer" ] || fail "timer unit missing"
    grep -q "$iprefix/kavita-sync/kavita-sync" "$WORK/units/kavita-sync.service" || fail "service path"
    printf 'API_KEY=keep-this\nSERVER_URL=https://books.jenskock.de\nDEST=/tmp/books\n' > "$iprefix/.config/kavita-sync.conf"
    sh "$ROOT/install.sh" --prefix "$iprefix" >/dev/null 2>&1
    grep -q 'keep-this' "$iprefix/.config/kavita-sync.conf" || fail "install rewrote config"
    markers=$(grep -c 'kavita-sync PATH begin' "$iprefix/.profile")
    [ "$markers" = 1 ] || fail "PATH block duplicated ($markers)"
    printf 'keep-book\n' > "$iprefix/plato-media/keep.txt"
    sh "$ROOT/uninstall.sh" --prefix "$iprefix" >/dev/null 2>&1
    [ ! -d "$iprefix/kavita-sync" ] || fail "uninstall left scripts"
    [ -f "$iprefix/plato-media/keep.txt" ] || fail "uninstall removed books"
    [ -f "$iprefix/.config/kavita-sync.conf" ] || fail "uninstall removed config"
    sh "$ROOT/install.sh" --prefix "$iprefix" >/dev/null 2>&1
    sh "$ROOT/uninstall.sh" --prefix "$iprefix" --purge-config --purge-state >/dev/null 2>&1
    [ ! -f "$iprefix/.config/kavita-sync.conf" ] || fail "purge-config kept config"
    www=$WORK/www
    mkdir -p "$www"
    printf 'not-a-real-wget\n' > "$www/wget.bin"
    good=$(sha256sum "$www/wget.bin" | awk '{print $1}')
    wport=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
    WWW=$www python3 - "$wport" <<'PY' >/dev/null 2>&1 &
import os, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
root = os.environ["WWW"]
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        data = open(os.path.join(root, "wget.bin"), "rb").read()
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *args):
        return
ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
    wpid=$!
    i=0
    while [ "$i" -lt 50 ]; do
        if curl -sf -o /dev/null "http://127.0.0.1:$wport/wget.bin"; then
            break
        fi
        i=$((i + 1))
        sleep 0.05
    done
    wprefix=$WORK/wprefix
    mkdir -p "$wprefix"
    if KAVITA_FETCH_WGET_URL="http://127.0.0.1:$wport/wget.bin" \
        KAVITA_FETCH_WGET_SHA256=deadbeef \
        sh "$ROOT/install.sh" --prefix "$wprefix" --fetch-wget >/dev/null 2>"$ERR"; then
        fail "bad checksum was accepted"
    fi
    [ ! -x "$wprefix/.local/bin/wget" ] || fail "bad wget was installed"
    KAVITA_FETCH_WGET_URL="http://127.0.0.1:$wport/wget.bin" \
        KAVITA_FETCH_WGET_SHA256="$good" \
        sh "$ROOT/install.sh" --prefix "$wprefix" --fetch-wget >/dev/null 2>&1
    [ -x "$wprefix/.local/bin/wget" ] || fail "static wget was not installed"
    got=$(sha256sum "$wprefix/.local/bin/wget" | awk '{print $1}')
    [ "$got" = "$good" ] || fail "installed wget checksum"
    kill "$wpid" >/dev/null 2>&1 || true
    wait "$wpid" >/dev/null 2>&1 || true
    unset SYSTEMD_UNIT_DIR
fi

wait_health
sync_run 0 --allow-stdout --help
sync_run 2 --config "$WORK/missing.conf"

EXPECTED=$(printf '%s\n' \
    "Comics/Nested Comic/Nested.cbz" \
    "Romane/Die Verwandlung/Die Verwandlung-c101.epub" \
    "Romane/Die Verwandlung/Die Verwandlung.epub" \
    "Romane/Über den Berg/Über den Berg.epub")

cfg=$WORK/kavita-sync.conf
dest=$WORK/books
state=$WORK/state
write_cfg "$cfg" "$dest" "$state" library-series
reset_control 1

sync_run 0 --config "$cfg" --dry-run
[ ! -d "$dest" ] || [ -z "$(find "$dest" -type f -print)" ] || fail "dry-run wrote files"
grep -q 'would download' "$ERR" || fail "dry-run did not list downloads"
[ "$(hits 200 /download/)" = 0 ] || fail "dry-run downloaded a book"

sync_run 0 --config "$cfg"
assert_tree "$dest" "$EXPECTED"
[ "$(read_file "$dest/Romane/Die Verwandlung/Die Verwandlung.epub")" = "EPUB-100-v1" ] || fail "epub body"
[ "$(read_file "$dest/Romane/Die Verwandlung/Die Verwandlung-c101.epub")" = "EPUB-101-v1" ] || fail "collision body"
[ "$(read_file "$dest/Romane/Über den Berg/Über den Berg.epub")" = "EPUB-11-v1" ] || fail "unicode body"
[ "$(read_file "$dest/Comics/Nested Comic/Nested.cbz")" = "CBZ-12-v1" ] || fail "cbz body"
[ "$(hits 200 /chapter/100/download/)" = 1 ] || fail "duplicate chapter downloaded twice"
find "$dest" -name '*.partial.*' -print | grep -q . && fail "partial file left behind"
[ "$(stat -c %a "$state/manifest.tsv")" = "600" ] || fail "manifest mode"

before100=$(hits 200 /chapter/100/download/)
sync_run 0 --config "$cfg"
[ "$(hits 200 /chapter/100/download/)" = "$before100" ] || fail "unchanged book was downloaded again"
[ "$(hits 304 /chapter/100/download/)" -ge 1 ] || fail "no 304 for unchanged book"
grep -q 'unchanged ' "$ERR" || fail "missing unchanged log"
[ "$(read_file "$dest/Romane/Die Verwandlung/Die Verwandlung.epub")" = "EPUB-100-v1" ] || fail "304 clobbered file"

sync_run 0 --config "$cfg" --force
[ "$(hits 200 /chapter/100/download/)" -gt "$before100" ] || fail "force did not redownload"

reset_control 2
sync_run 0 --config "$cfg"
[ "$(read_file "$dest/Romane/Über den Berg/Über den Berg.epub")" = "EPUB-11-v2" ] || fail "changed book not updated"
[ -f "$dest/Comics/Nested Comic/Nested.cbz" ] || fail "delete-off removed a book"

sync_run 0 --config "$cfg" --dry-run --delete
[ -f "$dest/Comics/Nested Comic/Nested.cbz" ] || fail "dry-run delete removed a file"
grep -q 'would delete ' "$ERR" || fail "dry-run delete did not say so"

sync_run 0 --config "$cfg" --delete
[ ! -e "$dest/Comics/Nested Comic/Nested.cbz" ] || fail "delete left the removed book"
[ ! -d "$dest/Comics" ] || fail "empty library directory remained"
assert_tree "$dest" "$(printf '%s\n' \
    "Romane/Die Verwandlung/Die Verwandlung-c101.epub" \
    "Romane/Die Verwandlung/Die Verwandlung.epub" \
    "Romane/Über den Berg/Über den Berg.epub")"

# A failed catalogue must not delete tracked books.
safe=$WORK/safe-books
safe_state=$WORK/safe-state
write_cfg "$cfg" "$safe" "$safe_state" library-series
reset_control 1
sync_run 0 --config "$cfg"
reset_control 2
touch "$CONTROL/fail-libraries"
sync_run 1 --config "$cfg" --delete
[ -f "$safe/Comics/Nested Comic/Nested.cbz" ] || fail "failed sync deleted a book"
grep -q 'not deleting' "$ERR" || fail "missing delete skip warning"
rm -f "$CONTROL/fail-libraries"

# One bad file must not leave a partial or wipe the rest.
bad=$WORK/bad-books
bad_state=$WORK/bad-state
write_cfg "$cfg" "$bad" "$bad_state" library-series
reset_control 1
touch "$CONTROL/fail-chapter-100"
sync_run 1 --config "$cfg"
[ ! -e "$bad/Romane/Die Verwandlung/Die Verwandlung.epub" ] || fail "failed chapter was stored"
[ -f "$bad/Comics/Nested Comic/Nested.cbz" ] || fail "other books skipped after an error"
find "$bad" -name '*.partial.*' -print | grep -q . && fail "partial left after error"
rm -f "$CONTROL/fail-chapter-100"

# Off-host redirect must not be followed.
evil=$WORK/evil-books
evil_state=$WORK/evil-state
write_cfg "$cfg" "$evil" "$evil_state" library-series
reset_control 1
touch "$CONTROL/include-evil"
sync_run 1 --config "$cfg"
grep -q 'refusing redirect' "$ERR" || fail "off-host redirect was not refused"
[ ! -e "$evil/Evil/Stolen/stolen.epub" ] || fail "redirected book was saved"
rm -f "$CONTROL/include-evil"

# Author/series folders.
layout=$WORK/layout-books
layout_state=$WORK/layout-state
write_cfg "$cfg" "$layout" "$layout_state" author-series
reset_control 1
sync_run 0 --config "$cfg"
[ -f "$layout/Franz Kafka/Die Verwandlung/Die Verwandlung.epub" ] || fail "author-series layout"
[ -f "$layout/Jörg & Söhne/Über den Berg/Über den Berg.epub" ] || fail "author layout unicode"
[ -f "$layout/Ada Lovelace/Nested Comic/Nested.cbz" ] || fail "nested author layout"

# Wrong key.
badkey=$WORK/badkey.conf
write_cfg "$badkey" "$WORK/nowhere" "$WORK/nostate" library-series
sed 's/^API_KEY=.*/API_KEY=wrong-key/' "$badkey" > "$WORK/badkey2.conf"
sync_run 1 --config "$WORK/badkey2.conf"
grep -q 'access denied' "$ERR" || fail "bad key was not reported"

# Overlapping run.
lock_state=$state
mkdir -p "$lock_state"
(
    flock -n 9 || exit 1
    sleep 20
) 9>"$lock_state/kavita-sync.lock" &
holder=$!
sleep 0.2
write_cfg "$cfg" "$dest" "$lock_state" library-series
sync_run 3 --config "$cfg" --dry-run
kill "$holder" >/dev/null 2>&1 || true
wait "$holder" >/dev/null 2>&1 || true

if [ "${SKIP_WGET:-}" != 1 ]; then
    wdest=$WORK/wget-books
    wstate=$WORK/wget-state
    write_cfg "$cfg" "$wdest" "$wstate" library-series
    reset_control 1
    : > "$CONTROL/stats.tsv"
    KAVITA_HTTP_CLIENT=wget sync_run 0 --config "$cfg"
    assert_tree "$wdest" "$EXPECTED"
    KAVITA_HTTP_CLIENT=wget sync_run 0 --config "$cfg"
    [ "$(hits 304 /chapter/100/download/)" -ge 1 ] || fail "wget did not use conditional GET"
    [ "$(read_file "$wdest/Romane/Die Verwandlung/Die Verwandlung.epub")" = "EPUB-100-v1" ] || fail "wget 304 clobber"

    wrap=$WORK/bin
    mkdir -p "$wrap"
    cat > "$wrap/wget" <<'EOF'
#!/bin/sh
exec busybox wget "$@"
EOF
    chmod 755 "$wrap/wget"
    bdest=$WORK/bb-books
    bstate=$WORK/bb-state
    write_cfg "$cfg" "$bdest" "$bstate" flat
    reset_control 1
    : > "$CONTROL/stats.tsv"
    KAVITA_HTTP_CLIENT=wget KAVITA_WGET="$wrap/wget" sync_run 0 --config "$cfg"
    [ -f "$bdest/Die Verwandlung.epub" ] || fail "busybox wget did not download"
    [ -f "$bdest/Nested.cbz" ] || fail "busybox wget missed nested book"
    KAVITA_HTTP_CLIENT=wget KAVITA_WGET="$wrap/wget" sync_run 0 --config "$cfg"
    [ "$(hits 304 /chapter/3/download/)" -ge 1 ] || fail "busybox wget missed 304"
fi

printf 'ok (%s)\n' "$KAVITA_TEST_SH"
