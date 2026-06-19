#!/usr/bin/env bash

set -euo pipefail

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

make_command=("make" "${make_target}")
if [[ ${#make_argument_array[@]} -gt 0 ]]; then
    make_command+=("${make_argument_array[@]}")
fi
if [[ ${#sign_argument_array[@]} -gt 0 ]]; then
    make_command+=("${sign_argument_array[@]}")
fi

"${make_command[@]}"
