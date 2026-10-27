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

# The checksum entry must match the published engine asset's filename.
SWIFT_MK_ENGINE_ASSET="swift-mk-engine_darwin_arm64.dmg"
SWIFT_MK_CHECKSUMS_ASSET="checksums.txt"
# The release engine needs the active local toolchain's copy of this library.
SWIFT_MK_INDEX_STORE_LIBRARY="libIndexStore.dylib"
# These limits bound engine resolution when an asset request stalls.
SWIFT_MK_DOWNLOAD_CONNECT_TIMEOUT=10
SWIFT_MK_DOWNLOAD_MAX_TIME=300

# A custom binary output path does not relocate bootstrap's release record.
swift_mk_release_record_path() {
    printf "%s/.make/.swift-mk-release\n" "${SWIFT_MK_ROOT:-${PWD}}"
}

# Explicit source checkouts take priority over an existing bootstrap release record.
swift_mk_release_mode() {
    if [[ -n "${SWIFT_MK_BUILD_REPO:-}" || -n "${SWIFT_MK_DEV_DIR:-}" ]]; then
        return 1
    fi
    [[ -f "$(swift_mk_release_record_path)" ]]
}

# Read bootstrap's key=value record without evaluating it as shell code.
swift_mk_record_field() {
    local record_path
    local field_name
    record_path="$1"
    field_name="$2"
    awk -v name="${field_name}" 'index($0, name "=") == 1 { print substr($0, length(name) + 2) }' \
        "${record_path}"
}

# Failure messages use a short, single-line excerpt instead of the full command log.
swift_mk_stderr_sample() {
    tr '\n' ' ' < "$1" | cut -c1-200
}

# The engine loads @rpath/libIndexStore.dylib. dyld searches beside swift-mk
# through @loader_path before checking the build host's Xcode paths.
# The link does not modify the binary or invalidate its Developer ID signature.
# Every resolve checks the active developer directory and honors DEVELOPER_DIR.
swift_mk_link_index_store() {
    local output_dir
    local developer_dir
    local candidate
    local library_path
    local link_path

    output_dir="$1"
    if ! developer_dir=$(xcode-select -p); then
        printf "swift-mk: xcode-select -p failed; select Xcode or the Command Line Tools with xcode-select -s\n" >&2
        return 1
    fi
    library_path=""
    for candidate in \
        "${developer_dir}/Toolchains/XcodeDefault.xctoolchain/usr/lib/${SWIFT_MK_INDEX_STORE_LIBRARY}" \
        "${developer_dir}/usr/lib/${SWIFT_MK_INDEX_STORE_LIBRARY}"; do
        if [[ -f "${candidate}" ]]; then
            library_path="${candidate}"
            break
        fi
    done
    if [[ -z "${library_path}" ]]; then
        printf "swift-mk: %s not found under %s; install Xcode or the Command Line Tools and select it with xcode-select -s\n" \
            "${SWIFT_MK_INDEX_STORE_LIBRARY}" "${developer_dir}" >&2
        return 1
    fi
    link_path="${output_dir}/${SWIFT_MK_INDEX_STORE_LIBRARY}"
    if [[ -L "${link_path}" && "$(readlink "${link_path}")" == "${library_path}" ]]; then
        return 0
    fi
    ln -sfn "${library_path}" "${link_path}"
}

# An executable bit does not prove that dyld can load the engine's libraries.
swift_mk_verify_launch() {
    local output_path
    local tag
    local launch_log
    local launch_status=0

    output_path="$1"
    tag="$2"
    launch_log=$(mktemp "${TMPDIR:-/tmp}/swift-mk-launch.XXXXXXXX")
    "${output_path}" version >/dev/null 2>"${launch_log}" || launch_status=$?
    if [[ ${launch_status} -ne 0 ]]; then
        printf "swift-mk: %s from release %s failed to launch (exit %d): %s\n" \
            "${output_path}" "${tag}" "${launch_status}" "$(swift_mk_stderr_sample "${launch_log}")" >&2
        rm -f "${launch_log}"
        return 1
    fi
    rm -f "${launch_log}"
}

# Download failures must identify the release tag, asset, and URL.
swift_mk_download_asset() {
    local url
    local destination
    local tag
    local asset
    local curl_log
    local curl_status=0

    url="$1"
    destination="$2"
    tag="$3"
    asset="$4"
    curl_log="${destination}.curl.log"
    curl -fsSL --connect-timeout "${SWIFT_MK_DOWNLOAD_CONNECT_TIMEOUT}" \
        --max-time "${SWIFT_MK_DOWNLOAD_MAX_TIME}" \
        -o "${destination}" "${url}" 2>"${curl_log}" || curl_status=$?
    if [[ ${curl_status} -ne 0 ]]; then
        printf "swift-mk: could not download %s for release %s from %s (curl exit %d): %s\n" \
            "${asset}" "${tag}" "${url}" "${curl_status}" "$(swift_mk_stderr_sample "${curl_log}")" >&2
        return 1
    fi
}

# Bash suppresses -e here because the caller tests the staging subshell in an if.
# Every fallible staging step must check its status and return on failure.
swift_mk_stage_release_engine() {
    local work_dir
    local repo
    local tag
    local download_base
    local dmg_url
    local checksums_url
    local dmg_path
    local checksums_path
    local expected_digest
    local actual_digest
    local mount_dir
    local stage_dir
    local attach_log
    local detach_log
    local bundle_path
    local bundle_count

    work_dir="$1"
    repo="$2"
    tag="$3"
    download_base="${SWIFT_MK_RELEASE_BASE:-https://github.com}/${repo}/releases/download/${tag}"
    dmg_url="${download_base}/${SWIFT_MK_ENGINE_ASSET}"
    checksums_url="${download_base}/${SWIFT_MK_CHECKSUMS_ASSET}"
    dmg_path="${work_dir}/${SWIFT_MK_ENGINE_ASSET}"
    checksums_path="${work_dir}/${SWIFT_MK_CHECKSUMS_ASSET}"
    mount_dir="${work_dir}/mount"
    stage_dir="${work_dir}/stage"
    attach_log="${work_dir}/attach.log"
    detach_log="${work_dir}/detach.log"

    if ! swift_mk_download_asset "${checksums_url}" "${checksums_path}" "${tag}" "${SWIFT_MK_CHECKSUMS_ASSET}"; then
        return 1
    fi
    if ! swift_mk_download_asset "${dmg_url}" "${dmg_path}" "${tag}" "${SWIFT_MK_ENGINE_ASSET}"; then
        return 1
    fi

    expected_digest=$(awk -v name="${SWIFT_MK_ENGINE_ASSET}" '$2 == name { print $1 }' "${checksums_path}")
    if [[ -z "${expected_digest}" ]]; then
        printf "swift-mk: %s for release %s at %s does not list %s\n" \
            "${SWIFT_MK_CHECKSUMS_ASSET}" "${tag}" "${checksums_url}" "${SWIFT_MK_ENGINE_ASSET}" >&2
        return 1
    fi
    if ! actual_digest=$(shasum -a 256 "${dmg_path}" | awk '{ print $1 }'); then
        printf "swift-mk: shasum could not hash %s\n" "${dmg_path}" >&2
        return 1
    fi
    if [[ "${actual_digest}" != "${expected_digest}" ]]; then
        printf "swift-mk: %s for release %s from %s has sha256 %s; %s lists %s\n" \
            "${SWIFT_MK_ENGINE_ASSET}" "${tag}" "${dmg_url}" "${actual_digest}" \
            "${SWIFT_MK_CHECKSUMS_ASSET}" "${expected_digest}" >&2
        return 1
    fi

    if ! mkdir -p "${mount_dir}" "${stage_dir}"; then
        printf "swift-mk: could not create %s and %s\n" "${mount_dir}" "${stage_dir}" >&2
        return 1
    fi
    if ! hdiutil attach "${dmg_path}" -readonly -nobrowse -noautoopen \
        -mountpoint "${mount_dir}" >"${attach_log}" 2>&1; then
        printf "swift-mk: hdiutil could not mount %s for release %s from %s: %s\n" \
            "${SWIFT_MK_ENGINE_ASSET}" "${tag}" "${dmg_url}" "$(swift_mk_stderr_sample "${attach_log}")" >&2
        return 1
    fi
    if ! printf "%s\n" "${mount_dir}" > "${work_dir}/mounted"; then
        printf "swift-mk: could not record the mount point %s\n" "${mount_dir}" >&2
        return 1
    fi
    if [[ ! -x "${mount_dir}/swift-mk" ]]; then
        printf "swift-mk: %s for release %s from %s does not contain an executable swift-mk\n" \
            "${SWIFT_MK_ENGINE_ASSET}" "${tag}" "${dmg_url}" >&2
        return 1
    fi
    if ! cp "${mount_dir}/swift-mk" "${stage_dir}/swift-mk"; then
        printf "swift-mk: could not copy swift-mk from %s\n" "${mount_dir}" >&2
        return 1
    fi
    bundle_count=0
    shopt -s nullglob
    for bundle_path in "${mount_dir}"/*.bundle; do
        if ! cp -R "${bundle_path}" "${stage_dir}/"; then
            printf "swift-mk: could not copy %s\n" "${bundle_path}" >&2
            return 1
        fi
        bundle_count=$((bundle_count + 1))
    done
    shopt -u nullglob
    if ! hdiutil detach "${mount_dir}" -quiet >"${detach_log}" 2>&1; then
        printf "swift-mk: hdiutil could not detach %s: %s\n" \
            "${mount_dir}" "$(swift_mk_stderr_sample "${detach_log}")" >&2
        return 1
    fi
    if ! rm -f "${work_dir}/mounted"; then
        printf "swift-mk: could not remove %s\n" "${work_dir}/mounted" >&2
        return 1
    fi
    if [[ ${bundle_count} -eq 0 ]]; then
        printf "swift-mk: %s for release %s from %s does not contain a *.bundle folder\n" \
            "${SWIFT_MK_ENGINE_ASSET}" "${tag}" "${dmg_url}" >&2
        return 1
    fi
}

# A failed staging step can leave the image attached. The mounted file records
# its mount point for cleanup outside the staging subshell.
swift_mk_cleanup_release_work_dir() {
    local work_dir
    local mount_dir
    work_dir="$1"
    if [[ -f "${work_dir}/mounted" ]]; then
        mount_dir=$(cat "${work_dir}/mounted")
        if ! hdiutil detach "${mount_dir}" -force -quiet; then
            printf "swift-mk: hdiutil could not detach %s; detach it with hdiutil detach\n" "${mount_dir}" >&2
        fi
    fi
    rm -rf "${work_dir}"
}

# Release binaries use a tag record because source content keys apply only to
# locally compiled engines.
swift_mk_install_release() {
    local record_path
    local output_path
    local output_dir
    local tag_path
    local repo
    local tag
    local work_dir
    local bundle_path
    local bundle_name

    record_path=$(swift_mk_release_record_path)
    output_path=$(swift_mk_output_path)
    output_dir=$(dirname "${output_path}")
    tag_path="${output_path}.release-tag"
    repo=$(swift_mk_record_field "${record_path}" repo)
    tag=$(swift_mk_record_field "${record_path}" tag)
    if [[ -z "${repo}" || -z "${tag}" ]]; then
        printf "swift-mk: %s does not record a repo and a tag\n" "${record_path}" >&2
        return 1
    fi

    mkdir -p "${output_dir}"
    if [[ -x "${output_path}" && -f "${tag_path}" && "$(cat "${tag_path}")" == "${tag}" ]]; then
        swift_mk_link_index_store "${output_dir}"
        swift_mk_verify_launch "${output_path}" "${tag}"
        return
    fi

    work_dir=$(mktemp -d "${output_dir}/.swift-mk-engine-download.XXXXXXXX")
    if ! (swift_mk_stage_release_engine "${work_dir}" "${repo}" "${tag}"); then
        swift_mk_cleanup_release_work_dir "${work_dir}"
        return 1
    fi
    shopt -s nullglob
    for bundle_path in "${work_dir}/stage"/*.bundle; do
        bundle_name=$(basename "${bundle_path}")
        rm -rf "${output_dir:?}/${bundle_name}"
        mv "${bundle_path}" "${output_dir}/${bundle_name}"
    done
    shopt -u nullglob
    mv "${work_dir}/stage/swift-mk" "${output_path}"
    swift_mk_cleanup_release_work_dir "${work_dir}"
    # Deleting the source key requires a rebuild after a switch to source mode.
    rm -f "${output_path}.key" "${tag_path}"
    swift_mk_link_index_store "${output_dir}"
    swift_mk_verify_launch "${output_path}" "${tag}"
    # Write the tag last. If this new binary fails its launch check, the next
    # resolve must download it again.
    printf "%s\n" "${tag}" > "${tag_path}"
}

swift_mk_resolve_bin() {
    local package_path
    local output_path
    local key_path
    local computed_key
    local stored_key

    # Computing a source key runs `swift --version`. Resolve releases first to
    # avoid invoking the source-build toolchain.
    if swift_mk_release_mode; then
        swift_mk_install_release
        return
    fi

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
