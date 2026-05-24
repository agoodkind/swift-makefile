#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FETCH_SCRIPT="${SCRIPT_DIR}/swift-mk-fetch-one.sh"

asset_list() {
    printf "swift.mk\n"
    printf ".swiftlint.yml\n"
    printf ".swift-format\n"
    printf ".periphery.yml\n"
    printf "swift-build.mk\n"
    printf "swift-release.mk\n"
    printf "scripts/swift-mk-fetch-one.sh\n"
    printf "scripts/swift-mk-common.sh\n"
    printf "scripts/swift-mk-gate.sh\n"
    printf "scripts/swift-mk-findings.awk\n"
    printf "scripts/swift-mk-baseline.awk\n"
    printf "scripts/swift-mk-lint.sh\n"
    printf "scripts/swift-mk-baseline.sh\n"
    printf "scripts/swift-mk-swiftcheck-extra.sh\n"
    printf "scripts/swift-mk-sync.sh\n"
    printf "scripts/swift-mk-fleet-update.sh\n"
    printf "scripts/install-hooks.sh\n"
    printf "hooks/pre-commit\n"
    printf "swiftcheck/Package.swift\n"
    printf "swiftcheck/Sources/swiftcheck-extra/main.swift\n"
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
    printf "smoke-fetch: OK (%s assets fetched into .make/)\n" "${count_output}"
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
