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
    local subsystem
    local logstream_pid
    local watchdog_pid

    mkdir -p "$out_dir"

    for subsystem in \
        com.apple.securityd \
        com.apple.security \
        com.apple.trustd \
        com.apple.network; do
        sudo log config --mode 'level:debug' --subsystem "$subsystem" || true
    done

    security dump-keychain "$HOME/Library/Keychains/login.keychain-db" \
        > "$out_dir/keychain-baseline.txt" 2>&1 || true
    security find-identity -v > "$out_dir/identities-baseline.txt" 2>&1 || true

    nohup /usr/bin/log stream --style syslog \
        --predicate 'process == "swift-package" OR process == "securityd" OR process == "trustd" OR subsystem == "com.apple.securityd" OR subsystem == "com.apple.trustd" OR subsystem == "com.apple.network"' \
        > "$out_dir/logstream.txt" 2>&1 &
    logstream_pid=$!
    CHILD_PIDS+=("$logstream_pid")
    echo "$logstream_pid" > "$out_dir/logstream.pid"

    nohup bash "$helper_root/.github/actions/ci-instrument/watchdog.sh" \
        "$out_dir" 180 > "$out_dir/watchdog.log" 2>&1 &
    watchdog_pid=$!
    CHILD_PIDS+=("$watchdog_pid")
    echo "$watchdog_pid" > "$out_dir/watchdog.pid"

    printf 'CI instrumentation started: logstream_pid=%s watchdog_pid=%s\n' \
        "$logstream_pid" "$watchdog_pid"
}

trap handle_interrupt INT TERM

main "$@"
