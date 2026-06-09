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

swift_mk_build_from_repo() {
    local output_path
    local package_path
    local config
    local bin_path
    local scratch_path

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
    swift build --package-path "${package_path}" --scratch-path "${scratch_path}" -c "${config}" --product swift-mk
    bin_path="$(swift build --package-path "${package_path}" --scratch-path "${scratch_path}" -c "${config}" --show-bin-path | tr -d '\r' | tail -n 1)/swift-mk"
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
        newest_source=$(find "${package_path}/Sources" "${package_path}/Package.swift" -name "*.swift" -newer "${output_path}" 2>/dev/null | head -n 1 || true)
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
