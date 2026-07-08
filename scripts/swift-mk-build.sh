#!/usr/bin/env bash
set -eo pipefail

# Build and cache the swift-mk tooling binary. Runs before the binary exists, so
# it stays shell. Modeled on swift-mk-swiftcheck-extra.sh.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

swift_mk_output_path() {
    printf "%s\n" "${SWIFT_MK_BIN:-${SWIFT_MK_ROOT:-${PWD}}/.make/swift-mk}"
}

swift_mk_package_path() {
    if [[ -n "${SWIFT_MK_BUILD_REPO:-}" ]]; then
        printf "%s\n" "${SWIFT_MK_BUILD_REPO}"
        return
    fi
    if [[ -n "${SWIFT_MK_DEV_DIR:-}" && -f "${SWIFT_MK_DEV_DIR}/Package.swift" ]]; then
        printf "%s\n" "${SWIFT_MK_DEV_DIR}"
        return
    fi
    printf "%s/.make\n" "${SWIFT_MK_ROOT:-${PWD}}"
}

swift_mk_dependency_hash() {
    local manifest_path
    local package_path
    local resolved_path

    package_path="$1"
    manifest_path="${package_path}/Package.swift"
    resolved_path="${package_path}/Package.resolved"
    if [[ ! -f "${manifest_path}" ]]; then
        printf "%s\n" "swift-mk-missing-package"
        return
    fi
    {
        shasum "${manifest_path}"
        if [[ -f "${resolved_path}" ]]; then
            shasum "${resolved_path}"
        fi
    } | awk '{ print $1 }' | LC_ALL=C sort | shasum | awk '{ print $1 }'
}

swift_mk_pool_cache_args() {
    local package_path
    local pool_cache_root
    local dependency_hash
    local swiftpm_cache_path

    package_path="$1"
    pool_cache_root="/Volumes/My Shared Files/cache"
    if [[ "${SWIFT_MK_POOL:-}" != "1" ]]; then
        return
    fi
    if [[ ! -d "${pool_cache_root}" ]]; then
        return
    fi

    dependency_hash=$(swift_mk_dependency_hash "${package_path}")
    swiftpm_cache_path="${pool_cache_root}/spm/${dependency_hash}/swiftpm-cache"
    mkdir -p "${swiftpm_cache_path}"
    # SwiftPM CLI has no separate SourcePackages checkout flag. Keep the
    # per-consumer scratch path and share only SwiftPM's supported dependency cache.
    # Disable the manifest DB because SwiftPM's shared manifest cache lives under
    # --cache-path and is write-heavy.
    printf "%s\n" "--cache-path"
    printf "%s\n" "${swiftpm_cache_path}"
    printf "%s\n" "--manifest-cache"
    printf "%s\n" "none"
}

swift_mk_build_from_repo() {
    local output_path
    local package_path
    local config
    local bin_dir
    local bin_path
    local scratch_path
    local -a pool_cache_args

    output_path=$(swift_mk_output_path)
    package_path=$(swift_mk_package_path)
    config="${SWIFT_MK_BUILD_CONFIG:-release}"
    if [[ ! -f "${package_path}/Package.swift" ]]; then
        printf "swift-mk: package %s not present\n" "${package_path}"
        return 1
    fi
    mkdir -p "$(dirname "${output_path}")"
    # Build into a per-consumer scratch directory under the consumer's .make, not
    # the package's own .build. In dev-dir mode every consumer (and swift-makefile's
    # own dev work) shares one swift-makefile checkout, so building into that
    # checkout's .build serializes them all on a single SwiftPM lock and leaves the
    # binary missing whenever another build holds it. A scratch path under the
    # consumer isolates each consumer and each worktree.
    scratch_path="$(dirname "${output_path}")/swift-mk-build"
    pool_cache_args=()
    while IFS= read -r arg; do
        pool_cache_args+=("${arg}")
    done < <(swift_mk_pool_cache_args "${package_path}")
    swift build --package-path "${package_path}" --scratch-path "${scratch_path}" "${pool_cache_args[@]}" -c "${config}" --product swift-mk
    bin_dir=$(
        swift build --package-path "${package_path}" --scratch-path "${scratch_path}" "${pool_cache_args[@]}" -c "${config}" --show-bin-path \
            | tr -d '\r' \
            | awk 'NF { line = $0 } END { print line }'
    )
    if [[ -z "${bin_dir}" ]]; then
        printf "swift-mk: could not resolve SwiftPM binary output path\n" >&2
        return 1
    fi
    bin_path="${bin_dir}/swift-mk"
    cp "${bin_path}" "${output_path}"
    chmod +x "${output_path}"
    # A copied arm64 binary can carry a stale linker signature and a provenance
    # xattr that make the kernel kill it on launch ("Killed: 9"). Clear the xattrs
    # and re-sign ad-hoc so the cached binary runs.
    if command -v xattr >/dev/null 2>&1; then
        xattr -c "${output_path}" 2>/dev/null || true
    fi
    if command -v codesign >/dev/null 2>&1; then
        codesign --force --sign - "${output_path}" >/dev/null 2>&1 || true
    fi
}

swift_mk_resolve_bin() {
    local package_path
    local output_path
    local newest_source

    output_path=$(swift_mk_output_path)
    package_path=$(swift_mk_package_path)
    newest_source=""
    if [[ -x "${output_path}" ]]; then
        newest_source=$(find "${package_path}/Sources" "${package_path}/Package.swift" -name "*.swift" -newer "${output_path}" -print -quit 2>/dev/null || true)
    fi
    if [[ ! -x "${output_path}" || -n "${newest_source}" ]]; then
        swift_mk_build_from_repo
    fi
}

case "${1:-resolve}" in
    resolve)
        swift_mk_resolve_bin
        ;;
    path)
        if [[ -n "${SWIFT_MK_BIN:-}" ]]; then printf "%s\n" "${SWIFT_MK_BIN}"; else swift_mk_output_path; fi
        ;;
    *)
        printf "swift-mk-build: unknown command %s\n" "${1}"
        exit 2
        ;;
esac
