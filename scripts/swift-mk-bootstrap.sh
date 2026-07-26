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
    while IFS= read -r asset_name; do
        if [[ ! -s "${base_dir}/${asset_name}" ]]; then
            return 1
        fi
    done < <(required_assets)
    return 0
}

# install_from_stage replaces the engine tree under .make with the verified
# staged tree, preserving the generated runtime files a build depends on. It
# mirrors snapshot_clear_engine's preserve list in scripts/swift-mk-sync.sh.
install_from_stage() {
    local stage_dir="$1"
    find "${MAKE_DIR}" -mindepth 1 -maxdepth 1 \
        ! -name logs \
        ! -name build.lock \
        ! -name swift-mk \
        ! -name swift-mk.key \
        ! -name swift-mk-build \
        ! -name dev \
        ! -name .swift-mk-snapshot-ref \
        ! -name swift.mk \
        ! -name '*.log' \
        -exec rm -rf {} +
    cp -R "${stage_dir}/." "${MAKE_DIR}/"
    find "${MAKE_DIR}/scripts" -type f -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
}

stage_fetch_and_verify() {
    local stage_root="$1"
    local stage_dir="$2"
    local status_code

    if ! status_code=$(curl -sS --connect-timeout 5 --max-time "${FETCH_MAX_TIME}" \
        -o "${stage_root}/snapshot.tar.gz" -w '%{http_code}' \
        "${SWIFT_MK_CODELOAD_BASE}/${SWIFT_MK_API_REPO}/tar.gz/${SWIFT_MK_API_REF}" 2>/dev/null); then
        return 1
    fi
    if [[ "${status_code}" != "200" ]]; then
        return 1
    fi

    mkdir -p "${stage_dir}"
    if ! tar -xzf "${stage_root}/snapshot.tar.gz" -C "${stage_dir}" --strip-components 1 2>/dev/null; then
        return 1
    fi
    if ! assets_complete "${stage_dir}"; then
        return 1
    fi
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
        install_from_stage "${stage_dir}"
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

    if provision; then
        return 0
    fi

    printf '%s\n' "error: could not provision the swift-makefile engine snapshot. Set SWIFT_MK_DEV_DIR, or check network access to ${SWIFT_MK_CODELOAD_BASE}" >&2
    return 1
}

reexec_from_temp_copy "$@"
main "$@"
