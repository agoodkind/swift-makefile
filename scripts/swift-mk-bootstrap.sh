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
    local preserved_path
    cp_log="$(dirname "${stage_dir}")/install-cp.log"

    rm -rf "${next_dir}" "${previous_dir}"
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
        if ! install_from_stage "${stage_dir}"; then
            exit 1
        fi
    )
}

main() {
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
