#!/usr/bin/env bash
set -eu

HOOKS_DEST_DIR="${SWIFT_MK_HOOKS_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/swift-makefile/hooks}"
HOOK_NAME="pre-commit"

resolve_canonical_hook() {
    if [[ -n "${SWIFT_MK_DEV_DIR:-}" && -f "${SWIFT_MK_DEV_DIR}/hooks/${HOOK_NAME}" ]]; then
        printf '%s\n' "${SWIFT_MK_DEV_DIR}/hooks/${HOOK_NAME}"
        return 0
    fi

    mkdir -p "${HOOKS_DEST_DIR}"
    local target="${HOOKS_DEST_DIR}/${HOOK_NAME}"
    local gh_path
    gh_path=$(command -v gh || true)

    if [[ -n "${gh_path}" ]] && gh api "repos/agoodkind/swift-makefile/contents/hooks/${HOOK_NAME}?ref=main" -H "Accept: application/vnd.github.raw" > "${target}"; then
        chmod +x "${target}"
        printf '%s\n' "${target}"
        return 0
    fi

    if curl -fsSL --connect-timeout 5 --max-time 10 \
        "https://raw.githubusercontent.com/agoodkind/swift-makefile/main/hooks/${HOOK_NAME}" \
        -o "${target}"; then
        chmod +x "${target}"
        printf '%s\n' "${target}"
        return 0
    fi

    printf 'install-hooks: cannot fetch canonical hook\n'
    return 1
}

git_dir=$(git rev-parse --git-dir) || {
    printf 'install-hooks: not in a git repo\n'
    exit 1
}

canonical=$(resolve_canonical_hook)
hook_link="${git_dir}/hooks/${HOOK_NAME}"
mkdir -p "${git_dir}/hooks"

if [[ -L "${hook_link}" && "$(readlink "${hook_link}")" == "${canonical}" ]]; then
    printf 'install-hooks: %s already linked to %s\n' "${hook_link}" "${canonical}"
    exit 0
fi

if [[ -e "${hook_link}" && ! -L "${hook_link}" ]]; then
    backup="${hook_link}.backup.$(date +%s)"
    mv "${hook_link}" "${backup}"
    printf 'install-hooks: existing hook moved to %s\n' "${backup}"
fi

ln -sfn "${canonical}" "${hook_link}"
printf 'install-hooks: linked %s -> %s\n' "${hook_link}" "${canonical}"
