#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/swift-mk-common.sh"

run_gate() {
    local component_name
    local stamp_path

    component_name="$1"
    stamp_path=".make/${component_name}-baseline.gate.ok"
    bash "${SCRIPT_DIR}/swift-mk-gate.sh" \
        --stamp "${stamp_path}" \
        --confirm-value "${BASELINE_CONFIRM:-}" \
        --token-value "${BASELINE_TOKEN:-}" \
        --token-command "${BASELINE_TOKEN_CMD:-${SWIFT_MK_GATE_TOKEN_CMD:-}}"
    [[ -f "${stamp_path}" ]]
}

normalize_mode() {
    local mode

    mode="${1:-sync}"
    case "${mode}" in
        sync | prune-fixed | remove-fixed | accept-new)
            printf "%s\n" "${mode}"
            ;;
        *)
            printf "unknown baseline update mode: %s\n" "${mode}"
            exit 2
            ;;
    esac
}

write_component_baseline() {
    local title
    local baseline_file
    local findings_file
    local label
    local mode
    local exclude_pattern
    local temporary_file

    title="$1"
    baseline_file="$2"
    findings_file="$3"
    label="$4"
    mode="$5"
    exclude_pattern="${6:-}"
    mkdir -p "$(dirname "${baseline_file}")"
    if [[ ! -f "${baseline_file}" ]]; then
        : > "${baseline_file}"
    fi
    temporary_file="${baseline_file}.tmp"
    printf "%s baseline update\n" "${label}"
    printf "  File: %s\n" "${baseline_file}"
    printf "  Mode: %s\n\n" "${mode}"
    swift_mk_print_baseline_update_counts "${label}" "${baseline_file}" "${findings_file}" "${label}" "${mode}" "${exclude_pattern}"
    swift_mk_write_baseline_file "${title}" "${baseline_file}" "${findings_file}" "${label}" "${temporary_file}" "${mode}"
    mv "${temporary_file}" "${baseline_file}"
    swift_mk_print_baseline_overall_counts "${label}" "${baseline_file}" "${findings_file}" "${label}" "${exclude_pattern}"
    printf "\n%s: baseline %s refreshed\n" "${label}" "${baseline_file}"
}

update_swiftlint_baseline() {
    local mode
    local raw_output
    local findings_output
    local exclude_pattern

    mode="$1"
    if ! run_gate "swiftlint"; then
        return 0
    fi
    mkdir -p .make
    raw_output=".make/swiftlint-baseline.raw.out"
    findings_output=".make/swiftlint-baseline.out"
    exclude_pattern=$(swift_mk_exclude_pattern "${SWIFTLINT_DEFAULT_EXCLUDE_PATHS:-}" "${SWIFTLINT_EXCLUDE_PATHS:-}")
    bash "${SCRIPT_DIR}/swift-mk-lint.sh" lint-tools
    bash "${SCRIPT_DIR}/swift-mk-lint.sh" capture-swiftlint "${raw_output}" "${findings_output}"
	    write_component_baseline \
	        "swiftlint" \
	        "${SWIFTLINT_BASELINE:-.swiftlint-baseline.txt}" \
	        "${findings_output}" \
	        "swiftlint" \
	        "${mode}" \
	        "${exclude_pattern}"
}

update_complexity_baseline() {
    local mode
    local raw_output
    local findings_output
    local exclude_pattern

    mode="$1"
    if ! run_gate "complexity"; then
        return 0
    fi
    mkdir -p .make
    raw_output=".make/lint-complexity-baseline.raw.out"
    findings_output=".make/lint-complexity-baseline.out"
    exclude_pattern=$(swift_mk_exclude_pattern "${SWIFTLINT_DEFAULT_EXCLUDE_PATHS:-}" "${SWIFTLINT_EXCLUDE_PATHS:-}")
    bash "${SCRIPT_DIR}/swift-mk-lint.sh" lint-tools
    bash "${SCRIPT_DIR}/swift-mk-lint.sh" capture-complexity "${raw_output}" "${findings_output}"
    write_component_baseline \
        "swiftlint-complexity" \
        "${SWIFTLINT_COMPLEXITY_BASELINE:-.swiftlint-complexity-baseline.txt}" \
        "${findings_output}" \
        "swiftlint-complexity" \
        "${mode}" \
        "${exclude_pattern}"
}

update_deadcode_baseline() {
    local mode
    local raw_output
    local findings_output
    local exclude_pattern

    mode="$1"
    if ! run_gate "deadcode"; then
        return 0
    fi
    mkdir -p .make
    raw_output=".make/periphery-baseline.raw.out"
    findings_output=".make/periphery-baseline.out"
    exclude_pattern=$(swift_mk_exclude_pattern "${PERIPHERY_DEFAULT_EXCLUDE_PATHS:-}" "${PERIPHERY_EXCLUDE_PATHS:-}")
    bash "${SCRIPT_DIR}/swift-mk-lint.sh" capture-deadcode "${raw_output}" "${findings_output}"
    write_component_baseline \
        "periphery" \
        "${PERIPHERY_BASELINE:-.periphery-baseline.txt}" \
        "${findings_output}" \
        "periphery" \
        "${mode}" \
        "${exclude_pattern}"
}

update_swiftcheck_baseline() {
    local mode
    local raw_output
    local findings_output
    local exclude_pattern

    mode="$1"
    if ! run_gate "swiftcheck-extra"; then
        return 0
    fi
    mkdir -p .make
    raw_output=".make/swiftcheck-extra.raw.out"
    findings_output=".make/swiftcheck-extra.out"
    exclude_pattern=$(swift_mk_exclude_pattern "${SWIFTCHECK_EXTRA_DEFAULT_EXCLUDE_PATHS:-}" "${SWIFTCHECK_EXTRA_EXCLUDE_PATHS:-}")
    bash "${SCRIPT_DIR}/swift-mk-swiftcheck-extra.sh" bin
    bash "${SCRIPT_DIR}/swift-mk-swiftcheck-extra.sh" capture "${raw_output}" "${findings_output}"
    write_component_baseline \
        "swiftcheck-extra" \
        "${SWIFTCHECK_EXTRA_BASELINE:-.swiftcheck-extra-baseline.txt}" \
        "${findings_output}" \
        "swiftcheck-extra" \
        "${mode}" \
        "${exclude_pattern}"
}

mode=$(normalize_mode "${BASELINE_UPDATE_MODE:-sync}")
component="${1:-all}"

case "${component}" in
    all)
        update_swiftlint_baseline "${mode}"
        update_complexity_baseline "${mode}"
        update_deadcode_baseline "${mode}"
        update_swiftcheck_baseline "${mode}"
        ;;
    swiftlint)
        update_swiftlint_baseline "${mode}"
        ;;
    complexity)
        update_complexity_baseline "${mode}"
        ;;
    deadcode)
        update_deadcode_baseline "${mode}"
        ;;
    swiftcheck-extra)
        update_swiftcheck_baseline "${mode}"
        ;;
    *)
        printf "swift-mk-baseline: unknown component %s\n" "${component}"
        exit 2
        ;;
esac
