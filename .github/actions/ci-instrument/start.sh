#!/usr/bin/env bash

set -uo pipefail

CHILD_PIDS=()

handle_interrupt() {
    local child_pid

    for child_pid in "${CHILD_PIDS[@]}"; do
        kill "$child_pid" 2>/dev/null || true
    done
    exit 130
}

main() {
    local out_dir="$1"
    local helper_root="$2"
    # Backstop lifetime for the background collectors, well above the 60-minute
    # job timeout. A self-hosted pool runner persists across jobs, so nothing here
    # may outlive the job even if stop.sh's teardown never runs.
    local max_runtime="${3:-7200}"
    local subsystem
    local logstream_pid
    local watchdog_pid

    mkdir -p "$out_dir"

    for subsystem in \
        com.apple.securityd \
        com.apple.security \
        com.apple.trustd \
        com.apple.network; do
        sudo -n log config --mode 'level:debug' --subsystem "$subsystem" || true
    done

    # Redact account values. dump-keychain without -d already omits decrypted
    # secrets; this drops the per-item account so the uploaded artifact keeps only
    # item class, label, and service.
    security dump-keychain "$HOME/Library/Keychains/login.keychain-db" 2>&1 \
        | sed -E 's/("acct"<blob>=).*/\1<redacted>/' \
        > "$out_dir/keychain-baseline.txt" || true
    security find-identity -v > "$out_dir/identities-baseline.txt" 2>&1 || true

    nohup /usr/bin/log stream --style syslog \
        --predicate 'process == "swift-package" OR process == "securityd" OR process == "trustd" OR subsystem == "com.apple.securityd" OR subsystem == "com.apple.trustd" OR subsystem == "com.apple.network"' \
        > "$out_dir/logstream.txt" 2>&1 &
    logstream_pid=$!
    CHILD_PIDS+=("$logstream_pid")
    echo "$logstream_pid" > "$out_dir/logstream.pid"

    nohup bash "$helper_root/.github/actions/ci-instrument/watchdog.sh" \
        "$out_dir" 180 "$max_runtime" > "$out_dir/watchdog.log" 2>&1 &
    watchdog_pid=$!
    CHILD_PIDS+=("$watchdog_pid")
    echo "$watchdog_pid" > "$out_dir/watchdog.pid"

    # Independent reaper so both collectors are bounded even if the watchdog dies
    # abnormally and stop.sh never runs. macOS runners have no `timeout`, so use a
    # detached sleep-then-kill.
    nohup bash -c "sleep $max_runtime; kill $logstream_pid $watchdog_pid 2>/dev/null" \
        > /dev/null 2>&1 &

    printf 'CI instrumentation started: logstream_pid=%s watchdog_pid=%s\n' \
        "$logstream_pid" "$watchdog_pid"
}

trap handle_interrupt INT TERM

main "$@"
