#!/usr/bin/env bash

set -uo pipefail

POLL_INTERVAL=5

find_first_pid() {
    local process_name="$1"
    local found_pid

    while IFS= read -r found_pid; do
        printf '%s' "$found_pid"
        return
    done < <(pgrep -x "$process_name" 2>/dev/null || true)
}

find_observed_pid() {
    local current_pid

    current_pid="$(find_first_pid swift-package)"
    if [[ -z "$current_pid" ]]; then
        current_pid="$(find_first_pid xcodebuild)"
    fi
    if [[ -z "$current_pid" ]]; then
        current_pid="$(find_first_pid swift-frontend)"
    fi

    printf '%s' "$current_pid"
}

capture_stall() {
    local pid="$1"
    local out_dir="$2"
    local tag
    local securityd_pid
    local trustd_pid

    tag="${pid}-$(date +%Y%m%dT%H%M%S)"
    securityd_pid="$(find_first_pid securityd)"
    trustd_pid="$(find_first_pid trustd)"

    sudo -n /usr/bin/spindump -o "$out_dir/spindump-$tag.txt" 5 10 || true
    sample "$pid" 5 -mayDie > "$out_dir/sample-swiftpackage-$tag.txt" 2>&1 || true
    # sudo -n applies only to inspected processes; the runner owns the output files.
    if [[ -n "$securityd_pid" ]]; then
        # shellcheck disable=SC2024
        sudo -n sample "$securityd_pid" 5 -mayDie \
            > "$out_dir/sample-securityd-$tag.txt" 2>&1 || true
    fi
    if [[ -n "$trustd_pid" ]]; then
        # shellcheck disable=SC2024
        sudo -n sample "$trustd_pid" 5 -mayDie \
            > "$out_dir/sample-trustd-$tag.txt" 2>&1 || true
    fi
    lsof -p "$pid" > "$out_dir/lsof-swiftpackage-$tag.txt" 2>&1 || true
    if [[ -n "$securityd_pid" ]]; then
        # shellcheck disable=SC2024
        sudo -n lsof -p "$securityd_pid" \
            > "$out_dir/lsof-securityd-$tag.txt" 2>&1 || true
    fi
    nettop -P -x -l 1 > "$out_dir/nettop-$tag.txt" 2>&1 || true
    netstat -an > "$out_dir/netstat-$tag.txt" 2>&1 || true
    security dump-keychain "$HOME/Library/Keychains/login.keychain-db" \
        > "$out_dir/keychain-$tag.txt" 2>&1 || true
    security find-identity -v > "$out_dir/identities-$tag.txt" 2>&1 || true
    {
        curl --max-time 20 -o /dev/null \
            -w '%{http_code} %{time_total}s ip=%{remote_ip}\n' \
            http://ocsp.apple.com || true
        curl -sL --max-time 20 -o /dev/null \
            -w '%{http_code} %{time_total}s ip=%{remote_ip}\n' \
            https://github.com/sparkle-project/Sparkle/releases/download/2.9.4/Sparkle-for-Swift-Package-Manager.zip || true
    } > "$out_dir/reach-$tag.txt" 2>&1
}

main() {
    local out_dir="$1"
    local stall_threshold="${2:-180}"
    local now
    local current_pid
    local previous_pid=""
    local previous_since=0
    local age
    local captured=""

    mkdir -p "$out_dir"

    while true; do
        now="$(date +%s)"
        current_pid="$(find_observed_pid)"

        if [[ -z "$current_pid" ]]; then
            previous_pid=""
        else
            if [[ "$current_pid" != "$previous_pid" ]]; then
                previous_pid="$current_pid"
                previous_since="$now"
            fi

            age=$((now - previous_since))
            if [[ "$age" -ge "$stall_threshold" && ",${captured}," != *",${current_pid},"* ]]; then
                capture_stall "$current_pid" "$out_dir"
                if [[ -z "$captured" ]]; then
                    captured="$current_pid"
                else
                    captured="${captured},${current_pid}"
                fi
                previous_pid=""
            fi
        fi

        sleep "$POLL_INTERVAL"
    done
}

main "$@"
