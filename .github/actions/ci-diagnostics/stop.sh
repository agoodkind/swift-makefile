#!/usr/bin/env bash

set -uo pipefail

main() {
    local out_dir="$1"
    local name
    local pid_file
    local pid
    local subsystem

    for name in logstream watchdog reaper; do
        pid_file="$out_dir/$name.pid"
        if [[ -f "$pid_file" ]]; then
            pid="$(< "$pid_file")"
            # Only signal a well-formed PID. These files live under the
            # instrumentation's own out_dir, but guard against a malformed or
            # non-numeric value rather than passing it to kill unchecked.
            if [[ "$pid" =~ ^[0-9]+$ ]]; then
                sudo -n kill "$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
            fi
        fi
    done

    # Restore the default log configuration that start.sh raised to debug, so a
    # persistent self-hosted runner does not keep verbose system logging on after
    # the job.
    for subsystem in \
        com.apple.securityd \
        com.apple.security \
        com.apple.Authorization \
        com.apple.trustd \
        com.apple.network; do
        sudo -n log config --reset --subsystem "$subsystem" 2>/dev/null || true
    done

    sleep 2
    ls -la "$out_dir" || true
}

main "$@"
