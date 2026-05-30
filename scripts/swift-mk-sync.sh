#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FETCH_SCRIPT="${SCRIPT_DIR}/swift-mk-fetch-one.sh"

asset_list() {
    local script_file
    local module_name

    # Top-level configs that are not carried in SWIFT_MK_SCRIPT_FILES.
    printf "swift.mk\n"
    printf ".swiftlint.yml\n"
    printf ".swift-format\n"
    printf ".periphery.yml\n"
    printf "swift-build.mk\n"
    printf "swift-release.mk\n"

    # The canonical fetched file set is authored once in swift.mk as
    # SWIFT_MK_SCRIPT_FILES and exported into this script's environment, so the
    # swiftcheck package sources live in exactly one list and cannot drift.
    if [[ -z "${SWIFT_MK_SCRIPT_FILES:-}" ]]; then
        printf "swift-mk-sync: SWIFT_MK_SCRIPT_FILES is empty; run via make (e.g. make smoke-fetch)\n" >&2
        exit 1
    fi
    # shellcheck disable=SC2086
    for script_file in ${SWIFT_MK_SCRIPT_FILES}; do
        printf "%s\n" "${script_file}"
    done

    for module_name in ${SWIFT_MK_MODULES:-}; do
        printf "%s\n" "${module_name}"
    done
}

update_assets() {
    local asset_name
    local destination_path

    mkdir -p .make
    while IFS= read -r asset_name; do
        if [[ -z "${asset_name}" ]]; then
            continue
        fi
        if [[ "${asset_name}" == "swift.mk" ]]; then
            destination_path="${SWIFT_MK:-.make/swift.mk}"
        else
            destination_path=".make/${asset_name}"
        fi
        bash "${FETCH_SCRIPT}" "${asset_name}" "${destination_path}" ""
        printf "updated: %s\n" "${asset_name}"
    done < <(asset_list | awk 'NF && !seen[$0]++')
}

smoke_fetch() {
    local asset_name
    local destination_path
    local count_output

    rm -rf .make
    mkdir -p .make
    while IFS= read -r asset_name; do
        if [[ -z "${asset_name}" ]]; then
            continue
        fi
        destination_path=".make/${asset_name}"
        bash "${FETCH_SCRIPT}" "${asset_name}" "${destination_path}" ""
    done < <(asset_list | awk 'NF && !seen[$0]++')
    count_output=$(find .make -type f | wc -l | tr -d " ")
    printf "smoke-fetch: %s assets fetched into .make/\n" "${count_output}"
    smoke_build_swiftcheck
    printf "smoke-fetch: OK (%s assets fetched into .make/)\n" "${count_output}"
}

# Build the swiftcheck package from the freshly fetched tree so an incomplete
# fetch manifest (a declared target source missing from the asset list) fails
# here instead of silently breaking a consumer's on-demand build on a clean
# runner. SwiftPM validates every declared target's source directory at manifest
# load, so a missing SwiftCheckCore or SwiftCheckCoreTests source fails the build.
smoke_build_swiftcheck() {
    local package_path=".make/swiftcheck"
    local product="${SWIFTCHECK_EXTRA_BUILD_PRODUCT:-swiftcheck-extra}"

    if [[ ! -f "${package_path}/Package.swift" ]]; then
        printf "smoke-fetch: %s/Package.swift missing after fetch\n" "${package_path}" >&2
        exit 1
    fi
    printf "smoke-fetch: building %s from the fetched swiftcheck package\n" "${product}"
    if ! swift build --package-path "${package_path}" -c release --product "${product}"; then
        printf "smoke-fetch: building %s from %s failed; the fetch manifest is incomplete or a swiftcheck source path is missing\n" "${product}" "${package_path}" >&2
        exit 1
    fi
}

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
