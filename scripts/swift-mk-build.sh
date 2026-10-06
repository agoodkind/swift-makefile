#!/usr/bin/env bash
set -eo pipefail

# Builds the swift-mk binary and copies it to .make/swift-mk. This script is
# shell because it runs before the binary exists.

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
    local swiftpm_resolved_path

    package_path="$1"
    manifest_path="${package_path}/Package.swift"
    resolved_path="${package_path}/Package.resolved"
    swiftpm_resolved_path="${package_path}/.swiftpm/configuration/Package.resolved"
    if [[ ! -f "${manifest_path}" ]]; then
        printf "%s\n" "swift-mk-missing-package"
        return
    fi
    {
        shasum "${manifest_path}"
        if [[ -f "${resolved_path}" ]]; then
            shasum "${resolved_path}"
        elif [[ -f "${swiftpm_resolved_path}" ]]; then
            shasum "${swiftpm_resolved_path}"
        fi
    } | awk '{ print $1 }' | LC_ALL=C sort | shasum | awk '{ print $1 }'
}

# Prints the content key of the binary: a hash of the source files, the build
# configuration, and a hash of the toolchain identity. swift_mk_resolve_bin
# compares keys and ignores file modification times.
swift_mk_content_key() {
    local package_path
    local config
    local resolved_rel
    local source_hash
    local toolchain_id

    package_path="$1"
    config="${SWIFT_MK_BUILD_CONFIG:-release}"

    resolved_rel=""
    if [[ -f "${package_path}/Package.resolved" ]]; then
        resolved_rel="Package.resolved"
    elif [[ -f "${package_path}/.swiftpm/configuration/Package.resolved" ]]; then
        resolved_rel=".swiftpm/configuration/Package.resolved"
    fi

    # Each hashed line is "<digest>  <path relative to the package>". A renamed
    # file changes the hash. Two machines with different checkout paths compute
    # equal hashes. The inputs are Package.swift, the resolved lockfile, this
    # script, and every file under Sources. `|| true` covers a missing Sources
    # directory under pipefail.
    source_hash=$(
        cd "${package_path}" 2>/dev/null || exit 0
        {
            if [[ -f Package.swift ]]; then printf '%s\0' "Package.swift"; fi
            if [[ -n "${resolved_rel}" ]]; then printf '%s\0' "${resolved_rel}"; fi
            if [[ -f scripts/swift-mk-build.sh ]]; then printf '%s\0' "scripts/swift-mk-build.sh"; fi
            find Sources -type f -print0 2>/dev/null || true
        } | xargs -0 shasum 2>/dev/null | LC_ALL=C sort | shasum | awk '{ print $1 }'
    )

    toolchain_id=$(
        {
            xcode-select -p 2>/dev/null || true
            swift --version 2>/dev/null || true
        } | shasum | awk '{ print $1 }'
    )
    printf '%s-%s-%s\n' "${source_hash}" "${config}" "${toolchain_id}"
}

swift_mk_resolve_flags() {
    if [[ "$(uname -s)" == Darwin ]]; then
        printf '%s\n' --disable-automatic-resolution
    fi
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
    # The pool shares only the SwiftPM dependency cache; each consumer has its
    # own scratch path. The manifest cache is off because SwiftPM stores it under
    # --cache-path and writes to it often.
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
    local bin_dir_output
    local bin_dir_status
    local bin_path
    local bundle_path
    local bundle_name
    local output_dir
    local scratch_path
    local content_key
    local -a resolve_flags
    local -a pool_cache_args

    output_path=$(swift_mk_output_path)
    package_path=$(swift_mk_package_path)
    config="${SWIFT_MK_BUILD_CONFIG:-release}"
    if [[ ! -f "${package_path}/Package.swift" ]]; then
        printf "swift-mk: package %s not present\n" "${package_path}"
        return 1
    fi
    # Compute the key before the build. A source edit during the build then
    # produces a key mismatch on the next resolve, and the binary is rebuilt.
    content_key=$(swift_mk_content_key "${package_path}")
    mkdir -p "$(dirname "${output_path}")"
    # The scratch directory is under the .make of the consumer. In dev-dir mode
    # every consumer builds one swift-makefile checkout, and a build into the
    # .build of that checkout would wait on one SwiftPM lock.
    scratch_path="$(dirname "${output_path}")/swift-mk-build"
    pool_cache_args=()
    while IFS= read -r arg; do
        pool_cache_args+=("${arg}")
    done < <(swift_mk_pool_cache_args "${package_path}")
    resolve_flags=()
    while IFS= read -r arg; do
        [[ -n "${arg}" ]] && resolve_flags+=("${arg}")
    done < <(swift_mk_resolve_flags)
    swift build --package-path "${package_path}" --scratch-path "${scratch_path}" "${pool_cache_args[@]}" "${resolve_flags[@]}" -c "${config}" --product swift-mk
    set +e
    bin_dir_output=$(swift build --package-path "${package_path}" --scratch-path "${scratch_path}" "${pool_cache_args[@]}" "${resolve_flags[@]}" -c "${config}" --show-bin-path 2>&1)
    bin_dir_status=$?
    set -e
    bin_dir=$(printf "%s\n" "${bin_dir_output}" | tr -d '\r' | awk 'NF { line = $0 } END { print line }')
    if [[ "${bin_dir_status}" -ne 0 || -z "${bin_dir}" ]]; then
        printf "swift-mk: could not resolve SwiftPM binary output path\n" >&2
        if [[ -n "${bin_dir_output//[[:space:]]/}" ]]; then
            printf "swift-mk: swift build --show-bin-path output:\n%s\n" "${bin_dir_output}" >&2
        else
            printf "swift-mk: swift build --show-bin-path produced no output\n" >&2
        fi
        return 1
    fi
    bin_path="${bin_dir}/swift-mk"
    output_dir="$(dirname "${output_path}")"
    cp "${bin_path}" "${output_path}"
    chmod +x "${output_path}"
    # swift-mk reads its lint configs from a resource bundle in the directory of
    # the running executable. Copy every bundle from the build directory.
    shopt -s nullglob
    for bundle_path in "${bin_dir}"/*.bundle; do
        bundle_name="$(basename "${bundle_path}")"
        if [[ -z "${bundle_name}" ]]; then
            continue
        fi
        rm -rf "${output_dir:?}/${bundle_name}"
        cp -R "${bundle_path}" "${output_dir}/${bundle_name}"
    done
    shopt -u nullglob
    # The kernel can kill a copied arm64 binary on launch ("Killed: 9") because
    # of a stale linker signature or a provenance xattr. Clear the xattrs and
    # sign the copy ad hoc.
    if command -v xattr >/dev/null 2>&1; then
        xattr -c "${output_path}" 2>/dev/null || true
    fi
    if command -v codesign >/dev/null 2>&1; then
        codesign --force --sign - "${output_path}" >/dev/null 2>&1 || true
    fi
    printf '%s\n' "${content_key}" > "${output_path}.key"
}

swift_mk_resolve_bin() {
    local package_path
    local output_path
    local key_path
    local computed_key
    local stored_key

    output_path=$(swift_mk_output_path)

    # CI exports SWIFT_MK_BIN_VERIFIED=1 after it builds or restores the binary
    # and runs `swift-mk --help`. Reuse that binary without a key check.
    # SWIFT_MK_BIN is not the signal, because swift.mk sets it on every run.
    if [[ "${SWIFT_MK_BIN_VERIFIED:-}" == "1" && -x "${output_path}" ]]; then
        return
    fi

    package_path=$(swift_mk_package_path)
    key_path="${output_path}.key"
    computed_key=$(swift_mk_content_key "${package_path}")
    stored_key=""
    if [[ -f "${key_path}" ]]; then
        stored_key=$(cat "${key_path}")
    fi
    if [[ -x "${output_path}" && "${stored_key}" == "${computed_key}" ]]; then
        return
    fi
    swift_mk_build_from_repo
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
