#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SHARED_ROOT="${SWIFT_MK_DEV_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
MANIFEST_PATH="${SWIFT_MK_CONSUMER_MANIFEST:-}"
ROOTS_TEXT="${SWIFT_MK_CONSUMER_ROOTS:-/Users/agoodkind/Sites}"
INCLUDE_DIRTY="${SWIFT_MK_UPDATE_INCLUDE_DIRTY:-0}"
VALIDATE_TARGET="${SWIFT_MK_UPDATE_VALIDATE:-}"
MODE="${1:-dry-run}"

discover_repos_from_manifest() {
    if [[ -z "${MANIFEST_PATH}" || ! -f "${MANIFEST_PATH}" ]]; then
        return 1
    fi
    cat "${MANIFEST_PATH}"
}

discover_repos_from_roots() {
    local root_path
    local makefile_path
    local repo_path

    for root_path in ${ROOTS_TEXT}; do
        find "${root_path}" -name Makefile | while IFS= read -r makefile_path; do
            repo_path=$(dirname "${makefile_path}")
            if grep -Eq '^(include|-include) bootstrap\.mk$' "${makefile_path}" && [[ -f "${repo_path}/bootstrap.mk" ]] && grep -q 'swift-makefile' "${repo_path}/bootstrap.mk"; then
                printf "%s\n" "${repo_path}"
            fi
        done
    done
}

repo_list() {
    if discover_repos_from_manifest; then
        return 0
    fi
    discover_repos_from_roots
}

is_dirty_repo() {
    local repo_path="$1"
    local status_output

    status_output=$(git -C "${repo_path}" status --short)
    [[ -n "${status_output}" ]]
}

run_repo_update() {
    local repo_path="$1"
    local dirty_state="clean"

    if is_dirty_repo "${repo_path}"; then
        dirty_state="dirty"
    fi

    printf "repo: %s\n" "${repo_path}"
    printf "  source: %s\n" "${SHARED_ROOT}"
    printf "  dirty: %s\n" "${dirty_state}"

    if [[ "${MODE}" == "dry-run" || "${SWIFT_MK_UPDATE_DRY_RUN:-0}" == "1" ]]; then
        printf "  planned writes: bootstrap.mk, .make/\n"
        printf "  validation: make help"
        if [[ -n "${VALIDATE_TARGET}" ]]; then
            printf ", make %s" "${VALIDATE_TARGET}"
        fi
        printf "\n"
        if [[ "${dirty_state}" == "dirty" && "${INCLUDE_DIRTY}" != "1" ]]; then
            printf "  action: would skip dirty repo\n"
        else
            printf "  action: would update repo\n"
        fi
        return 0
    fi

    if [[ "${dirty_state}" == "dirty" && "${INCLUDE_DIRTY}" != "1" ]]; then
        printf "  action: skipped dirty repo\n"
        return 0
    fi

    cp "${SHARED_ROOT}/bootstrap.mk" "${repo_path}/bootstrap.mk"
    (
        cd "${repo_path}"
        SWIFT_MK_DEV_DIR="${SHARED_ROOT}" make update-swift-mk
        SWIFT_MK_DEV_DIR="${SHARED_ROOT}" make help
        if [[ -n "${VALIDATE_TARGET}" ]]; then
            SWIFT_MK_DEV_DIR="${SHARED_ROOT}" make "${VALIDATE_TARGET}"
        fi
    )
}

repo_list | awk 'NF' | sort -u | while IFS= read -r repo_path; do
    run_repo_update "${repo_path}"
done
