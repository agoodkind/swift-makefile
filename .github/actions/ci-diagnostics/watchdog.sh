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

# Match on a full-command substring rather than the exact executable name, for a
# process whose comm name differs from its launchd service (for example the
# keychain-authorization agent, which runs as SecurityAgent or authorizationhost
# rather than com.apple.security.agent).
find_first_pid_fuzzy() {
    local pattern="$1"
    local found_pid

    while IFS= read -r found_pid; do
        printf '%s' "$found_pid"
        return
    done < <(pgrep -f "$pattern" 2>/dev/null || true)
}

# Sample one process by exact executable name into its own file. sudo -n so a
# runner without passwordless sudo degrades instead of prompting; all best-effort.
sample_daemon() {
    local label="$1"
    local process_name="$2"
    local tag="$3"
    local out_dir="$4"
    local daemon_pid

    daemon_pid="$(find_first_pid "$process_name")"
    if [[ -n "$daemon_pid" ]]; then
        # shellcheck disable=SC2024
        sudo -n sample "$daemon_pid" 5 -mayDie \
            > "$out_dir/sample-$label-$tag.txt" 2>&1 || true
    fi
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
    local agent_pid

    tag="${pid}-$(date +%Y%m%dT%H%M%S)"
    securityd_pid="$(find_first_pid securityd)"

    sudo -n /usr/bin/spindump -o "$out_dir/spindump-$tag.txt" 5 10 || true
    sample "$pid" 5 -mayDie > "$out_dir/sample-swiftpackage-$tag.txt" 2>&1 || true

    # Sample every daemon in the keychain-authorization chain by name, so a stall
    # can be attributed to whichever one is blocked. securityd (the legacy
    # single-threaded SecurityServer) blocks on a synchronous cross-service reply;
    # sampling its candidate peers names the one it waits on.
    # sudo -n applies only to inspected processes; the runner owns the output files.
    sample_daemon securityd securityd "$tag" "$out_dir"
    sample_daemon trustd trustd "$tag" "$out_dir"
    sample_daemon securitydsystem securityd_system "$tag" "$out_dir"
    sample_daemon applekeystored applekeystored "$tag" "$out_dir"
    sample_daemon endpointsecurityd endpointsecurityd "$tag" "$out_dir"
    sample_daemon secd secd "$tag" "$out_dir"
    sample_daemon trustdagent trustd "$tag" "$out_dir"

    # The keychain-authorization agent hosts the interactive prompt (service
    # com.apple.security.agent) and runs as SecurityAgent or authorizationhost.
    # Match on the command since its comm name is not the service name.
    agent_pid="$(find_first_pid_fuzzy SecurityAgent)"
    if [[ -z "$agent_pid" ]]; then
        agent_pid="$(find_first_pid_fuzzy authorizationhost)"
    fi
    if [[ -n "$agent_pid" ]]; then
        # shellcheck disable=SC2024
        sudo -n sample "$agent_pid" 5 -mayDie \
            > "$out_dir/sample-securityagent-$tag.txt" 2>&1 || true
    fi

    # Name the XPC peer the blocked securityd is waiting on. procinfo lists its
    # live endpoints; dumpstate maps every service to its owning pid. lsof lists
    # its open handles.
    if [[ -n "$securityd_pid" ]]; then
        # shellcheck disable=SC2024
        sudo -n launchctl procinfo "$securityd_pid" \
            > "$out_dir/procinfo-securityd-$tag.txt" 2>&1 || true
        # shellcheck disable=SC2024
        sudo -n lsof -p "$securityd_pid" \
            > "$out_dir/lsof-securityd-$tag.txt" 2>&1 || true
    fi
    # shellcheck disable=SC2024
    sudo -n launchctl dumpstate > "$out_dir/launchctl-dumpstate-$tag.txt" 2>&1 || true

    lsof -p "$pid" > "$out_dir/lsof-swiftpackage-$tag.txt" 2>&1 || true
    # Wait-channel and parentage for the whole security stack in one table. ps with
    # a wchan column plus a multi-term match is not expressible with pgrep.
    # shellcheck disable=SC2009
    ps -axo pid,ppid,stat,wchan,command 2>/dev/null \
        | grep -Ei "securityd|secd|SecurityAgent|authorizationhost|SandboxCheck|trustd|mds|git-credential|swift-package|xcodebuild" \
        > "$out_dir/ps-security-$tag.txt" 2>&1 || true
    nettop -P -x -l 1 > "$out_dir/nettop-$tag.txt" 2>&1 || true
    netstat -an > "$out_dir/netstat-$tag.txt" 2>&1 || true
    # Redact account values from the dump. dump-keychain without -d already omits
    # decrypted secrets; this also drops the per-item account so the uploaded
    # artifact keeps only item class, label, and service, which is what stall
    # diagnosis needs.
    security dump-keychain "$HOME/Library/Keychains/login.keychain-db" 2>&1 \
        | sed -E 's/("acct"<blob>=).*/\1<redacted>/' \
        > "$out_dir/keychain-$tag.txt" || true
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
    # Backstop lifetime. A self-hosted pool runner is a persistent machine reused
    # across jobs, so a path that skips stop.sh's teardown (forced cancellation
    # past the grace window, a crashed job, a runner failure) must not leave this
    # loop or the sibling log stream running forever. Default is well above the
    # 60-minute job timeout.
    local max_runtime="${3:-7200}"
    local start_time
    start_time="$(date +%s)"
    local now
    local current_pid
    local previous_pid=""
    local previous_since=0
    local age
    local captured=""

    mkdir -p "$out_dir"

    while true; do
        now="$(date +%s)"
        if [[ $((now - start_time)) -ge "$max_runtime" ]]; then
            # Reap the sibling log stream too, since stop.sh may never run.
            if [[ -f "$out_dir/logstream.pid" ]]; then
                kill "$(< "$out_dir/logstream.pid")" 2>/dev/null || true
            fi
            exit 0
        fi
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
