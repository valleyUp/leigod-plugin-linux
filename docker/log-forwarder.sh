#!/bin/sh
set -eu

readonly LOG_DIR=${LEIGOD_LOG_DIR:-/tmp/acc/log}
readonly LOG_LEVEL=${LEIGOD_LOG_LEVEL:-warn}
readonly REPEAT_LIMIT=60
readonly MAX_LINE_LENGTH=4096

case "$LOG_LEVEL" in
    off) exit 0 ;;
    error) threshold=0 ;;
    warn) threshold=1 ;;
    info) threshold=2 ;;
    debug) threshold=3 ;;
    *)
        printf '[leigod:log] invalid LEIGOD_LOG_LEVEL: %s\n' "$LOG_LEVEL" >&2
        exit 1
        ;;
esac

sanitize() {
    sed -u -E \
        -e 's/("(token|nonce|user_id|password|authorization|cookie|speedSign)"[[:space:]]*:[[:space:]]*")[^"]*"/\1<redacted>"/Ig' \
        -e 's/((token|nonce|user_id|password|authorization|cookie|speedSign)[[:space:]]*[:=][[:space:]]*)[^,;[:space:]]+/\1<redacted>/Ig' \
        -e 's/(Authorization[[:space:]]*:[[:space:]]*(Bearer|Basic)[[:space:]]+)[^[:space:]]+/\1<redacted>/Ig' \
        -e 's/([?&][[:alnum:]_.-]*(token|secret|password|auth|sign|key)[[:alnum:]_.-]*=)[^&[:space:]",;]+/\1<redacted>/Ig' \
        -e "s/^(.{$MAX_LINE_LENGTH}).*$/\\1/"
}

set_line_priority() {
    line=$1
    fallback=$2
    case "$line" in
        *' FATAL '*|*' ERROR '*|*FATAL*|*Fatal*|*fatal*|*ERROR*|*Error*|*error*|*FAILED*|*Failed*|*failed*)
            priority=0
            ;;
        *' WARN '*|*WARN*|*Warn*|*warn*|*Cannot*|*cannot*|*'Bad rule'*|*RTNETLINK*|*ioctl*)
            priority=1
            ;;
        *' DEBUG '*|*DEBUG*|*Debug*|*debug*)
            priority=3
            ;;
        *' INFO '*|*INFO*|*Info*|*info*)
            priority=2
            ;;
        *)
            priority=$fallback
            ;;
    esac
}

self_test() {
    sample='2026-01-01 00:00:00.000 WARN token=plain-secret {"user_id":"42","speedSign":"session-secret"} https://example.invalid/?access_token=query-secret&mode=1'
    safe_sample=$(printf '%s\n' "$sample" | sanitize)
    case "$safe_sample" in
        *plain-secret*|*session-secret*|*query-secret*|*'"42"'*)
            printf '[leigod:log] self-test leaked a protected value\n' >&2
            exit 1
            ;;
    esac
    redaction_count=$(printf '%s\n' "$safe_sample" | grep -o '<redacted>' | wc -l)
    [ "$redaction_count" -eq 4 ] || {
        printf '[leigod:log] self-test expected four redactions, got %s\n' \
            "$redaction_count" >&2
        exit 1
    }
    set_line_priority '2026-01-01 DEBUG test' 2
    [ "$priority" -eq 3 ]
    set_line_priority 'Cannot open device' 2
    [ "$priority" -eq 1 ]
}

if [ "${1:-}" = --self-test ]; then
    self_test
    exit 0
fi

forward_file() {
    source_name=$1
    source_file=$2
    continuation_priority=$3
    previous=
    repeats=0

    tail -n 0 -F "$source_file" 2>/dev/null | sanitize |
    while IFS= read -r safe_line; do
        set_line_priority "$safe_line" "$continuation_priority"
        continuation_priority=$priority
        [ "$priority" -le "$threshold" ] || continue

        case "$safe_line" in
            ????-??-??\ ??:??:??.???\ *)
                fingerprint=${safe_line#????-??-?? ??:??:??.??? }
                ;;
            *) fingerprint=$safe_line ;;
        esac

        if [ -n "$previous" ] && [ "$fingerprint" = "$previous" ]; then
            repeats=$((repeats + 1))
            if [ "$repeats" -ge "$REPEAT_LIMIT" ]; then
                printf '[leigod:%s] previous message repeated %s additional times\n' \
                    "$source_name" "$repeats"
                repeats=0
            fi
            continue
        fi

        if [ "$repeats" -gt 0 ]; then
            printf '[leigod:%s] previous message repeated %s additional times\n' \
                "$source_name" "$repeats"
        fi
        previous=$fingerprint
        repeats=0
        printf '[leigod:%s] %s\n' "$source_name" "$safe_line"
    done
}

mkdir -p "$LOG_DIR"
for log_file in acc_daemon.log acc_PC.log web_api.log console.log; do
    : >> "$LOG_DIR/$log_file"
done

pids=
forward_file daemon "$LOG_DIR/acc_daemon.log" 2 &
pids="$pids $!"
forward_file game "$LOG_DIR/acc_PC.log" 2 &
pids="$pids $!"
forward_file web "$LOG_DIR/web_api.log" 2 &
pids="$pids $!"
forward_file console "$LOG_DIR/console.log" 2 &
pids="$pids $!"

cleanup() {
    trap - EXIT INT TERM
    # pids is populated only with child processes created above.
    kill $pids 2>/dev/null || true
    wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

wait
