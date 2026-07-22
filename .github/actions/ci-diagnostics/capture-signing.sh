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

# probe_codesign_session LABEL LAUNCHER...: run, inside the session the launcher
# reaches, a user-list set followed by codesign against a scratch Mach-O, and
# record the exit code. The launcher is a command prefix such as
# `launchctl asuser <uid>`. The inner script sets the user keychain search list
# to the signing keychain (honored in a login session), prints the session it
# landed in, then signs, so the recorded rc and managername show whether that
# launcher is a viable broker fix.
probe_codesign_session() {
    local label="$1"
    shift
    local scratch rc inner

    scratch="$(mktemp -t codesign-sess)"
    cp /bin/echo "${scratch}"
    if ! file "${scratch}" | grep -q 'Mach-O'; then
        printf 'codesign-session[%s]: scratch is not a Mach-O, probe invalid\n' "${label}"
        rm -f "${scratch}"
        return 0
    fi

    # Build the in-session script with quoted paths. Keep stderr on every command
    # because the list set is a precondition whose failure explains a codesign
    # failure, and the managername shows which session codesign actually ran in.
    inner="$(printf 'security list-keychains -d user -s %q %q; /bin/launchctl managername; codesign --verbose=4 --force --sign %q --keychain %q %q' \
        "${keychain}" "${system_keychain}" "${identity_sha1}" "${keychain}" "${scratch}")"

    printf '\n=== codesign-session[%s]: %s ===\n' "${label}" "$*"
    rc=0
    "$@" /bin/sh -c "${inner}" || rc=$?
    printf 'codesign-session[%s] rc=%s\n' "${label}" "${rc}"

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

    # Session mechanism probes. Prior runs proved no security list-keychains
    # variant adds the signing keychain to the search list in the System session,
    # so codesign cannot resolve the identity here. The broker fix runs the runner
    # in the admin user's login session instead. These probes test whether
    # launchctl asuser reaches such a session for this uid and whether codesign
    # succeeds there, so the broker change is verified before it is written.
    local admin_uid
    admin_uid="$(id -u)"
    printf '\n### SESSION MECHANISM PROBES (uid %s) ###\n' "${admin_uid}"

    # Is passwordless sudo available. asuser needs root, and the guest agent runs
    # as non-root admin, so the broker fix depends on this.
    run sudo -n /usr/bin/true

    # Which session each launcher reaches. A non-System managername means the
    # launcher moved into a login session where user keychains are honored.
    run /bin/launchctl asuser "${admin_uid}" /bin/launchctl managername
    run sudo -n /bin/launchctl asuser "${admin_uid}" /bin/launchctl managername

    # codesign inside the login session. Each launcher sets the user search list
    # to include the signing keychain, prints the session it landed in, then signs
    # a scratch Mach-O. rc=0 identifies the launcher the broker should use.
    probe_codesign_session asuser-nosudo /bin/launchctl asuser "${admin_uid}"
    probe_codesign_session asuser-sudo sudo -n /bin/launchctl asuser "${admin_uid}"
    probe_codesign_session asuser-sudo-asadmin \
        sudo -n /bin/launchctl asuser "${admin_uid}" sudo -u admin
}

# One recovery boundary: the diagnostic is best-effort and must not fail the
# pre-build step, so its failure is contained and reported here, not propagated.
if ! diagnostics >"${log}" 2>&1; then
    printf 'signing diagnostics exited non-zero; see %s\n' "${log}"
fi

printf 'wrote %s\n' "${log}"
exit 0
