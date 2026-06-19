#!/usr/bin/env bash

set -euo pipefail

# Run one make target with the optional `DEVELOPMENT_TEAM` override that the
# reusable workflow forwards to unsigned read-only jobs.
main() {
    local make_target
    local make_args
    local team_id
    local -a make_argument_array
    local -a sign_argument_array
    local -a make_command

    make_target="${MAKE_TARGET:-}"
    make_args="${MAKE_ARGS:-}"
    team_id="${TEAM_ID:-}"
    if [[ -z "${make_target}" ]]; then
        printf 'run-make-with-team: MAKE_TARGET is empty\n' >&2
        exit 1
    fi

    make_argument_array=()
    if [[ -n "${make_args}" ]]; then
        read -r -a make_argument_array <<< "${make_args}"
    fi

    sign_argument_array=()
    if [[ -n "${team_id}" ]]; then
        sign_argument_array=("DEVELOPMENT_TEAM=${team_id}")
    fi

    # Bash 3.2 treats `${empty_array[@]}` as unbound under `set -u`, so build
    # the final argv incrementally instead of expanding optional arrays inline.
    make_command=("make" "${make_target}")
    if [[ ${#make_argument_array[@]} -gt 0 ]]; then
        make_command+=("${make_argument_array[@]}")
    fi
    if [[ ${#sign_argument_array[@]} -gt 0 ]]; then
        make_command+=("${sign_argument_array[@]}")
    fi

    "${make_command[@]}"
}

main "$@"
