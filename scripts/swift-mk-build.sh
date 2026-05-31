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

    output_path=$(swift_mk_output_path)
    package_path=$(swift_mk_package_path)
    config="${SWIFT_MK_BUILD_CONFIG:-release}"
    if [[ ! -f "${package_path}/Package.swift" ]]; then
        printf "swift-mk: package %s not present\n" "${package_path}"
        return 1
    fi
    mkdir -p "$(dirname "${output_path}")"
    swift build --package-path "${package_path}" -c "${config}" --product swift-mk
    bin_path="$(swift build --package-path "${package_path}" -c "${config}" --show-bin-path | tr -d '\r' | tail -n 1)/swift-mk"
    cp "${bin_path}" "${output_path}"
    chmod +x "${output_path}"
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
