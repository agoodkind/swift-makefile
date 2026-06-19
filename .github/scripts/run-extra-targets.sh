#!/usr/bin/env bash

set -euo pipefail

# Run each bespoke extra target after the shared required jobs, preserving the
# same optional signing arguments that the Build and Test jobs use.
main() {
    local extra_targets_shell
    local make_args
    local cert_sha1
    local team_id
    local target
    local -a extra_target_array
    local -a make_argument_array
    local -a sign_argument_array
    local -a make_command

    extra_targets_shell="${EXTRA_TARGETS_SHELL:-}"
    make_args="${MAKE_ARGS:-}"
    cert_sha1="${CERT_SHA1:-}"
    team_id="${TEAM_ID:-}"
    if [[ -z "${extra_targets_shell}" ]]; then
        printf 'run-extra-targets: EXTRA_TARGETS_SHELL is empty\n' >&2
        exit 1
    fi

    read -r -a extra_target_array <<< "${extra_targets_shell}"

    make_argument_array=()
    if [[ -n "${make_args}" ]]; then
        read -r -a make_argument_array <<< "${make_args}"
    fi

    sign_argument_array=()
    if [[ -n "${cert_sha1}" ]]; then
        sign_argument_array=("CODE_SIGN_IDENTITY=${cert_sha1}")
    fi
    if [[ -n "${team_id}" ]]; then
        sign_argument_array+=("DEVELOPMENT_TEAM=${team_id}")
    fi

    for target in "${extra_target_array[@]}"; do
        printf 'extra-targets: running %s\n' "${target}"

        # Bash 3.2 treats `${empty_array[@]}` as unbound under `set -u`, so
        # each `make` argv is assembled incrementally before execution.
        make_command=("make" "${target}")
        if [[ ${#make_argument_array[@]} -gt 0 ]]; then
            make_command+=("${make_argument_array[@]}")
        fi
        if [[ ${#sign_argument_array[@]} -gt 0 ]]; then
            make_command+=("${sign_argument_array[@]}")
        fi
        "${make_command[@]}"
    done
}

main "$@"
