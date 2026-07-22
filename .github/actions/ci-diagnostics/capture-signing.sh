#!/usr/bin/env bash
#
# capture-signing.sh
#
# Capture why codesign cannot use an imported Developer ID private key on the
# self-hosted pool. The certificate imports and find-identity lists it, yet
# codesign and xcodebuild report no usable identity, so this dumps the signing
# keychain's lock state, the private key's access control list, both identity
# search scopes, and a direct codesign probe with its exact error. Best effort:
# every command is allowed to fail so the diagnostic never breaks the job.
#
# Usage: capture-signing.sh <out_dir> <signing_keychain_db_path> [identity_sha1]

set -uo pipefail

out_dir="${1:?out_dir required}"
keychain="${2:-}"
identity_sha1="${3:-}"

mkdir -p "${out_dir}"
log="${out_dir}/signing-diagnostics.txt"

run() {
    printf '\n=== %s ===\n' "$*"
    "$@" 2>&1 || printf '(exit %s)\n' "$?"
}

{
    printf 'captured: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'user: %s (uid %s)\n' "$(id -un 2>/dev/null)" "$(id -u 2>/dev/null)"
    printf 'security_session: %s\n' "$(/usr/bin/security -q list-keychains 2>/dev/null | tr '\n' ' ')"
    printf 'signing_keychain: %s\n' "${keychain}"
    printf 'identity_sha1: %s\n' "${identity_sha1}"

    run /usr/bin/security list-keychains -d user
    run /usr/bin/security default-keychain -d user
    run /usr/bin/security default-keychain

    if [[ -n "${keychain}" ]]; then
        run /usr/bin/security show-keychain-info "${keychain}"
        run /usr/bin/security find-identity -v -p codesigning "${keychain}"
        # Access control list and partition list for the imported key. Strip
        # non-printable bytes so the blob stays readable in the artifact.
        printf '\n=== dump-keychain -a (access + partition list) ===\n'
        /usr/bin/security dump-keychain -a "${keychain}" 2>&1 | tr -cd '[:print:]\t\n' || printf '(dump exit %s)\n' "$?"
    fi

    run /usr/bin/security find-identity -v -p codesigning

    # Direct codesign probe against a scratch Mach-O, so the exact errSec that
    # signing hits is captured next to the keychain state above.
    if [[ -n "${identity_sha1}" ]]; then
        scratch="$(mktemp -t codesign-probe)"
        cp /bin/echo "${scratch}" 2>/dev/null || printf 'copy /bin/echo failed\n'
        printf '\n=== codesign --verbose=4 probe (explicit keychain) ===\n'
        if [[ -n "${keychain}" ]]; then
            codesign --verbose=4 --force --sign "${identity_sha1}" --keychain "${keychain}" "${scratch}" 2>&1
            printf 'codesign explicit-keychain rc=%s\n' "$?"
        fi
        printf '\n=== codesign --verbose=4 probe (default search list) ===\n'
        codesign --verbose=4 --force --sign "${identity_sha1}" "${scratch}" 2>&1
        printf 'codesign default-search rc=%s\n' "$?"
        rm -f "${scratch}"
    fi
} >"${log}" 2>&1 || true

printf 'wrote %s\n' "${log}"
