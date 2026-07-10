#!/usr/bin/env bash

swift_mk_release_brew_lock() {
    local release_status

    release_status=$?
    if [[ -n "${SWIFT_MK_BREW_LOCK_HELD:-}" ]]; then
        rmdir "${SWIFT_MK_BREW_LOCK_HELD}" 2>/dev/null || true
        SWIFT_MK_BREW_LOCK_HELD=""
    fi
    return "${release_status}"
}

trap swift_mk_release_brew_lock EXIT

swift_mk_brew_output_is_lock_contention() {
    local output
    local matched
    local nocasematch_was_set

    output=$1
    matched=1
    nocasematch_was_set=0
    if shopt -q nocasematch; then
        nocasematch_was_set=1
    fi

    shopt -s nocasematch
    if [[ "${output}" =~ already[[:space:]]+locked ]] \
        || [[ "${output}" =~ another[[:space:]]+active[[:space:]]+homebrew ]] \
        || [[ "${output}" =~ another[[:space:]].*process[[:space:]]+is[[:space:]]+already[[:space:]]+running ]]; then
        matched=0
    fi
    if ((nocasematch_was_set == 0)); then
        shopt -u nocasematch
    fi
    return "${matched}"
}

swift_mk_brew_retry_sleep_seconds() {
    local attempt
    local base_seconds
    local cap_seconds
    local sleep_seconds

    attempt=$1
    base_seconds=${SWIFT_MK_BREW_RETRY_BASE_SECONDS:-10}
    cap_seconds=${SWIFT_MK_BREW_RETRY_CAP_SECONDS:-30}
    sleep_seconds=$((attempt * base_seconds))
    if ((sleep_seconds > cap_seconds)); then
        sleep_seconds=${cap_seconds}
    fi
    printf '%s\n' "${sleep_seconds}"
}

swift_mk_run_brew() {
    case "${1:-}" in
        install | upgrade)
            HOMEBREW_NO_AUTO_UPDATE=1 brew "$@"
            ;;
        *)
            brew "$@"
            ;;
    esac
}

swift_mk_brew_with_retries() {
    local max_attempts
    local max_wait_seconds
    local start_seconds
    local attempt
    local brew_output
    local brew_status
    local sleep_seconds

    max_attempts=${SWIFT_MK_BREW_RETRY_MAX_ATTEMPTS:-6}
    max_wait_seconds=${SWIFT_MK_BREW_RETRY_MAX_WAIT_SECONDS:-180}
    start_seconds=${SECONDS}
    attempt=1

    while ((attempt <= max_attempts)); do
        brew_status=0
        brew_output="$(swift_mk_run_brew "$@" 2>&1)" || brew_status=$?
        if [[ -n "${brew_output}" ]]; then
            printf '%s\n' "${brew_output}" >&2
        fi
        if ((brew_status == 0)); then
            return 0
        fi
        if ! swift_mk_brew_output_is_lock_contention "${brew_output}"; then
            return "${brew_status}"
        fi
        if ((attempt >= max_attempts)); then
            return "${brew_status}"
        fi

        sleep_seconds=$(swift_mk_brew_retry_sleep_seconds "${attempt}")
        if ((SECONDS - start_seconds + sleep_seconds > max_wait_seconds)); then
            return "${brew_status}"
        fi

        printf 'swift-mk: Homebrew lock contention; retrying brew %s in %s seconds (attempt %s/%s)\n' "${1:-command}" "${sleep_seconds}" "$((attempt + 1))" "${max_attempts}" >&2
        sleep "${sleep_seconds}"
        attempt=$((attempt + 1))
    done

    return "${brew_status}"
}

brew_locked() {
    local lockdir
    local timeout_seconds
    local start_seconds
    local brew_status

    lockdir="${SWIFT_MK_BREW_LOCK_DIR:-/tmp/swift-mk-brew.lock.d}"
    timeout_seconds=300
    start_seconds="${SECONDS}"

    while ! mkdir "${lockdir}" 2>/dev/null; do
        if ((SECONDS - start_seconds >= timeout_seconds)); then
            printf 'swift-mk: brew lock timed out after %s seconds; continuing without lock\n' "${timeout_seconds}" >&2
            swift_mk_brew_with_retries "$@"
            return $?
        fi
        sleep 1
    done

    SWIFT_MK_BREW_LOCK_HELD="${lockdir}"
    brew_status=0
    swift_mk_brew_with_retries "$@" || brew_status=$?
    swift_mk_release_brew_lock
    return "${brew_status}"
}

# brew_locked_update refreshes the Homebrew index, but skips the refresh when a
# VM-boot marker says the pool already refreshed it once at prep time. The pool
# broker's clone-runner-slots.sh runs `brew update` once per VM boot and drops
# the marker, so co-tenant slot jobs never run a contending `brew update`.
# Hosted runners have no marker, so they refresh here as before.
brew_locked_update() {
    local marker
    marker="${SWIFT_MK_BREW_BOOT_REFRESH_MARKER:-/tmp/swift-mk-brew-boot-refreshed}"
    if [[ -f "${marker}" ]]; then
        printf 'swift-mk: Homebrew index refreshed at VM boot (%s); skipping brew update\n' "${marker}" >&2
        return 0
    fi
    brew_locked update --quiet
}
