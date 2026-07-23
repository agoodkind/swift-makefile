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
# else mint a fresh id. The chosen traceparent is written under the log directory,
# the header is printed to stderr once per run (guarded by the .run sentinel), and
# `ok <traceparent> <trace> <span>` is printed to stdout for the make caller to
# parse into its exported variables.
#
# Inputs (environment): TRACEPARENT, TRACE_ID, SPAN_ID, SWIFT_MK_TRACE_ID,
# SWIFT_MK_SPAN_ID, SWIFT_MK_SKIP_FETCH, SWIFT_MK_ROOT. The make caller passes its
# own make-var values through the environment so a make-level assignment is honored
# the same as an inherited environment value.

set -euo pipefail

readonly TRACE_HEX_LENGTH=32
readonly SPAN_HEX_LENGTH=16
readonly FLAGS_HEX_LENGTH=2
readonly TRACE_BYTE_COUNT=16
readonly SPAN_BYTE_COUNT=8

# Resolve the run's log directory and print its absolute path. SWIFT_MK_ROOT pins
# the tree to the checkout root when a nested make runs under a package subdir.
resolve_log_dir() {
    local log_dir

    if [[ -n "${SWIFT_MK_ROOT:-}" ]]; then
        log_dir="${SWIFT_MK_ROOT%/}/.make/logs"
    else
        log_dir=".make/logs"
    fi

    mkdir -p "$log_dir"
    # Subshell keeps the caller's cwd unchanged while absolutizing for the header.
    (cd "$log_dir" && pwd)
}

# True when value is exactly expected_length lowercase hex characters.
is_lower_hex() {
    local value=$1
    local expected_length=$2
    local stripped

    if [[ -z "$value" ]]; then
        return 1
    fi
    if [[ ${#value} -ne "$expected_length" ]]; then
        return 1
    fi
    stripped=$(printf '%s' "$value" | tr -d '0123456789abcdef')
    if [[ -n "$stripped" ]]; then
        return 1
    fi
    return 0
}

# True when value is a valid W3C id: lowercase hex of the expected length and not
# all zeros. An all-zero trace-id or span-id is invalid per the W3C trace-context
# spec, so a caller that exports one is treated as having none.
is_valid_id() {
    local value=$1
    local expected_length=$2

    if ! is_lower_hex "$value" "$expected_length"; then
        return 1
    fi
    case "$value" in
        *[!0]*)
            return 0
            ;;
    esac
    return 1
}

# Validate a W3C traceparent and print the same trace and span with flags
# normalized to 01. Any well-formed two-hex flags field is accepted (an unsampled
# 00 is valid), so a valid inbound context is never dropped over the flag byte.
normalize_traceparent() {
    local candidate=$1
    local trace
    local remainder
    local span
    local flags

    trace=${candidate#00-}
    if [[ "$trace" == "$candidate" ]]; then
        return 1
    fi
    trace=${trace%%-*}
    remainder=${candidate#00-"$trace"-}
    if [[ "$remainder" == "$candidate" ]]; then
        return 1
    fi
    span=${remainder%%-*}
    flags=${remainder#"$span"-}
    if ! is_valid_id "$trace" "$TRACE_HEX_LENGTH"; then
        return 1
    fi
    if ! is_valid_id "$span" "$SPAN_HEX_LENGTH"; then
        return 1
    fi
    if ! is_lower_hex "$flags" "$FLAGS_HEX_LENGTH"; then
        return 1
    fi
    if [[ "$candidate" != "00-$trace-$span-$flags" ]]; then
        return 1
    fi
    printf '%s\n' "00-$trace-$span-01"
}

# Emit byte_count random bytes as lowercase hex. Try openssl, then /dev/urandom via
# od, then hexdump, so a fresh macOS or Debian host works before optional tools are
# installed. Each failed source logs once and falls through to the next; there is
# no second soft landing on the same source.
random_hex() {
    local byte_count=$1
    local expected_length=$((byte_count * 2))
    local value=""

    if command -v openssl >/dev/null 2>&1; then
        if value=$(openssl rand -hex "$byte_count"); then
            if is_lower_hex "$value" "$expected_length"; then
                printf '%s' "$value"
                return 0
            fi
            printf 'swift-mk-trace: openssl entropy failed hex validation; trying next source\n' >&2
        else
            printf 'swift-mk-trace: openssl rand failed; trying next source\n' >&2
        fi
    fi

    if [[ -r /dev/urandom ]] && command -v od >/dev/null 2>&1; then
        if value=$(od -An -N "$byte_count" -tx1 /dev/urandom | tr -d ' \n'); then
            if is_lower_hex "$value" "$expected_length"; then
                printf '%s' "$value"
                return 0
            fi
            printf 'swift-mk-trace: od entropy failed hex validation; trying next source\n' >&2
        else
            printf 'swift-mk-trace: od urandom read failed; trying next source\n' >&2
        fi
    fi

    if [[ -r /dev/urandom ]] && command -v hexdump >/dev/null 2>&1; then
        if value=$(hexdump -n "$byte_count" -e '1/1 "%02x"' /dev/urandom); then
            if is_lower_hex "$value" "$expected_length"; then
                printf '%s' "$value"
                return 0
            fi
            printf 'swift-mk-trace: hexdump entropy failed hex validation\n' >&2
        else
            printf 'swift-mk-trace: hexdump urandom read failed\n' >&2
        fi
    fi

    return 1
}

# Split a normalized traceparent into trace and span ids for the header and .run
# sentinel. The caller already validated the string through normalize_traceparent
# or constructed it from validated ids.
ids_from_traceparent() {
    local traceparent=$1
    local trace
    local rest

    trace=${traceparent#00-}
    trace=${trace%%-*}
    rest=${traceparent#00-"$trace"-}
    printf '%s %s\n' "$trace" "${rest%%-*}"
}

main() {
    local log_dir
    local traceparent_file
    local run_file
    local traceparent=""
    local trace=""
    local span=""
    local file_traceparent=""
    local previous_run=""
    local id_pair=""

    log_dir=$(resolve_log_dir)
    traceparent_file="$log_dir/.traceparent"
    run_file="$log_dir/.run"

    if [[ -n "${TRACEPARENT:-}" ]]; then
        if traceparent=$(normalize_traceparent "$TRACEPARENT"); then
            id_pair=$(ids_from_traceparent "$traceparent")
            trace=${id_pair%% *}
            span=${id_pair#* }
        fi
    fi

    if [[ -z "$traceparent" ]] \
        && is_valid_id "${TRACE_ID:-}" "$TRACE_HEX_LENGTH" \
        && is_valid_id "${SPAN_ID:-}" "$SPAN_HEX_LENGTH"; then
        trace=$TRACE_ID
        span=$SPAN_ID
        traceparent="00-$trace-$span-01"
    fi

    if [[ -z "$traceparent" ]] \
        && is_valid_id "${SWIFT_MK_TRACE_ID:-}" "$TRACE_HEX_LENGTH" \
        && is_valid_id "${SWIFT_MK_SPAN_ID:-}" "$SPAN_HEX_LENGTH"; then
        trace=$SWIFT_MK_TRACE_ID
        span=$SWIFT_MK_SPAN_ID
        traceparent="00-$trace-$span-01"
    fi

    if [[ -z "$traceparent" && "${SWIFT_MK_SKIP_FETCH:-}" == "1" && -s "$traceparent_file" ]]; then
        if IFS= read -r file_traceparent <"$traceparent_file"; then
            if traceparent=$(normalize_traceparent "$file_traceparent"); then
                id_pair=$(ids_from_traceparent "$traceparent")
                trace=${id_pair%% *}
                span=${id_pair#* }
            else
                printf 'swift-mk-trace: persisted traceparent is invalid; minting a new id\n' >&2
                traceparent=""
            fi
        else
            printf 'swift-mk-trace: failed to read %s; minting a new id\n' "$traceparent_file" >&2
        fi
    fi

    if [[ -z "$traceparent" ]]; then
        trace=$(random_hex "$TRACE_BYTE_COUNT")
        span=$(random_hex "$SPAN_BYTE_COUNT")
        traceparent="00-$trace-$span-01"
    fi

    if [[ -z "$trace" || -z "$span" ]]; then
        id_pair=$(ids_from_traceparent "$traceparent")
        trace=${id_pair%% *}
        span=${id_pair#* }
    fi

    printf '%s\n' "$traceparent" >"$traceparent_file"

    if [[ -s "$run_file" ]]; then
        if ! IFS= read -r previous_run <"$run_file"; then
            printf 'swift-mk-trace: failed to read %s; treating as a new run\n' "$run_file" >&2
            previous_run=""
        fi
    fi

    if [[ "$previous_run" != "$trace" ]]; then
        printf '%s\n' "$trace" >"$run_file"
        printf '🔎 logs=%s trace_id=%s span_id=%s\n' "$log_dir" "$trace" "$span" >&2
    fi

    printf 'ok %s %s %s\n' "$traceparent" "$trace" "$span"
}

main "$@"
