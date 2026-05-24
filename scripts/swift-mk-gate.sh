#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/swift-mk-common.sh"

gate_stamp=""
confirm_value=""
token_value=""
token_command=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stamp)
            gate_stamp="$2"
            shift 2
            ;;
        --confirm-value)
            confirm_value="$2"
            shift 2
            ;;
        --token-value)
            token_value="$2"
            shift 2
            ;;
        --token-command)
            token_command="$2"
            shift 2
            ;;
        *)
            printf "swift-mk-gate: unknown argument %s\n" "$1"
            exit 2
            ;;
    esac
done

if [[ -z "${gate_stamp}" || -z "${token_command}" ]]; then
    printf "swift-mk-gate: --stamp and --token-command are required\n"
    exit 2
fi

rm -f "${gate_stamp}"

case "${confirm_value}" in
    1 | y | yes | Y | YES)
        ;;
    *)
        exit 0
        ;;
esac

swift_mk_setup_temp_dir
expected_raw="${SWIFT_MK_TEMP_DIR}/expected-token.raw"
expected_error="${SWIFT_MK_TEMP_DIR}/expected-token.err"

if ! eval "${token_command}" > "${expected_raw}" 2>"${expected_error}"; then
    exit 0
fi

expected_token=$(swift_mk_slugify < "${expected_raw}" || true)
actual_token=$(printf "%s" "${token_value}" | swift_mk_slugify)

if [[ -z "${expected_token}" || -z "${actual_token}" ]]; then
    exit 0
fi

if [[ "${expected_token}" != "${actual_token}" ]]; then
    exit 0
fi

mkdir -p "$(dirname "${gate_stamp}")"
: > "${gate_stamp}"
