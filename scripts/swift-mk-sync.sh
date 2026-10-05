#!/usr/bin/env bash
set -eo pipefail

SWIFT_MK_API_REPO="${SWIFT_MK_API_REPO:-agoodkind/swift-makefile}"
SWIFT_MK_API_REF="${SWIFT_MK_API_REF:-main}"

# SWIFT_MK_DEV_DIR is often a symlink under .make/dev, and smoke_fetch deletes
# .make before snapshot_extract reads the path. Resolve the physical path first.
SWIFT_MK_DEV_DIR_REAL=""
if [[ -n "${SWIFT_MK_DEV_DIR:-}" ]]; then
    SWIFT_MK_DEV_DIR_REAL="$(cd "${SWIFT_MK_DEV_DIR}" 2>/dev/null && pwd -P || true)"
fi

# Deletes the engine files of the previous snapshot from .make. SwiftPM compiles
# every source file under .make, including a file the new snapshot does not
# contain. The function does not delete the files a build generates.
# install_from_stage in scripts/swift-mk-bootstrap.sh preserves the same names.
#
# .gate and signing.xcconfig are in the preserved names because a nested make
# can extract a snapshot during a build. A gated build reads .make/.gate/stamp
# at each compile. xcodebuild reads the path in XCODE_XCCONFIG_FILE for the
# whole build.
snapshot_clear_engine() {
    local make_dir="$1"
    find "${make_dir}" -mindepth 1 -maxdepth 1 \
        ! -name logs \
        ! -name build.lock \
        ! -name swift-mk \
        ! -name swift-mk.key \
        ! -name '*.bundle' \
        ! -name swift-mk-build \
        ! -name dev \
        ! -name .swift-mk-snapshot-ref \
        ! -name .gate \
        ! -name signing.xcconfig \
        ! -name swift.mk \
        ! -name '*.log' \
        -exec rm -rf {} +
}

# Extracts the engine snapshot into .make, which is the SwiftPM package the
# consumer builds. In dev-dir mode the source is the working tree of the dev
# checkout: the function stages that tree in a temporary index and archives it,
# and does not change the index of the checkout. Otherwise the function
# downloads the archive of SWIFT_MK_API_REF with gh, or with curl from codeload
# when gh fails.
snapshot_extract() {
    local make_dir
    local dev_dir
    local temp_index
    local tree
    local temp_dir
    local ok
    local codeload_base
    local etag_value

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
    # Tests set SWIFT_MK_CODELOAD_BASE to a local server.
    codeload_base="${SWIFT_MK_CODELOAD_BASE:-https://codeload.github.com}"
    if command -v gh >/dev/null 2>&1 \
        && gh api "repos/${SWIFT_MK_API_REPO}/tarball/${SWIFT_MK_API_REF}" > "${temp_dir}/snapshot.tar.gz" 2>/dev/null \
        && [[ -s "${temp_dir}/snapshot.tar.gz" ]]; then
        ok=1
    elif curl -fsSL --connect-timeout 5 --max-time 60 \
        -D "${temp_dir}/headers" \
        "${codeload_base}/${SWIFT_MK_API_REPO}/tar.gz/${SWIFT_MK_API_REF}" \
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
    # The marker has the three fields that scripts/swift-mk-bootstrap.sh writes.
    # SWIFT_MK_SNAPSHOT_CURRENT in swift.mk reads the etag field. The gh download
    # writes no headers file; awk then exits nonzero, and `|| true` sets an empty
    # etag_value under pipefail.
    etag_value=$(awk 'tolower($1) == "etag:" { print $2 }' "${temp_dir}/headers" 2>/dev/null | tr -d '\r' | tail -n 1) || true
    {
        printf 'ref=%s\n' "${SWIFT_MK_API_REF}"
        printf 'etag=%s\n' "${etag_value}"
        printf 'timestamp=%s\n' "${EPOCHSECONDS:-$(date +%s)}"
    } > "${make_dir}/.swift-mk-snapshot-ref"
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

# Builds the swiftcheck package from the extracted tree. The build fails when
# the snapshot lacks the source directory of a declared swiftcheck target.
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

# A test sources this file to call snapshot_clear_engine. Dispatch a command
# only when the file is executed.
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
