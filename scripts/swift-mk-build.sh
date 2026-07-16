#!/usr/bin/env bash
set -eo pipefail

# Build and cache the swift-mk tooling binary. Runs before the binary exists, so
# it stays shell. Modeled on swift-mk-swiftcheck-extra.sh.

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

# Content key for the built tool binary: fold the source that produces it and the
# active toolchain identity into one stable string. Reuse keys on content, not file
# mtimes, so a source or toolchain change rebuilds while a binary restored with any
# mtime neither forces a spurious rebuild nor serves a stale binary.
swift_mk_content_key() {
    local package_path
    local config
    local resolved_rel
    local source_hash
    local toolchain_id

    package_path="$1"
    # The product's build configuration is part of its identity: a release binary must
    # not be reused when the consumer switches to debug, so fold it into the key.
    config="${SWIFT_MK_BUILD_CONFIG:-release}"

    # Prefer the committed Package.resolved, else the .swiftpm one, recorded as a
    # package-relative path so both the digest and the path stay stable across machines.
    resolved_rel=""
    if [[ -f "${package_path}/Package.resolved" ]]; then
        resolved_rel="Package.resolved"
    elif [[ -f "${package_path}/.swiftpm/configuration/Package.resolved" ]]; then
        resolved_rel=".swiftpm/configuration/Package.resolved"
    fi

    # Hash each input as "<content-digest>  <package-relative-path>", so a
    # content-preserving rename changes the key (the path moved) while the digest stays
    # deterministic across machines because the paths are package-relative, never absolute
    # temp-dir paths. Run relative to the package so shasum emits relative paths. Inputs:
    # Package.swift, the resolved lockfile, this build script (the CI toolchain-cache key
    # folds it too), and every file under Sources (Swift sources plus bundled
    # Resources/*.yml,*.json,*.toml that compile into the binary). find under pipefail
    # must not abort when Sources is absent; the null delimiter keeps a path with
    # whitespace from splitting an entry; sort the full lines so the key is order-stable.
    source_hash=$(
        cd "${package_path}" 2>/dev/null || exit 0
        {
            if [[ -f Package.swift ]]; then printf '%s\0' "Package.swift"; fi
            if [[ -n "${resolved_rel}" ]]; then printf '%s\0' "${resolved_rel}"; fi
            if [[ -f scripts/swift-mk-build.sh ]]; then printf '%s\0' "scripts/swift-mk-build.sh"; fi
            find Sources -type f -print0 2>/dev/null || true
        } | xargs -0 shasum 2>/dev/null | LC_ALL=C sort | shasum | awk '{ print $1 }'
    )

    # Fold the active toolchain identity so a compiler or Xcode-bundle change rebuilds
    # even when no source changed.
    toolchain_id=$(
        {
            xcode-select -p 2>/dev/null || true
            swift --version 2>/dev/null || true
        } | shasum | awk '{ print $1 }'
    )
    printf '%s-%s-%s\n' "${source_hash}" "${config}" "${toolchain_id}"
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
    local bin_dir_output
    local bin_dir_status
    local bin_path
    local scratch_path
    local content_key
    local -a pool_cache_args

    output_path=$(swift_mk_output_path)
    package_path=$(swift_mk_package_path)
    config="${SWIFT_MK_BUILD_CONFIG:-release}"
    if [[ ! -f "${package_path}/Package.swift" ]]; then
        printf "swift-mk: package %s not present\n" "${package_path}"
        return 1
    fi
    # Capture the content key BEFORE compiling. Recomputing it after the build would
    # open a TOCTOU gap: a source edit during compilation would label the just-built
    # binary with the post-edit key, so the next resolve would reuse a binary that does
    # not match the edited source. Keying on the pre-build inputs labels the binary with
    # exactly what produced it, so a mid-build edit leaves a key mismatch and rebuilds.
    content_key=$(swift_mk_content_key "${package_path}")
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
    set +e
    bin_dir_output=$(swift build --package-path "${package_path}" --scratch-path "${scratch_path}" "${pool_cache_args[@]}" -c "${config}" --show-bin-path 2>&1)
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
    # Record the content key captured before the build, so a later resolve reuses the
    # binary only when the source and toolchain that produced it are unchanged,
    # independent of file mtimes.
    printf '%s\n' "${content_key}" > "${output_path}.key"
}

swift_mk_resolve_bin() {
    local package_path
    local output_path
    local key_path
    local computed_key
    local stored_key

    output_path=$(swift_mk_output_path)

    # Trust a CI-provided binary that already launched under its probe. CI exports
    # SWIFT_MK_BIN_VERIFIED=1 after building or restoring the toolchain binary and
    # running its `--help` launch probe, so the make-driven resolve reuses it instead
    # of building a second copy. SWIFT_MK_BIN being set is not itself the signal:
    # swift.mk sets it on every invocation, so gating on it would never rebuild a
    # stale local binary.
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
    # Reuse the existing binary only when it is executable and its stored content key
    # matches the freshly computed one; otherwise rebuild (which rewrites the key).
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
