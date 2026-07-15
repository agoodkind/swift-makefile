#!/usr/bin/env bash
set -euo pipefail

tool_name="$(basename "$0")"
log_path="${SWIFT_MK_HELP_TRIPWIRE_LOG:?}"

printf '%s\n' "${tool_name}" >> "${log_path}"
printf 'tripwire: %s should not run in this test\n' "${tool_name}" >&2
exit 97
