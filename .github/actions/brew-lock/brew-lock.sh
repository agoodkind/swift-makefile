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
            brew "$@" || return $?
            return 0
        fi
        sleep 1
    done

    SWIFT_MK_BREW_LOCK_HELD="${lockdir}"
    brew_status=0
    brew "$@" || brew_status=$?
    swift_mk_release_brew_lock
    return "${brew_status}"
}
