#!/usr/bin/env bash
# Print the cache/asset key for the Linux swift-mk binary: "<source_hash>-<runtime_id>".
#
# Both setup-linux-swift-mk (the consumer side) and publish-linux-swift-mk (the build side) key
# on this exact value, so the recipe lives here once. If the two sides computed it separately and
# drifted by a byte, every consumer would miss and rebuild forever.
#
#   source_hash  hashes the checked-in engine sources that change the compiled binary, each
#                file's content paired with its repo-relative path, sorted. Run it BEFORE any
#                `swift build`, since a build can rewrite Package.resolved.
#   runtime_id   folds the Swift toolchain, glibc, and base OS, so a binary is only reused under
#                the identical runtime it was dynamically linked against.
#
# Correctness rests on failing loudly rather than emitting a partial key, because a partial key
# collides across revisions and silently restores the wrong binary. `set -e` alone is not trusted
# here: its propagation into command substitutions is version-dependent, so `set -E` plus an ERR
# trap that exits catches a failure anywhere, including inside a `$(...)`. Every required input and
# runtime signal is also checked explicitly, and the final key shape is validated, so no partial
# or empty value reaches stdout.
set -Eeuo pipefail
trap 'printf "swift-mk-asset-key: command failed (line %s)\n" "${LINENO}" >&2; exit 1' ERR

repo_root="${1:?repo root is required}"

require_file() {
    if [[ ! -f "$1" ]]; then
        printf 'swift-mk-asset-key: required file missing: %s\n' "$1" >&2
        exit 1
    fi
}

require_signal() {
    if [[ -z "$2" ]]; then
        printf 'swift-mk-asset-key: empty runtime signal: %s\n' "$1" >&2
        exit 1
    fi
}

# --- source hash ---
if [[ ! -d "${repo_root}/Sources" ]]; then
    printf 'swift-mk-asset-key: required directory missing: %s/Sources\n' "${repo_root}" >&2
    exit 1
fi
require_file "${repo_root}/Package.swift"
require_file "${repo_root}/scripts/swift-mk-build.sh"

file_list=$(mktemp)
trap 'rm -f "${file_list}"' EXIT

# `find` is its own command, so a failure (for example an unreadable subdirectory) is not masked by
# a following command in a group. Null-delimit so a path with whitespace cannot corrupt the hash.
# Package.resolved is gitignored in some checkouts, so it is the one optional input.
find "${repo_root}/Sources" -type f -print0 > "${file_list}"
printf '%s\0' "${repo_root}/Package.swift" >> "${file_list}"
printf '%s\0' "${repo_root}/scripts/swift-mk-build.sh" >> "${file_list}"
if [[ -f "${repo_root}/Package.resolved" ]]; then
    printf '%s\0' "${repo_root}/Package.resolved" >> "${file_list}"
fi

# Hash each file and validate its digest. A file that hashes to nothing was unreadable; without the
# check, its empty content hash would still fold into a valid-shaped final digest and a wrong key.
# Order does not matter: the pairs are sorted before the final digest.
pairs=""
while IFS= read -r -d '' path; do
    content_hash=$(shasum < "${path}" | awk '{ print $1 }')
    if [[ ! "${content_hash}" =~ ^[0-9a-f]{40}$ ]]; then
        printf 'swift-mk-asset-key: could not hash %s\n' "${path}" >&2
        exit 1
    fi
    pairs+="${content_hash}  ${path#"${repo_root}/"}"$'\n'
done < "${file_list}"
source_hash=$(printf '%s' "${pairs}" | LC_ALL=C sort | shasum | awk '{ print $1 }')

# --- runtime id ---
# Each signal is captured, checked non-empty, then folded. A signal command that fails fires the
# ERR trap; one that exits 0 with empty output is caught by require_signal.
swift_version=$(swift --version)
libc_version=$(getconf GNU_LIBC_VERSION)
os_release=$(cat /etc/os-release)
require_signal "swift --version" "${swift_version}"
require_signal "getconf GNU_LIBC_VERSION" "${libc_version}"
require_signal "/etc/os-release" "${os_release}"
runtime_id=$(printf '%s\n%s\n%s\n' "${swift_version}" "${libc_version}" "${os_release}" \
    | shasum | awk '{ print $1 }')

# --- key ---
# Final shape guard: two 40-hex shasum digests joined by a dash. Anything partial or empty cannot
# pass, so a malformed key is never printed and never keys a cache or an asset.
key="${source_hash}-${runtime_id}"
if [[ ! "${key}" =~ ^[0-9a-f]{40}-[0-9a-f]{40}$ ]]; then
    printf 'swift-mk-asset-key: computed a malformed key: %q\n' "${key}" >&2
    exit 1
fi
printf '%s\n' "${key}"
