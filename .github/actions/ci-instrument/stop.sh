#!/usr/bin/env bash

set -uo pipefail

main() {
    local out_dir="$1"
    local name
    local pid_file
    local pid

    for name in logstream watchdog; do
        pid_file="$out_dir/$name.pid"
        if [[ -f "$pid_file" ]]; then
            pid="$(< "$pid_file")"
            sudo kill "$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
        fi
    done

    sleep 2
    ls -la "$out_dir" || true
}

main "$@"
