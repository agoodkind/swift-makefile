#!/usr/bin/env bash
set -eo pipefail

SWIFT_MK_API_REPO="${SWIFT_MK_API_REPO:-agoodkind/swift-makefile}"
SWIFT_MK_API_REF="${SWIFT_MK_API_REF:-main}"

# Resolve the dev checkout to its physical path once, up front. SWIFT_MK_DEV_DIR
# is often a symlink under .make/dev, and smoke-fetch wipes .make before it
# extracts, so the symlink would be gone by the time the extract reads it. The
# physical worktree path survives the wipe.
SWIFT_MK_DEV_DIR_REAL=""
if [[ -n "${SWIFT_MK_DEV_DIR:-}" ]]; then
    SWIFT_MK_DEV_DIR_REAL="$(cd "${SWIFT_MK_DEV_DIR}" 2>/dev/null && pwd -P || true)"
fi

# Remove a prior snapshot's engine files from .make before laying down a new one, so
# a ref change or a migration from the old per-file .make cannot leave an orphaned
# source the new snapshot no longer defines (SwiftPM would then compile the orphan and
# the build would break). Preserve the generated runtime files: the built binary and
# its scratch and content key, the logs, the build lock, the dev symlinks, the
# snapshot marker, and any *.log. Everything else in .make is engine content the
# snapshot re-provides, so clearing it and re-extracting drops orphans while keeping
# the runtime state a build depends on.
snapshot_clear_engine() {
    local make_dir="$1"
    find "${make_dir}" -mindepth 1 -maxdepth 1 \
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
}

# Extract the whole engine snapshot into .make so it becomes the flat SwiftPM
# package the consumer builds. In dev-dir mode take the local working tree: stage
# it into a throwaway index and archive that tree, so the extract includes a source
# added on disk with no manifest to edit, drops a file removed on disk, and excludes
# .git and the gitignored .make, all without touching the real index. Otherwise
# download the pinned ref's archive from GitHub, gh first and a plain curl of the
# public codeload archive as the fallback, so no auth is required. Either path clears
# the prior snapshot's engine files first, then lands the same flat layout under .make.
snapshot_extract() {
    local make_dir
    local dev_dir
    local temp_index
    local tree
    local temp_dir
    local ok

    mkdir -p .make
    make_dir="$(cd .make && pwd)"
    dev_dir="${SWIFT_MK_DEV_DIR_REAL}"

    if [[ -n "${dev_dir}" ]] && git -C "${dev_dir}" rev-parse --show-toplevel >/dev/null 2>&1; then
        temp_index="$(mktemp)"
        GIT_INDEX_FILE="${temp_index}" git -C "${dev_dir}" read-tree HEAD
        GIT_INDEX_FILE="${temp_index}" git -C "${dev_dir}" add -A
        tree="$(GIT_INDEX_FILE="${temp_index}" git -C "${dev_dir}" write-tree)"
        rm -f "${temp_index}"
        snapshot_clear_engine "${make_dir}"
        git -C "${dev_dir}" archive --format=tar "${tree}" | tar -x -C "${make_dir}"
        printf "dev-%s\n" "$(git -C "${dev_dir}" rev-parse HEAD)" > "${make_dir}/.swift-mk-snapshot-ref"
        return 0
    fi

    temp_dir="$(mktemp -d)"
    ok=""
    if command -v gh >/dev/null 2>&1 \
        && gh api "repos/${SWIFT_MK_API_REPO}/tarball/${SWIFT_MK_API_REF}" > "${temp_dir}/snapshot.tar.gz" 2>/dev/null \
        && [[ -s "${temp_dir}/snapshot.tar.gz" ]]; then
        ok=1
    elif curl -fsSL --connect-timeout 5 --max-time 60 \
        "https://codeload.github.com/${SWIFT_MK_API_REPO}/tar.gz/${SWIFT_MK_API_REF}" \
        -o "${temp_dir}/snapshot.tar.gz" \
        && [[ -s "${temp_dir}/snapshot.tar.gz" ]]; then
        ok=1
    fi
    if [[ -z "${ok}" ]]; then
        printf "swift-mk-sync: could not fetch the engine snapshot for %s\n" "${SWIFT_MK_API_REF}" >&2
        rm -rf "${temp_dir}"
        return 1
    fi
    snapshot_clear_engine "${make_dir}"
    tar -xz --strip-components=1 -C "${make_dir}" -f "${temp_dir}/snapshot.tar.gz"
    printf "%s\n" "${SWIFT_MK_API_REF}" > "${make_dir}/.swift-mk-snapshot-ref"
    rm -rf "${temp_dir}"
}

update_assets() {
    snapshot_extract
    printf "updated: engine snapshot extracted into .make/\n"
}

smoke_fetch() {
    local count_output

    rm -rf .make
    mkdir -p .make
    snapshot_extract
    count_output=$(find .make -type f | wc -l | tr -d " ")
    printf "smoke-fetch: %s files extracted into .make/\n" "${count_output}"
    smoke_build_swiftcheck
    printf "smoke-fetch: OK (%s files extracted into .make/)\n" "${count_output}"
}

# Build the swiftcheck package from the freshly extracted tree so a snapshot that
# is missing a swiftcheck source (a declared target source left out of the archive)
# fails here instead of silently breaking a consumer's on-demand build on a clean
# runner. SwiftPM validates every declared target's source directory at manifest
# load, so a missing SwiftCheckCore or SwiftCheckCoreTests source fails the build.
smoke_build_swiftcheck() {
    local package_path=".make/swiftcheck"
    local product="${SWIFTCHECK_EXTRA_BUILD_PRODUCT:-swiftcheck-extra}"

    if [[ ! -f "${package_path}/Package.swift" ]]; then
        printf "smoke-fetch: %s/Package.swift missing after extract\n" "${package_path}" >&2
        exit 1
    fi
    printf "smoke-fetch: building %s from the extracted swiftcheck package\n" "${product}"
    if ! swift build --package-path "${package_path}" -c release --product "${product}"; then
        printf "smoke-fetch: building %s from %s failed; the snapshot is missing a swiftcheck source\n" "${product}" "${package_path}" >&2
        exit 1
    fi
}

# Only dispatch when executed directly, so a test can source this file to exercise a
# single function (snapshot_clear_engine) without triggering the unknown-command exit.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        update)
            update_assets
            ;;
        smoke-fetch)
            smoke_fetch
            ;;
        *)
            printf "swift-mk-sync: unknown command %s\n" "${1:-}"
            exit 2
            ;;
    esac
fi
