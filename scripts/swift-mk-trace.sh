#!/usr/bin/env bash
#
# swift-mk-trace.sh
#
# The full make-time trace bootstrap. The engine swift.mk invokes this once at
# parse time, before any heavy work, so the trace header is the first thing a run
# prints; a consumer bootstrap.mk prints its own minimal header inline (a reduced
# form of this precedence) so it needs no fetch. It runs before the swift-mk binary
# exists, so it stays pure shell with only baseline tools.
#
# It resolves one run correlation and prints it: adopt an inbound W3C TRACEPARENT,
# else the canonical TRACE_ID/SPAN_ID pair, else the SWIFT_MK_TRACE_ID/
# SWIFT_MK_SPAN_ID aliases, else (skip-fetch only) the persisted .traceparent,
# else mint a fresh id. The chosen traceparent is written to .make/logs/.traceparent,
# the header is printed to stderr once per run (guarded by .make/logs/.run), and
# `ok <traceparent> <trace> <span>` is printed to stdout for the make caller to
# parse into its exported variables.
#
# Inputs (environment): TRACEPARENT, TRACE_ID, SPAN_ID, SWIFT_MK_TRACE_ID,
# SWIFT_MK_SPAN_ID, SWIFT_MK_SKIP_FETCH. The make caller passes its own make-var
# values through the environment so a make-level assignment is honored the same as
# an inherited environment value.

set -u

readonly LOG_DIR=".make/logs"
readonly TRACEPARENT_FILE="$LOG_DIR/.traceparent"
readonly RUN_FILE="$LOG_DIR/.run"
readonly TRACE_HEX_LENGTH=32
readonly SPAN_HEX_LENGTH=16
readonly FLAGS_HEX_LENGTH=2
readonly TRACE_BYTE_COUNT=16
readonly SPAN_BYTE_COUNT=8

# True when value is exactly expected_length lowercase hex characters.
is_lower_hex() {
    local value=$1
    local expected_length=$2
    [[ -n "$value" ]] || return 1
    [[ ${#value} -eq "$expected_length" ]] || return 1
    local stripped
    stripped=$(printf '%s' "$value" | tr -d '0123456789abcdef')
    [[ -z "$stripped" ]]
}

# True when value is a valid W3C id: lowercase hex of the expected length and not
# all zeros. An all-zero trace-id or span-id is invalid per the W3C trace-context
# spec, so a caller that exports one is treated as having none.
is_valid_id() {
    is_lower_hex "$1" "$2" || return 1
    case "$1" in
        *[!0]*) return 0 ;;
    esac
    return 1
}

# Validate a W3C traceparent and, on success, set the global `traceparent` to the
# same trace and span with the flags normalized to 01. Any well-formed two-hex
# flags field is accepted (an unsampled 00 is valid), so a valid inbound context
# is never dropped over the flag byte alone.
use_traceparent() {
    local candidate=$1
    local trace=${candidate#00-}
    [[ "$trace" != "$candidate" ]] || return 1
    trace=${trace%%-*}
    local remainder=${candidate#00-"$trace"-}
    [[ "$remainder" != "$candidate" ]] || return 1
    local span=${remainder%%-*}
    local flags=${remainder#"$span"-}
    is_valid_id "$trace" "$TRACE_HEX_LENGTH" || return 1
    is_valid_id "$span" "$SPAN_HEX_LENGTH" || return 1
    is_lower_hex "$flags" "$FLAGS_HEX_LENGTH" || return 1
    [[ "$candidate" = "00-$trace-$span-$flags" ]] || return 1
    traceparent="00-$trace-$span-01"
}

# Emit byte_count random bytes as lowercase hex, trying openssl, then /dev/urandom
# via od, then hexdump, so a fresh macOS or Debian host works before any tool is
# installed. Returns non-zero when none produce a valid hex string.
random_hex() {
    local byte_count=$1
    local expected_length=$(( byte_count * 2 ))
    local value=""
    if command -v openssl >/dev/null 2>&1; then
        value=$(openssl rand -hex "$byte_count" 2>/dev/null || true)
        if is_lower_hex "$value" "$expected_length"; then printf '%s' "$value"; return 0; fi
    fi
    if [[ -r /dev/urandom ]] && command -v od >/dev/null 2>&1; then
        value=$(od -An -N "$byte_count" -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
        if is_lower_hex "$value" "$expected_length"; then printf '%s' "$value"; return 0; fi
    fi
    if [[ -r /dev/urandom ]] && command -v hexdump >/dev/null 2>&1; then
        value=$(hexdump -n "$byte_count" -e '1/1 "%02x"' /dev/urandom 2>/dev/null)
        if is_lower_hex "$value" "$expected_length"; then printf '%s' "$value"; return 0; fi
    fi
    return 1
}

main() {
    local traceparent=""
    local trace=""
    local span=""

    mkdir -p "$LOG_DIR" || exit 1

    if use_traceparent "${TRACEPARENT:-}"; then
        :
    elif is_valid_id "${TRACE_ID:-}" "$TRACE_HEX_LENGTH" \
        && is_valid_id "${SPAN_ID:-}" "$SPAN_HEX_LENGTH"; then
        trace=$TRACE_ID
        span=$SPAN_ID
        traceparent="00-$trace-$span-01"
    elif is_valid_id "${SWIFT_MK_TRACE_ID:-}" "$TRACE_HEX_LENGTH" \
        && is_valid_id "${SWIFT_MK_SPAN_ID:-}" "$SPAN_HEX_LENGTH"; then
        trace=$SWIFT_MK_TRACE_ID
        span=$SWIFT_MK_SPAN_ID
        traceparent="00-$trace-$span-01"
    elif [[ "${SWIFT_MK_SKIP_FETCH:-}" = "1" && -s "$TRACEPARENT_FILE" ]]; then
        local file_traceparent
        IFS= read -r file_traceparent < "$TRACEPARENT_FILE" || file_traceparent=""
        use_traceparent "$file_traceparent" || traceparent=""
    fi

    if [[ -z "$traceparent" ]]; then
        trace=$(random_hex "$TRACE_BYTE_COUNT") || exit 1
        span=$(random_hex "$SPAN_BYTE_COUNT") || exit 1
        traceparent="00-$trace-$span-01"
    fi

    # When a traceparent was adopted, recover its trace/span for the header and the
    # .run guard, since the id branches set them but the adopt branches do not.
    if [[ -z "$trace" ]]; then
        trace=${traceparent#00-}
        trace=${trace%%-*}
        local rest=${traceparent#00-"$trace"-}
        span=${rest%%-*}
    fi

    printf '%s\n' "$traceparent" > "$TRACEPARENT_FILE" || exit 1

    local previous_run=""
    if [[ -s "$RUN_FILE" ]]; then
        IFS= read -r previous_run < "$RUN_FILE" || previous_run=""
    fi
    if [[ "$previous_run" != "$trace" ]]; then
        printf '%s\n' "$trace" > "$RUN_FILE" || exit 1
        printf '🔎 logs=%s trace_id=%s span_id=%s\n' "$LOG_DIR" "$trace" "$span" >&2
    fi

    printf 'ok %s %s %s\n' "$traceparent" "$trace" "$span"
}

main "$@"
