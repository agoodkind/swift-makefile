#!/usr/bin/env bash
#
# capture-signing.sh
#
# Capture why codesign cannot use an imported Developer ID private key on the
# self-hosted pool. The certificate imports and find-identity lists it, yet
# codesign reports no usable identity. This dumps the keychain search lists that
# codesign resolves through, the signing keychain lock state, the imported key
# access control list and partition list, and a baseline codesign probe. It then
# applies fix candidates that put the signing keychain into a different search
# list and re-probes codesign, so one pool run names the command that lets
# codesign resolve the identity.
#
# This is a best-effort PRE-BUILD diagnostic. It must never fail the job, so the
# diagnostic body runs under one recovery boundary and the script exits 0. Each
# probe command captures its own exit code as data, because a probe failing is
# the signal being collected, not a script error.
#
# Usage: capture-signing.sh <out_dir> <signing_keychain_db_path> [identity_sha1]

set -euo pipefail

out_dir="${1:?out_dir required}"
keychain="${2:-}"
identity_sha1="${3:-}"

mkdir -p "${out_dir}"
log="${out_dir}/signing-diagnostics.txt"

system_keychain="/Library/Keychains/System.keychain"

# run CMD...: run a command, keep stdout and stderr, and record a nonzero exit.
# The trailing || keeps this safe under set -e so a failing probe is captured as
# data instead of aborting the script.
run() {
    printf '\n=== %s ===\n' "$*"
    local rc=0
    "$@" || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        printf '(exit %s)\n' "${rc}"
    fi
}

# probe_codesign LABEL: sign a scratch Mach-O and record codesign's exit code
# for both the explicit-keychain and default-search identity resolutions.
probe_codesign() {
    local label="$1"
    local scratch rc

    scratch="$(mktemp -t codesign-probe)"
    cp /bin/echo "${scratch}"
    # Verify the scratch is a signable Mach-O before trusting a codesign failure,
    # so a bad copy does not masquerade as a signing failure.
    if ! file "${scratch}" | grep -q 'Mach-O'; then
        printf 'codesign[%s]: scratch is not a Mach-O, probe invalid\n' "${label}"
        rm -f "${scratch}"
        return 0
    fi

    if [[ -n "${keychain}" ]]; then
        printf '\n--- codesign[%s] explicit-keychain ---\n' "${label}"
        rc=0
        codesign --verbose=4 --force --sign "${identity_sha1}" \
            --keychain "${keychain}" "${scratch}" || rc=$?
        printf 'codesign[%s] explicit-keychain rc=%s\n' "${label}" "${rc}"
    fi

    printf '\n--- codesign[%s] default-search ---\n' "${label}"
    rc=0
    codesign --verbose=4 --force --sign "${identity_sha1}" "${scratch}" || rc=$?
    printf 'codesign[%s] default-search rc=%s\n' "${label}" "${rc}"

    rm -f "${scratch}"
}

diagnostics() {
    printf 'captured: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'user: %s (uid %s)\n' "$(id -un)" "$(id -u)"
    printf 'signing_keychain: %s\n' "${keychain}"
    printf 'identity_sha1: %s\n' "${identity_sha1}"

    # Session type. A non-Aqua (Background/StandardIO) session is why securityd
    # refuses to add a user keychain to the search list, so codesign cannot
    # resolve the identity even though find-identity opens the keychain by path.
    run /bin/launchctl managername

    # The list with no -d is the effective session list codesign resolves
    # through. Compare it against the user, dynamic, and common domains to see
    # which list the signing keychain actually reaches.
    run /usr/bin/security list-keychains
    run /usr/bin/security list-keychains -d user
    run /usr/bin/security list-keychains -d dynamic
    run /usr/bin/security list-keychains -d common
    run /usr/bin/security default-keychain -d user
    run /usr/bin/security default-keychain

    if [[ -z "${keychain}" ]]; then
        printf '\nno signing keychain path given; skipping keychain-specific probes\n'
        return 0
    fi

    run /usr/bin/security show-keychain-info "${keychain}"
    run /usr/bin/security find-identity -v -p codesigning "${keychain}"

    # Access control list and partition list for the imported key. Strip
    # non-printable bytes so the blob stays readable, and report a dump failure.
    printf '\n=== dump-keychain -a (access + partition list) ===\n'
    local rc=0
    /usr/bin/security dump-keychain -a "${keychain}" | tr -cd '[:print:]\t\n' || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        printf '(dump-keychain exit %s)\n' "${rc}"
    fi

    run /usr/bin/security find-identity -v -p codesigning

    if [[ -z "${identity_sha1}" ]]; then
        printf '\nno identity sha1 given; skipping codesign probes\n'
        return 0
    fi

    # Baseline: the state the real build sees.
    probe_codesign baseline

    # Hypothesis test, not a known fix. Verified: no security list-keychains
    # variant changes the running session's effective list, and entering the
    # existing boot Aqua session with launchctl asuser still fails. Two competing
    # explanations remain and this run discriminates them:
    #   H1 search-list: codesign resolves the identity only through the session's
    #     effective search list, which never contains the per-job keychain here.
    #   H2 key-access: the identity is found but the private key cannot be used
    #     in this session, and codesign reports that as "no identity found".
    # Each fresh-session primitive below sets admin's user-domain list first, then
    # runs an inner script that prints the session name, the effective list, and
    # find-identity (default) BEFORE codesign. If a session's effective list gains
    # the keychain and find-identity default sees it, H1 is testable there; if it
    # does and codesign still fails, that is evidence for H2.
    printf '\n### FRESH SESSION HYPOTHESIS PROBES ###\n'
    run sudo -n /usr/bin/true

    # Set the login user's (admin) user-domain list under admin's own home before
    # any session is created. A login session reads the list from the login
    # user's home plist, so this is the state a fresh admin session would inherit.
    run env HOME=/Users/admin /usr/bin/security list-keychains -d user -s "${keychain}" "${system_keychain}"
    run env HOME=/Users/admin /usr/bin/security list-keychains -d user

    local inner scratch
    scratch="$(mktemp -t codesign-fresh)"
    cp /bin/echo "${scratch}"
    if ! file "${scratch}" | grep -q 'Mach-O'; then
        printf 'fresh-session: scratch is not a Mach-O, probe invalid\n'
        rm -f "${scratch}"
        return 0
    fi

    # Inner script observed inside whatever session the primitive creates. It
    # reports the session, its effective search list, the default-search identity
    # lookup, then signs through the explicit keychain and the default search,
    # recording each exit code so H1 and H2 look different in the output.
    # The $(...) and $HOME in this template must expand inside the fresh session
    # at runtime, not now, so single quotes are intentional. Only the %q paths are
    # substituted by printf here.
    # shellcheck disable=SC2016
    inner="$(printf 'echo whoami=$(id -un) home=$HOME; echo managername=$(/bin/launchctl managername); echo "--- effective list ---"; /usr/bin/security list-keychains; echo "--- find-identity default ---"; /usr/bin/security find-identity -v -p codesigning; echo "--- codesign explicit-keychain ---"; /usr/bin/codesign --verbose=4 --force --sign %q --keychain %q %q; echo fresh-codesign-explicit-rc=$?; echo "--- codesign default-search ---"; /usr/bin/codesign --verbose=4 --force --sign %q %q; echo fresh-codesign-default-rc=$?' \
        "${identity_sha1}" "${keychain}" "${scratch}" "${identity_sha1}" "${scratch}")"

    local rc

    # Primitive 1: /usr/bin/login opens a new security session via PAM. It has no
    # command argument on macOS, so the inner script is fed on stdin to the login
    # shell. This is the primitive most likely to create a genuinely fresh session.
    printf '\n=== fresh session via login -fpq admin (stdin) ===\n'
    rc=0
    printf '%s\n' "${inner}" | sudo -n /usr/bin/login -fpq admin || rc=$?
    printf 'fresh-login outer rc=%s\n' "${rc}"

    # Primitive 2 (control): sudo -u admin -i runs a login shell but may inherit
    # the caller's System audit session rather than create a new one. Comparing
    # its managername and effective list against primitive 1 shows whether a new
    # session was actually created.
    printf '\n=== control session via sudo -u admin -i sh -c ===\n'
    rc=0
    sudo -n -u admin -i /bin/sh -c "${inner}" || rc=$?
    printf 'control-sudo-i outer rc=%s\n' "${rc}"

    rm -f "${scratch}"
}

# One recovery boundary: the diagnostic is best-effort and must not fail the
# pre-build step, so its failure is contained and reported here, not propagated.
if ! diagnostics >"${log}" 2>&1; then
    printf 'signing diagnostics exited non-zero; see %s\n' "${log}"
fi

printf 'wrote %s\n' "${log}"
exit 0
