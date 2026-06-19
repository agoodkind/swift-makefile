#!/usr/bin/env bash

set -euo pipefail

make_target="${MAKE_TARGET:-}"
make_args="${MAKE_ARGS:-}"
cert_sha1="${CERT_SHA1:-}"
team_id="${TEAM_ID:-}"

if [[ -z "${make_target}" ]]; then
    printf 'run-make-with-signing: MAKE_TARGET is empty\n' >&2
    exit 1
fi

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

make "${make_target}" "${make_argument_array[@]}" "${sign_argument_array[@]}"
