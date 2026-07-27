#!/usr/bin/env bash
# swift-mk-bootstrap.sh: provision the swift-makefile engine snapshot into .make.
#
# bootstrap.mk delegates here so fetch policy lives in a fetched file rather
# than in the copy each consumer commits. A policy change therefore ships to
# every consumer on its next parse, with no consumer pull request.
#
# Provisioning is staged: one tarball extracts into a temp directory, the
# required assets are verified there, and only then is the tree under .make
# replaced. Nothing is removed before its replacement exists.
#
# This script lives inside the tree it replaces, so it re-executes from a
# temporary copy before touching .make. A running bash script whose file is
# rewritten underneath it can misread its own remaining bytes.

set -euo pipefail

SWIFT_MK_API_REPO="${SWIFT_MK_API_REPO:-agoodkind/swift-makefile}"
SWIFT_MK_API_REF="${SWIFT_MK_API_REF:-main}"
# Internal override, in the same category as SWIFT_MK_API_REPO and
# SWIFT_MK_API_REF. Tests point it at a local server; consumers never set it.
SWIFT_MK_CODELOAD_BASE="${SWIFT_MK_CODELOAD_BASE:-https://codeload.github.com}"
SWIFT_MK_DEV_DIR="${SWIFT_MK_DEV_DIR:-}"
SWIFT_MK_MODULES="${SWIFT_MK_MODULES:-}"

MAKE_DIR=".make"
FETCH_MAX_TIME=60
MARKER_PATH="${MAKE_DIR}/.swift-mk-snapshot-ref"
VALIDATION_CONNECT_TIMEOUT=2
VALIDATION_MAX_TIME=3
REUSE_WINDOW_SECONDS=3600

# Re-execute from a temp copy so replacing this file mid-run is safe. The guard
# variable stops the copy from re-executing itself.
reexec_from_temp_copy() {
    local temp_copy
    if [[ -n "${SWIFT_MK_BOOTSTRAP_REEXEC:-}" ]]; then
        return 0
    fi
    temp_copy=$(mktemp "${TMPDIR:-/tmp}/swift-mk-bootstrap.XXXXXXXX") || return 1
    cp "$0" "${temp_copy}"
    chmod +x "${temp_copy}"
    SWIFT_MK_BOOTSTRAP_REEXEC=1 exec bash "${temp_copy}" "$@"
}

# A single-line, length-capped excerpt of a captured stderr log, so a failure
# message carries a concrete reason (a 403 body, a DNS error, a tar format
# complaint) instead of one generic sentence for every kind of failure.
stderr_sample() {
    tr '\n' ' ' < "$1" | cut -c1-200
}

required_assets() {
    printf '%s\n' "swift.mk"
    printf '%s\n' "Package.swift"
    printf '%s\n' "scripts/swift-mk-build.sh"
    local module_name
    for module_name in ${SWIFT_MK_MODULES}; do
        printf '%s\n' "${module_name}"
    done
}

assets_complete() {
    local base_dir="$1"
    local asset_name
    local asset_path
    while IFS= read -r asset_name; do
        asset_path="${base_dir}/${asset_name}"
        # -s alone is true for a non-empty directory as well as a file, so a
        # required asset path that is actually a directory would pass. -f
        # requires it to be a regular file.
        if [[ ! -f "${asset_path}" || ! -s "${asset_path}" ]]; then
            return 1
        fi
    done < <(required_assets)
    return 0
}

# stage_fetch_and_verify downloads the pinned ref's archive into stage_root and
# extracts it into stage_dir. Every failure path prints the exit code and a
# short stderr excerpt from the command that actually failed, so a 403, a DNS
# failure, and a corrupt tarball each leave a distinct diagnostic instead of
# one generic message. Nothing under .make is touched here.
stage_fetch_and_verify() {
    local stage_root="$1"
    local stage_dir="$2"
    local url="${SWIFT_MK_CODELOAD_BASE}/${SWIFT_MK_API_REPO}/tar.gz/${SWIFT_MK_API_REF}"
    local curl_log="${stage_root}/curl.log"
    local tar_log="${stage_root}/tar.log"
    local status_code
    local curl_status=0
    local tar_status=0

    status_code=$(curl -sS --connect-timeout 5 --max-time "${FETCH_MAX_TIME}" \
        -D "${stage_root}/headers" \
        -o "${stage_root}/snapshot.tar.gz" -w '%{http_code}' \
        "${url}" 2>"${curl_log}") || curl_status=$?
    if [[ ${curl_status} -ne 0 ]]; then
        printf 'error: fetch failed (curl exit %d) for %s: %s\n' \
            "${curl_status}" "${url}" "$(stderr_sample "${curl_log}")" >&2
        return 1
    fi
    if [[ "${status_code}" != "200" ]]; then
        printf 'error: fetch returned HTTP %s for %s\n' "${status_code}" "${url}" >&2
        return 1
    fi

    if ! mkdir -p "${stage_dir}"; then
        printf 'error: could not create %s\n' "${stage_dir}" >&2
        return 1
    fi
    tar -xzf "${stage_root}/snapshot.tar.gz" -C "${stage_dir}" --strip-components 1 \
        2>"${tar_log}" || tar_status=$?
    if [[ ${tar_status} -ne 0 ]]; then
        printf 'error: tar extraction failed (exit %d): %s\n' \
            "${tar_status}" "$(stderr_sample "${tar_log}")" >&2
        return 1
    fi
    if ! assets_complete "${stage_dir}"; then
        printf 'error: fetched snapshot is missing a required asset\n' >&2
        return 1
    fi
    return 0
}

# install_from_stage assembles the verified staged tree next to .make,
# bringing forward the generated runtime files a build depends on (the same
# set snapshot_clear_engine preserves in scripts/swift-mk-sync.sh), then swaps
# it into place with mv. Nothing under .make is removed until the replacement
# is fully staged and verified, so a cp that fails partway, or any other
# failure before the final mv, leaves the existing .make exactly as it was.
#
# This function runs inside provision's `if provision; then` condition, and
# bash suppresses -e for the entire duration of a command used as an if/while
# condition, including every function and subshell called from it. -e cannot
# be relied on here at all: every step below that can fail is checked
# explicitly and returns 1 itself, rather than assuming an unguarded command
# would abort the function.
install_from_stage() {
    local stage_dir="$1"
    local next_dir="${MAKE_DIR}.next"
    local previous_dir="${MAKE_DIR}.previous"
    local cp_log
    local cp_status=0
    local clear_log
    local clear_status=0
    local preserved_path
    cp_log="$(dirname "${stage_dir}")/install-cp.log"
    clear_log="$(dirname "${stage_dir}")/clear-stage.log"

    # If this rm fails partway (a locked or immutable file left over from a
    # previous run), a stale next_dir would still exist. mkdir -p would then
    # succeed against it unchanged, cp -R would add every new file alongside
    # whatever survived, and both assets_complete checks below would still
    # pass, since every required asset is present, swapping a .make carrying
    # orphaned stale content into place with exit 0. Checking the status here
    # is what stops that.
    rm -rf "${next_dir}" "${previous_dir}" 2>"${clear_log}" || clear_status=$?
    if [[ ${clear_status} -ne 0 ]]; then
        printf 'error: could not clear stale staging directories %s and %s (rm exit %d): %s\n' \
            "${next_dir}" "${previous_dir}" "${clear_status}" "$(stderr_sample "${clear_log}")" >&2
        return 1
    fi

    if ! mkdir -p "${next_dir}"; then
        printf 'error: could not create staging directory %s\n' "${next_dir}" >&2
        return 1
    fi

    if [[ -d "${MAKE_DIR}" ]]; then
        while IFS= read -r -d '' preserved_path; do
            if ! cp -R "${preserved_path}" "${next_dir}/"; then
                printf 'error: could not preserve %s while staging the engine tree\n' \
                    "${preserved_path}" >&2
                rm -rf "${next_dir}"
                return 1
            fi
        done < <(find "${MAKE_DIR}" -mindepth 1 -maxdepth 1 \
            \( -name logs -o -name build.lock -o -name swift-mk -o -name swift-mk.key \
               -o -name swift-mk-build -o -name dev -o -name .swift-mk-snapshot-ref \
               -o -name swift.mk -o -name '*.log' \) -print0)
    fi

    cp -R "${stage_dir}/." "${next_dir}/" 2>"${cp_log}" || cp_status=$?
    if [[ ${cp_status} -ne 0 ]]; then
        printf 'error: staging the engine tree failed (cp exit %d): %s\n' \
            "${cp_status}" "$(stderr_sample "${cp_log}")" >&2
        rm -rf "${next_dir}"
        return 1
    fi

    # Best-effort only: a script that fails to gain +x here still fails loudly
    # and correctly the moment a build tries to execute it.
    find "${next_dir}/scripts" -type f -name '*.sh' -exec chmod +x {} + 2>/dev/null || true

    if ! assets_complete "${next_dir}"; then
        printf 'error: staged engine tree is missing a required asset after copy\n' >&2
        rm -rf "${next_dir}"
        return 1
    fi

    if [[ -d "${MAKE_DIR}" ]]; then
        if ! mv "${MAKE_DIR}" "${previous_dir}"; then
            printf 'error: could not move the current .make aside for the swap\n' >&2
            rm -rf "${next_dir}"
            return 1
        fi
    fi

    if ! mv "${next_dir}" "${MAKE_DIR}"; then
        printf 'error: could not swap the staged engine tree into .make\n' >&2
        if [[ -d "${previous_dir}" ]]; then
            mv "${previous_dir}" "${MAKE_DIR}"
        fi
        rm -rf "${next_dir}"
        return 1
    fi

    # Re-verify the tree that is now actually at .make, not just the staged
    # copy the mv came from, and roll back to the previous tree if it somehow
    # does not hold rather than leaving a known-broken .make in place.
    if ! assets_complete "${MAKE_DIR}"; then
        printf 'error: .make is missing a required asset after the swap\n' >&2
        if [[ -d "${previous_dir}" ]]; then
            rm -rf "${MAKE_DIR}"
            mv "${previous_dir}" "${MAKE_DIR}"
        fi
        return 1
    fi

    rm -rf "${previous_dir}"
    return 0
}

current_epoch_seconds() {
    if [[ -n "${EPOCHSECONDS:-}" ]]; then
        printf '%s' "${EPOCHSECONDS}"
        return 0
    fi
    date +%s
}

# read_marker_field returns one field of the marker. A marker holding only a
# bare ref name, which the previous engine wrote, has no fields, so every
# lookup fails and the caller takes the cold path. That is what unfreezes a
# consumer exactly once.
read_marker_field() {
    local field_name="$1"
    local line
    if [[ ! -s "${MARKER_PATH}" ]]; then
        return 1
    fi
    while IFS= read -r line; do
        if [[ "${line}" == "${field_name}="* ]]; then
            printf '%s' "${line#"${field_name}="}"
            return 0
        fi
    done < "${MARKER_PATH}"
    return 1
}

write_marker() {
    local etag_value="$1"
    {
        printf 'ref=%s\n' "${SWIFT_MK_API_REF}"
        printf 'etag=%s\n' "${etag_value}"
        printf 'timestamp=%s\n' "$(current_epoch_seconds)"
    } > "${MARKER_PATH}"
}

# validate_upstream sends a HEAD request instead of a GET. A GET probe would
# download and discard the full tarball on every run whose upstream moved,
# doubling the transfer and making the 3 second validation budget dishonest
# for anything larger than a tiny snapshot; a HEAD carries no body either way,
# on a 200 or a 304, so the budget stays honest and a moved upstream costs one
# real transfer (the later provision fetch) instead of two.
#
# curl's stderr is written to log_path instead of discarded with 2>/dev/null:
# that discard was a control-flow probe whose failure reason selects between
# serving from disk and falling through to a full provision, and the reason
# must survive so the caller can report it rather than leaving a probe that
# fails on every run invisible. On failure this returns curl's own exit
# status (not a generic 1), so the caller can report the real reason (a
# timeout, a DNS failure, a refused connection) rather than one generic
# message for every kind of failure.
validate_upstream() {
    local known_etag="$1"
    local log_path="$2"
    local status_code
    local curl_status=0
    local -a header_args=()
    if [[ -n "${known_etag}" ]]; then
        header_args=(-H "If-None-Match: ${known_etag}")
    fi
    # "${header_args[@]+"${header_args[@]}"}" instead of a bare
    # "${header_args[@]}": under bash 3.2 (still /bin/bash on stock macOS)
    # with `set -u`, expanding a zero-element array directly raises "unbound
    # variable". The `+` form only expands the array when it is non-empty.
    status_code=$(curl -sS --head \
        --connect-timeout "${VALIDATION_CONNECT_TIMEOUT}" \
        --max-time "${VALIDATION_MAX_TIME}" \
        "${header_args[@]+"${header_args[@]}"}" \
        -o /dev/null -w '%{http_code}' \
        "${SWIFT_MK_CODELOAD_BASE}/${SWIFT_MK_API_REPO}/tar.gz/${SWIFT_MK_API_REF}" \
        2>"${log_path}") || curl_status=$?
    if [[ ${curl_status} -ne 0 ]]; then
        return "${curl_status}"
    fi
    printf '%s' "${status_code}"
}

# marker_is_recent reports whether the recorded validation is inside the reuse
# window. A timestamp in the future, which a backwards clock produces, is not
# recent, so a bad clock forces a real fetch rather than an unbounded serve.
marker_is_recent() {
    local recorded
    local now
    if ! recorded=$(read_marker_field "timestamp"); then
        return 1
    fi
    if [[ ! "${recorded}" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    now=$(current_epoch_seconds)
    if (( recorded > now )); then
        return 1
    fi
    (( now - recorded <= REUSE_WINDOW_SECONDS ))
}

format_age() {
    local seconds="$1"
    if (( seconds < 60 )); then
        printf '%ds' "${seconds}"
        return 0
    fi
    printf '%dm' "$(( seconds / 60 ))"
}

serve_from_disk_with_warning() {
    local validate_status="$1"
    local log_path="$2"
    local recorded
    local etag_value
    local now
    recorded=$(read_marker_field "timestamp")
    etag_value=$(read_marker_field "etag" || printf 'unknown')
    now=$(current_epoch_seconds)
    printf '%s\n' "swift-mk: upstream unreachable; serving the .make snapshot validated $(format_age $(( now - recorded ))) ago (etag ${etag_value}); validation curl exit ${validate_status}: $(stderr_sample "${log_path}"). Set SWIFT_MK_SKIP_FETCH=1 to silence, or check network access to ${SWIFT_MK_CODELOAD_BASE}" >&2
}

# running_in_ci matches the test Build.runsInlineGates already uses.
# GITHUB_ACTIONS alone is not a CI run.
running_in_ci() {
    [[ "${GITHUB_ACTIONS:-}" == "true" && -n "${GITHUB_RUN_ID:-}" ]]
}

# A trap set with `trap ... RETURN` is not scoped to the function that set it:
# it also fires when an enclosing caller later returns, which here would read
# a stage_root local that has already gone out of scope. The staging work runs
# in a subshell instead, so its EXIT trap only ever fires once, on that
# subshell's own exit, and the temp directory is removed exactly then.
provision() {
    (
        stage_root=$(mktemp -d "${TMPDIR:-/tmp}/swift-mk-stage.XXXXXXXX") || exit 1
        trap 'rm -rf "${stage_root}"' EXIT

        stage_dir="${stage_root}/tree"
        if ! stage_fetch_and_verify "${stage_root}" "${stage_dir}"; then
            exit 1
        fi

        etag_value=$(awk 'tolower($1) == "etag:" { print $2 }' "${stage_root}/headers" | tr -d '\r' | tail -n 1)

        if ! install_from_stage "${stage_dir}"; then
            exit 1
        fi

        # A missing ETag does not fail the provision: refusing to install a
        # verified, complete tree would be worse than the defect this guards
        # against, since a cold consumer would be left with no engine at all
        # if codeload ever stopped sending ETag on archives. The tree
        # installs regardless; skipping the marker write means every later
        # run has no known etag and downloads unconditionally, the same
        # behavior this script had before conditional validation existed,
        # with a loud warning every time so the degradation stays visible.
        if [[ -z "${etag_value}" ]]; then
            printf 'swift-mk: warning: upstream response for %s carried no ETag header; validation is disabled until it does, downloading unconditionally each run\n' \
                "${SWIFT_MK_API_REF}" >&2
        else
            write_marker "${etag_value}"
        fi
    )
}

main() {
    local known_etag=""
    local status_code=""
    local stored_ref=""
    local validate_status=0
    local validation_log=""

    mkdir -p "${MAKE_DIR}"

    if [[ -n "${SWIFT_MK_DEV_DIR}" ]]; then
        return 0
    fi

    if [[ "${SWIFT_MK_SKIP_FETCH:-}" == "1" ]]; then
        if assets_complete "${MAKE_DIR}"; then
            return 0
        fi
        printf '%s\n' "error: SWIFT_MK_SKIP_FETCH=1 but .make is missing a required asset" >&2
        return 1
    fi

    # In CI the marker is never read, no conditional request is ever sent, and
    # a failed fetch never falls back to reusing what is on disk: a CI run
    # provisions unconditionally or fails outright.
    if ! running_in_ci && assets_complete "${MAKE_DIR}"; then
        # The etag is only trustworthy against the ref it was recorded for.
        # If SWIFT_MK_API_REF has changed since, the stored etag describes a
        # different ref's content: validating against it, or worse, serving
        # it from disk when the new ref is unreachable, would be a
        # wrong-content serve. A ref mismatch is treated the same as no
        # marker at all.
        stored_ref=$(read_marker_field "ref" || printf '')
        if [[ "${stored_ref}" == "${SWIFT_MK_API_REF}" ]]; then
            known_etag=$(read_marker_field "etag" || printf '')
        fi
    fi

    if [[ -n "${known_etag}" ]]; then
        validation_log=$(mktemp "${TMPDIR:-/tmp}/swift-mk-validate.XXXXXXXX") || return 1
        status_code=$(validate_upstream "${known_etag}" "${validation_log}") || validate_status=$?
        if [[ "${status_code}" == "304" ]]; then
            # Deliberately no marker write. The reuse window is a fixed hour
            # from the last real download, not a window a successful check can
            # slide forward, and a 304 must leave .make byte-for-byte alone.
            rm -f "${validation_log}"
            return 0
        fi
    fi

    # A validation that did not complete (timeout, DNS failure, connection
    # refused) or that returned something other than 304 still has one bounded
    # offline-reuse option: a marker inside the reuse window serves the warm
    # tree with a warning instead of blocking on a slow network. A marker
    # outside the window falls through to a real provision attempt instead of
    # failing here, since a validation timeout only proves the cheap 3 second
    # check did not finish, not that the full fetch would also fail; only a
    # provision that itself fails is a real failure.
    if ! running_in_ci && [[ -n "${known_etag}" && -z "${status_code}" ]] && marker_is_recent; then
        serve_from_disk_with_warning "${validate_status}" "${validation_log}"
        rm -f "${validation_log}"
        return 0
    fi

    # A probe that fails on every run must stay visible even on the stale
    # fall-through path, where the failure only decides whether to log before
    # a real provision attempt, not whether to serve from disk.
    if [[ -n "${validation_log}" ]]; then
        if [[ -z "${status_code}" ]]; then
            printf 'swift-mk: validation curl exit %d: %s; falling through to a full provision\n' \
                "${validate_status}" "$(stderr_sample "${validation_log}")" >&2
        fi
        rm -f "${validation_log}"
    fi

    # `if provision; then` puts provision, and everything it calls, in bash's
    # -e ignore list for the duration of this call: an unguarded failing
    # command anywhere under here would not abort on its own. provision and
    # install_from_stage check every step's exit status explicitly instead of
    # relying on -e to catch a mid-install failure.
    if provision; then
        return 0
    fi

    printf '%s\n' "error: could not provision the swift-makefile engine snapshot. Set SWIFT_MK_DEV_DIR, or check network access to ${SWIFT_MK_CODELOAD_BASE}" >&2
    return 1
}

reexec_from_temp_copy "$@"
main "$@"
