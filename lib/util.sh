# Shared helpers for kavita-sync. Sourced, not executed.
# shellcheck shell=sh

# Used by the other sourced scripts.
export OIFS="$IFS"
US=$(printf '\037')
export US

log() {
    local level msg
    level=$1
    shift
    case $level in
        debug)
            [ "${VERBOSE:-0}" = 1 ] || return 0
            ;;
        info|warn|error) ;;
        *) ;;
    esac
    msg=$(printf '%s' "$*")
    msg=$(redact "$msg")
    printf '%s %s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$level" "$msg" >&2
}

redact() {
    if [ -z "${API_KEY:-}" ]; then
        printf '%s' "$1"
        return 0
    fi
    printf '%s' "$1" | REDACT_KEY="$API_KEY" awk '
        function scrub(s,    k, out, i) {
            k = ENVIRON["REDACT_KEY"]
            out = ""
            while ((i = index(s, k)) > 0) {
                out = out substr(s, 1, i - 1) "***"
                s = substr(s, i + length(k))
            }
            return out s
        }
        { print scrub($0) }
    '
}

die() {
    log error "$*"
    exit 1
}

usage_die() {
    log error "$*"
    exit 2
}

is_digits() {
    case $1 in
        ""|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

sanitize_component() {
    local text fallback
    text=$1
    fallback=$2
    if [ -z "$fallback" ]; then
        fallback=untitled
    fi
    printf '%s\n' "$text" | LC_ALL=C awk -v fb="$fallback" '
        function ord_init(    i) {
            if (ord_done) return
            ord_done = 1
            for (i = 0; i < 256; i++) ordv[sprintf("%c", i)] = i
        }
        function trunc(s, max,    n, b) {
            ord_init()
            if (length(s) <= max) return s
            n = max
            while (n > 1) {
                b = ordv[substr(s, n, 1)]
                if (b < 128 || b >= 192) break
                n--
            }
            if (n < 1) n = 1
            return substr(s, 1, n)
        }
        function clean(s) {
            gsub(/[[:cntrl:]]/, "", s)
            gsub(/[\/:*?"<>|\\]/, "-", s)
            gsub(/[[:space:]]+/, " ", s)
            gsub(/^[ .]+/, "", s)
            gsub(/[ .]+$/, "", s)
            s = trunc(s, 80)
            gsub(/[ .]+$/, "", s)
            return s
        }
        BEGIN { buf = "" }
        {
            if (NR > 1) buf = buf " "
            buf = buf $0
        }
        END {
            s = clean(buf)
            if (s == "" || s == "." || s == "..") s = clean(fb)
            if (s == "" || s == "." || s == "..") s = "untitled"
            printf "%s", s
        }
    '
}

urldecode() {
    printf '%s' "$1" | LC_ALL=C awk '
        function hexval(h,    i, n, d, c) {
            n = 0
            for (i = 1; i <= length(h); i++) {
                c = toupper(substr(h, i, 1))
                d = index("0123456789ABCDEF", c)
                if (d == 0) return -1
                n = n * 16 + d - 1
            }
            return n
        }
        {
            s = $0
            out = ""
            while (match(s, /%[0-9A-Fa-f][0-9A-Fa-f]/)) {
                out = out substr(s, 1, RSTART - 1)
                cp = hexval(substr(s, RSTART + 1, 2))
                if (cp >= 0) out = out sprintf("%c", cp)
                s = substr(s, RSTART + 3)
            }
            printf "%s", out s
        }
    '
}

ext_for_mime() {
    local mime
    mime=$1
    mime=${mime%%;*}
    mime=$(printf '%s' "$mime" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    case $mime in
        application/epub+zip) printf '.epub' ;;
        application/pdf) printf '.pdf' ;;
        application/x-cbz|application/vnd.comicbook+zip|application/comicbook+zip) printf '.cbz' ;;
        application/x-cbr|application/vnd.comicbook-rar|application/comicbook+rar) printf '.cbr' ;;
        application/x-cbt|application/vnd.comicbook+tar) printf '.cbt' ;;
        application/x-cb7) printf '.cb7' ;;
        application/x-mobipocket-ebook|application/vnd.amazon.ebook|application/x-mobi) printf '.mobi' ;;
        application/vnd.amazon.mobi8-ebook|application/x-azw3) printf '.azw3' ;;
        application/fb2+zip|application/x-fictionbook+xml|application/fb2) printf '.fb2' ;;
        text/plain) printf '.txt' ;;
        application/zip) printf '.zip' ;;
        *) printf '' ;;
    esac
}

safe_filename() {
    local raw fallback mime base ext stem got
    raw=$1
    fallback=$2
    mime=$3
    base=${raw##*/}
    ext=""
    stem=$base
    case $base in
        *.*)
            ext=${base##*.}
            stem=${base%.*}
            case $ext in
                ""|*[!A-Za-z0-9]*|??????*)
                    ext=""
                    stem=$base
                    ;;
            esac
            ;;
    esac
    if [ -z "$ext" ]; then
        got=$(ext_for_mime "$mime")
        ext=${got#.}
    fi
    stem=$(sanitize_component "$stem" "")
    if [ "$stem" = "untitled" ] && [ -n "$fallback" ]; then
        stem=$(sanitize_component "$fallback" "book")
    fi
    if [ -n "$ext" ]; then
        printf '%s.%s' "$stem" "$ext"
    else
        printf '%s' "$stem"
    fi
}

build_rel() {
    local lib ser aut file rel
    lib=$(sanitize_component "$1" "Library")
    ser=$(sanitize_component "$2" "Series")
    aut=$(sanitize_component "$3" "Unknown")
    file=$4
    case $LAYOUT in
        flat) rel=$file ;;
        series) rel=$ser/$file ;;
        author) rel=$aut/$file ;;
        author-series) rel=$aut/$ser/$file ;;
        library) rel=$lib/$file ;;
        library-series) rel=$lib/$ser/$file ;;
        library-author-series) rel=$lib/$aut/$ser/$file ;;
        *)
            die "unknown LAYOUT '$LAYOUT'"
            ;;
    esac
    case $rel in
        /*|..|*../*|*/..)
            die "refusing unsafe path"
            ;;
    esac
    printf '%s' "$rel"
}

suffix_rel() {
    local rel extra stem ext dir name
    rel=$1
    extra=$2
    case $rel in
        *.*)
            stem=${rel%.*}
            ext=${rel##*.}
            dir=${stem%/*}
            name=${stem##*/}
            if [ "$dir" = "$stem" ]; then
                printf '%s-%s.%s' "$name" "$extra" "$ext"
            else
                printf '%s/%s-%s.%s' "$dir" "$name" "$extra" "$ext"
            fi
            ;;
        *)
            printf '%s-%s' "$rel" "$extra"
            ;;
    esac
}

key_tag() {
    local t
    t=$1
    t=${t##*/}
    sanitize_component "$t" "dup"
}

reserve_rel() {
    local rel key base n
    rel=$1
    key=$2
    base=$rel
    if [ -f "$WORK/used" ] && grep -F -x -q -- "$rel" "$WORK/used"; then
        rel=$(suffix_rel "$base" "$(key_tag "$key")")
        n=2
        while [ -f "$WORK/used" ] && grep -F -x -q -- "$rel" "$WORK/used"; do
            rel=$(suffix_rel "$base" "$n")
            n=$((n + 1))
            if [ "$n" -gt 50 ]; then
                rel=$(suffix_rel "$base" "$(key_tag "$key-$n")")
                break
            fi
        done
    fi
    printf '%s\n' "$rel" >> "$WORK/used"
    printf '%s' "$rel"
}

url_path() {
    local u rest
    u=${1%%\?*}
    u=${u%%\#*}
    case $u in
        *://*)
            rest=${u#*://}
            case $rest in
                */*) printf '/%s' "${rest#*/}" ;;
                *) printf '/' ;;
            esac
            ;;
        /*) printf '%s' "$u" ;;
        *) printf '/%s' "$u" ;;
    esac
}

url_origin() {
    local u rest host scheme
    u=$1
    case $u in
        https://*|http://*)
            rest=${u#*://}
            host=${rest%%/*}
            scheme=${u%%://*}
            printf '%s://%s' "$scheme" "$host"
            ;;
        *)
            printf '%s' "$SERVER_URL"
            ;;
    esac
}

url_hostport() {
    local u rest host
    u=$1
    case $u in
        https://*|http://*)
            rest=${u#*://}
            host=${rest%%/*}
            host=${host#*@}
            printf '%s' "$host"
            ;;
        *)
            printf ''
            ;;
    esac
}

resolve_against() {
    local base rel dir
    base=$1
    rel=$2
    base=${base%%\#*}
    case $rel in
        https://*|http://*)
            printf '%s' "$rel"
            ;;
        //*)
            case $base in
                https://*) printf 'https:%s' "$rel" ;;
                *) printf 'http:%s' "$rel" ;;
            esac
            ;;
        /*)
            printf '%s%s' "$(url_origin "$base")" "$rel"
            ;;
        *)
            base=${base%%\?*}
            dir=${base%/*}
            printf '%s/%s' "$dir" "$rel"
            ;;
    esac
}

same_origin() {
    local left right scheme_l scheme_r
    left=$(url_hostport "$1")
    right=$(url_hostport "$2")
    scheme_l=${1%%://*}
    scheme_r=${2%%://*}
    [ "$left" = "$right" ] && [ "$scheme_l" = "$scheme_r" ]
}

allows_redirect() {
    local dest
    dest=$1
    case $SERVER_URL in
        https://*)
            case $dest in
                https://*) ;;
                *) return 1 ;;
            esac
            ;;
        http://*)
            case $dest in
                http://*|https://*) ;;
                *) return 1 ;;
            esac
            ;;
        *)
            return 1
            ;;
    esac
    same_origin "$SERVER_URL" "$dest"
}

opds_tail() {
    local p
    p=$(url_path "$1")
    while :; do
        case $p in
            */) p=${p%/} ;;
            *) break ;;
        esac
    done
    case $p in
        */api/opds/"$API_KEY")
            printf ''
            ;;
        */api/opds/"$API_KEY"/*)
            printf '%s' "${p#*/api/opds/"$API_KEY"/}"
            ;;
        *)
            printf 'external'
            ;;
    esac
}

classify_url() {
    local tail id rest sid after vrem vid crem cid
    tail=$(opds_tail "$1")
    case $tail in
        ""|external) printf 'skip'; return ;;
    esac
    case $tail in
        libraries/*)
            id=${tail#libraries/}
            case $id in
                */*) printf 'skip'; return ;;
            esac
            if is_digits "$id"; then
                printf 'library'
            else
                printf 'skip'
            fi
            return
            ;;
        series/*)
            rest=${tail#series/}
            sid=${rest%%/*}
            if ! is_digits "$sid"; then
                printf 'skip'
                return
            fi
            if [ "$rest" = "$sid" ]; then
                printf 'series'
                return
            fi
            after=${rest#*/}
            case $after in
                volume/*) ;;
                *) printf 'skip'; return ;;
            esac
            vrem=${after#volume/}
            vid=${vrem%%/*}
            if ! is_digits "$vid"; then
                printf 'skip'
                return
            fi
            if [ "$vrem" = "$vid" ]; then
                printf 'nested'
                return
            fi
            after=${vrem#*/}
            case $after in
                chapter/*) ;;
                *) printf 'skip'; return ;;
            esac
            crem=${after#chapter/}
            cid=${crem%%/*}
            if ! is_digits "$cid"; then
                printf 'skip'
                return
            fi
            if [ "$crem" = "$cid" ]; then
                printf 'nested'
                return
            fi
            after=${crem#*/}
            case $after in
                download|download/*) printf 'download' ;;
                *) printf 'skip' ;;
            esac
            return
            ;;
        *)
            printf 'skip'
            ;;
    esac
}

book_key() {
    local href id path rest sid tmp vid cid tail
    href=$1
    id=$2
    path=${href%%\?*}
    case $path in
        *"/series/"*)
            rest=${path#*"/series/"}
            sid=${rest%%/*}
            rest=${rest#*/}
            case $rest in
                volume/*/chapter/*/download|volume/*/chapter/*/download/*)
                    tmp=${rest#volume/}
                    vid=${tmp%%/*}
                    tmp=${tmp#*/chapter/}
                    cid=${tmp%%/*}
                    if is_digits "$sid" && is_digits "$vid" && is_digits "$cid"; then
                        printf 's%s/v%s/c%s' "$sid" "$vid" "$cid"
                        return
                    fi
                    ;;
            esac
            ;;
    esac
    tail=$(sanitize_component "$(urldecode "${path##*/}")" "file")
    printf 'id-%s-%s' "$(sanitize_component "$id" "x")" "$tail"
}

load_config() {
    if [ ! -f "$CONFIG" ]; then
        usage_die "config not found: $CONFIG (copy kavita-sync.conf.example)"
    fi
    local line key val
    while IFS= read -r line || [ -n "$line" ]; do
        line=$(printf '%s' "$line" | tr -d '\r')
        case $line in
            ""|\#*) continue ;;
        esac
        case $line in
            *=*) ;;
            *) usage_die "bad config line: $line" ;;
        esac
        key=${line%%=*}
        val=${line#*=}
        key=$(printf '%s' "$key" | tr -d ' ')
        case $key in
            ""|*[!A-Z0-9_]*) usage_die "bad config key: $key" ;;
        esac
        case $val in
            \"*\") val=${val#\"}; val=${val%\"} ;;
            \'*\') val=${val#\'}; val=${val%\'} ;;
        esac
        case $key in
            SERVER_URL) SERVER_URL=$val ;;
            API_KEY) API_KEY=$val ;;
            DEST) DEST=$val ;;
            LAYOUT) LAYOUT=$val ;;
            STATE_DIR) STATE_DIR=$val ;;
            DELETE_MISSING) DELETE_MISSING=$val ;;
            USER_AGENT) USER_AGENT=$val ;;
            CA_CERT) CA_CERT=$val ;;
            INSECURE) INSECURE=$val ;;
            *) log warn "ignoring unknown config key $key" ;;
        esac
    done < "$CONFIG"
}

is_true() {
    case $1 in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

validate_config() {
    if [ -z "${SERVER_URL:-}" ]; then
        usage_die "SERVER_URL is empty"
    fi
    case $SERVER_URL in
        https://*|http://*) ;;
        *) usage_die "SERVER_URL must start with http:// or https://" ;;
    esac
    while :; do
        case $SERVER_URL in
            */) SERVER_URL=${SERVER_URL%/} ;;
            *) break ;;
        esac
    done
    if [ -z "${API_KEY:-}" ]; then
        usage_die "API_KEY is empty. In Kavita: user settings, 3rd party clients / OPDS."
    fi
    case $API_KEY in
        *[!A-Za-z0-9._-]*)
            usage_die "API_KEY contains characters this client will not put in a URL"
            ;;
    esac
    if [ -z "${DEST:-}" ]; then
        usage_die "DEST is empty"
    fi
    case $DEST in
        /*) ;;
        *) usage_die "DEST must be an absolute path" ;;
    esac
    case $DEST in
        /|/home|/home/root|/home/root/)
            usage_die "DEST is too broad; pick a library directory such as /home/root/plato-media"
            ;;
    esac
    if [ -z "${LAYOUT:-}" ]; then
        LAYOUT=library-series
    fi
    case $LAYOUT in
        flat|series|author|author-series|library|library-series|library-author-series) ;;
        *) usage_die "unknown LAYOUT '$LAYOUT'" ;;
    esac
    if [ -z "${STATE_DIR:-}" ]; then
        STATE_DIR=/home/root/.local/share/kavita-sync
    fi
    case $STATE_DIR in
        /*) ;;
        *) usage_die "STATE_DIR must be absolute" ;;
    esac
    if [ -z "${DELETE_MISSING:-}" ]; then
        DELETE_MISSING=0
    fi
    if [ -z "${USER_AGENT:-}" ]; then
        USER_AGENT="Mozilla/5.0 (compatible; kavita-sync/1.0; reMarkable)"
    fi
    if [ -z "${INSECURE:-}" ]; then
        INSECURE=0
    fi
    if [ -z "${CA_CERT:-}" ]; then
        CA_CERT=""
    fi
    if [ -n "$CA_CERT" ] && [ ! -f "$CA_CERT" ]; then
        usage_die "CA_CERT does not exist: $CA_CERT"
    fi
}

acquire_lock() {
    local oldpid
    mkdir -p "$STATE_DIR" || die "cannot create $STATE_DIR"
    chmod 700 "$STATE_DIR" || true
    LOCK_FILE=$STATE_DIR/kavita-sync.lock
    if command -v flock >/dev/null 2>&1; then
        # Hold fd 9 for the life of the process. Do not remove the lock file.
        exec 9>"$LOCK_FILE" || die "cannot open lock"
        if ! flock -n 9; then
            log error "another kavita-sync is already running"
            exit 3
        fi
        LOCK_MODE="flock"
        return 0
    fi
    LOCK_DIR=$STATE_DIR/kavita-sync.lockdir
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        oldpid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
        if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
            log error "another kavita-sync is already running (pid $oldpid)"
            exit 3
        fi
        rm -rf "$LOCK_DIR"
        mkdir "$LOCK_DIR" || {
            log error "another kavita-sync is already running"
            exit 3
        }
    fi
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
    LOCK_MODE="mkdir"
}

release_lock() {
    if [ "${LOCK_MODE:-}" = "mkdir" ] && [ -n "${LOCK_DIR:-}" ]; then
        rm -rf "$LOCK_DIR"
    fi
}

setup_work() {
    if command -v mktemp >/dev/null 2>&1; then
        WORK=$(mktemp -d "$STATE_DIR/work.XXXXXX") || die "mktemp failed"
    else
        WORK=$STATE_DIR/work.$$
        mkdir -p "$WORK" || die "cannot create $WORK"
    fi
    chmod 700 "$WORK" || true
}

cleanup() {
    # Save $? before any other command. `local` would reset it.
    rc=$?
    if [ -n "${WORK:-}" ] && [ -d "$WORK" ]; then
        rm -rf "$WORK"
    fi
    release_lock
    exit "$rc"
}
