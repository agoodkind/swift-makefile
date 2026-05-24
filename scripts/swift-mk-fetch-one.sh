#!/usr/bin/env bash
set -eo pipefail

relative_path="${1:?relative path is required}"
destination_path="${2:?destination path is required}"
developer_dir="${3:-${SWIFT_MK_DEV_DIR:-}}"
base_url="${SWIFT_MK_BASE_URL:-https://raw.githubusercontent.com/agoodkind/swift-makefile/main}"
api_repo="${SWIFT_MK_API_REPO:-agoodkind/swift-makefile}"
api_ref="${SWIFT_MK_API_REF:-main}"

mkdir -p "$(dirname "${destination_path}")"
temporary_path=$(mktemp "${destination_path}.tmp.XXXXXX")
error_path=$(mktemp "${destination_path}.err.XXXXXX")
cleanup_paths=("${temporary_path}" "${error_path}")

cleanup() {
    rm -f "${cleanup_paths[@]}"
}

trap cleanup EXIT

copy_from_developer_dir() {
    if [[ -z "${developer_dir}" || ! -f "${developer_dir}/${relative_path}" ]]; then
        return 1
    fi
    cp "${developer_dir}/${relative_path}" "${temporary_path}"
}

fetch_with_gh() {
    local gh_path

    gh_path=$(command -v gh || true)
    if [[ -z "${gh_path}" ]]; then
        return 1
    fi
    gh api "repos/${api_repo}/contents/${relative_path}?ref=${api_ref}" \
        -H "Accept: application/vnd.github.raw" \
        > "${temporary_path}" 2>"${error_path}"
}

fetch_with_raw_url() {
    curl -fsSL --connect-timeout 5 --max-time 10 \
        "${base_url}/${relative_path}?v=${EPOCHSECONDS:-$(date +%s)}" \
        -o "${temporary_path}" 2>"${error_path}"
}

fetch_with_plain_raw_url() {
    curl -fsSL --connect-timeout 5 --max-time 10 \
        "${base_url}/${relative_path}" \
        -o "${temporary_path}" 2>"${error_path}"
}

if copy_from_developer_dir || fetch_with_gh || fetch_with_raw_url || fetch_with_plain_raw_url; then
    if [[ ! -s "${temporary_path}" ]]; then
        printf "error: %s fetched empty body\n" "${relative_path}"
        exit 1
    fi
    mv "${temporary_path}" "${destination_path}"
    case "${destination_path}" in
        *.sh)
            chmod +x "${destination_path}"
            ;;
    esac
    exit 0
fi

printf "error: %s fetch failed. Run: gh auth login\n" "${relative_path}"
exit 1
