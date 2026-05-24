#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/swift-mk-common.sh"

SWIFT_FINDING_PATTERN='^[^[:space:]][^:]+:[0-9]+:[0-9]+:'

swift_format_command() {
    local mode="$1"

    swift_mk_split_words "${SWIFT_FORMAT:-xcrun swift-format}"
    if [[ "${mode}" == "format" ]]; then
        SWIFT_MK_WORDS=("${SWIFT_MK_WORDS[@]}" format --in-place --recursive --configuration "${SWIFT_MK_SWIFT_FORMAT_CONFIG:-.make/.swift-format}")
    else
        SWIFT_MK_WORDS=("${SWIFT_MK_WORDS[@]}" lint --strict --recursive --configuration "${SWIFT_MK_SWIFT_FORMAT_CONFIG:-.make/.swift-format}")
    fi
    SWIFT_MK_WORDS_COUNT=${#SWIFT_MK_WORDS[@]}
}

swift_format_targets() {
    local targets_text

    if [[ -n "${LINT_FILES:-}" ]]; then
        targets_text="${LINT_FILES}"
    else
        targets_text="${SWIFT_FORMAT_TARGETS:-Sources Tests Package.swift}"
    fi
    swift_mk_split_words "${targets_text}"
}

swiftlint_flag_args() {
    local flags_text

    flags_text="${SWIFTLINT_FLAGS:---config .make/.swiftlint.yml --reporter xcode}"
    swift_mk_split_words "${flags_text}"
}

swiftlint_target_args() {
    local targets_text

    if [[ -n "${LINT_FILES:-}" ]]; then
        targets_text="${LINT_FILES}"
    else
        targets_text="${SWIFTLINT_TARGETS:-Sources Tests Package.swift}"
    fi
    swift_mk_split_words "${targets_text}"
}

swiftlint_files_env() {
    local files_text="$1"
    local file_path
    local count=0

    SWIFT_MK_WORDS=()
    while IFS= read -r file_path; do
        [[ -n "${file_path}" ]] || continue
        SWIFT_MK_WORDS+=("SCRIPT_INPUT_FILE_${count}=${file_path}")
        count=$((count + 1))
    done < <(printf "%s\n" ${files_text})
    SWIFT_MK_WORDS+=("SCRIPT_INPUT_FILE_COUNT=${count}")
    SWIFT_MK_WORDS_COUNT=${#SWIFT_MK_WORDS[@]}
}

filter_ranges_if_needed() {
    local input_file="$1"
    local output_file="$2"

    if [[ -z "${LINT_LINE_RANGES:-}" || ! -s "${LINT_LINE_RANGES}" ]]; then
        cat "${input_file}" > "${output_file}"
        return
    fi

    awk -v action=linefilter -f "$(swift_mk_findings_awk)" "${LINT_LINE_RANGES}" "${input_file}" > "${output_file}"
}

print_or_gate_findings() {
    local gate_name="$1"
    local findings_file="$2"
    local baseline_file="$3"
    local label="$4"
    local remediation_text="$5"
    local exclude_pattern="$6"

    if [[ -z "${BASELINE:-1}" ]]; then
        if [[ -s "${findings_file}" ]]; then
            printf "%s findings:\n" "${gate_name}"
            swift_mk_print_findings < "${findings_file}"
            swift_mk_record_failed_gate "${gate_name}"
            return 1
        fi
        printf "%s: OK\n" "${gate_name}"
        printf "  Findings: 0\n"
        return 0
    fi

    swift_mk_run_baseline_diff_gate \
        "${gate_name}" \
        "${findings_file}" \
        "${baseline_file}" \
        "${label}" \
        "${remediation_text}" \
        "${exclude_pattern}"
}

capture_swiftlint_findings() {
    local raw_output="$1"
    local findings_output="$2"
    local exclude_pattern
    local scoped_output
    local flag_args=()
    local target_args=()
    local env_args=()

    swift_mk_setup_temp_dir
    exclude_pattern=$(swift_mk_exclude_pattern "${SWIFTLINT_DEFAULT_EXCLUDE_PATHS:-}" "${SWIFTLINT_EXCLUDE_PATHS:-}")
    swiftlint_flag_args
    flag_args=("${SWIFT_MK_WORDS[@]}")

    if [[ -n "${LINT_FILES:-}" ]]; then
        swiftlint_files_env "${LINT_FILES}"
        env_args=("${SWIFT_MK_WORDS[@]}")
        swift_mk_run_lint_capture "${raw_output}" env "${env_args[@]}" "${SWIFTLINT:-swiftlint}" lint --strict --use-script-input-files "${flag_args[@]}"
    else
        swiftlint_target_args
        target_args=("${SWIFT_MK_WORDS[@]}")
        swift_mk_run_lint_capture "${raw_output}" "${SWIFTLINT:-swiftlint}" lint --strict "${flag_args[@]}" "${target_args[@]}"
    fi

    scoped_output="${SWIFT_MK_TEMP_DIR}/swiftlint-findings.out"
    swift_mk_extract_findings "${raw_output}" "${scoped_output}" "${SWIFT_FINDING_PATTERN}" "${exclude_pattern}"
    filter_ranges_if_needed "${scoped_output}" "${findings_output}"
}

run_lint_tools() {
    local version_output

    mkdir -p .make
    version_output=".make/swift-format.version.out"
    swift_mk_run_capture "${version_output}" xcrun swift-format --version
    if [[ "${SWIFT_MK_COMMAND_STATUS}" -ne 0 ]]; then
        cat "${version_output}"
        return "${SWIFT_MK_COMMAND_STATUS}"
    fi
    if ! command -v swiftlint >/dev/zero; then
        brew install swiftlint
    fi
    if ! command -v periphery >/dev/zero; then
        brew install periphery
    fi
    if ! command -v osv-scanner >/dev/zero; then
        brew install osv-scanner
    fi
    bash "${SCRIPT_DIR}/swift-mk-swiftcheck-extra.sh" bin
}

run_lint_swiftlint() {
    local raw_output=".make/swiftlint.raw.out"
    local findings_output=".make/swiftlint.out"
    local exclude_pattern
    local run_status

    mkdir -p .make
    exclude_pattern=$(swift_mk_exclude_pattern "${SWIFTLINT_DEFAULT_EXCLUDE_PATHS:-}" "${SWIFTLINT_EXCLUDE_PATHS:-}")
    capture_swiftlint_findings "${raw_output}" "${findings_output}"
    run_status="${SWIFT_MK_COMMAND_STATUS}"

    if ! print_or_gate_findings \
        "swiftlint" \
        "${findings_output}" \
        "${SWIFTLINT_BASELINE:-.swiftlint-baseline.txt}" \
        "swiftlint" \
        "Fix these findings in code. Do not disable, silence, weaken, or otherwise circumvent the checks." \
        "${exclude_pattern}"; then
        return 1
    fi

    if [[ "${run_status}" -ne 0 && ! -s "${findings_output}" ]]; then
        printf "swiftlint: FAILED\n"
        printf "  Exit status: %s\n\n" "${run_status}"
        printf "Output:\n"
        cat "${raw_output}"
        swift_mk_record_failed_gate "swiftlint"
        return "${run_status}"
    fi
}

run_lint_format() {
    local output_file=".make/lint-format.out"
    local target_args=()

    mkdir -p .make
    swift_format_command lint
    swift_format_targets
    target_args=("${SWIFT_MK_WORDS[@]}")
    swift_format_command lint
    swift_mk_run_lint_capture "${output_file}" "${SWIFT_MK_WORDS[@]}" "${target_args[@]}"

    if [[ -s "${output_file}" ]]; then
        printf "lint-format: FAILED\n"
        cat "${output_file}"
        swift_mk_record_failed_gate "lint-format"
        return 1
    fi

    if [[ "${SWIFT_MK_COMMAND_STATUS}" -ne 0 ]]; then
        printf "lint-format: FAILED\n"
        printf "  Exit status: %s\n" "${SWIFT_MK_COMMAND_STATUS}"
        swift_mk_record_failed_gate "lint-format"
        return "${SWIFT_MK_COMMAND_STATUS}"
    fi
}

capture_complexity_findings() {
    local raw_output="$1"
    local findings_output="$2"
    local exclude_pattern
    local scoped_output
    swift_mk_setup_temp_dir
    local flag_args=()
    local target_args=()
    local env_args=()
    local rule_names=()
    local rule_name

    exclude_pattern=$(swift_mk_exclude_pattern "${SWIFTLINT_DEFAULT_EXCLUDE_PATHS:-}" "${SWIFTLINT_EXCLUDE_PATHS:-}")
    scoped_output="${SWIFT_MK_TEMP_DIR}/lint-complexity.filtered.out"
    swiftlint_flag_args
    flag_args=("${SWIFT_MK_WORDS[@]}")
    swiftlint_target_args
    target_args=("${SWIFT_MK_WORDS[@]}")
    IFS=',' read -r -a rule_names <<< "${COMPLEXITY_RULES:-cyclomatic_complexity,function_body_length,closure_body_length,file_length,type_body_length,function_parameter_count,large_tuple,nesting,todo}"
    for rule_name in "${rule_names[@]}"; do
        flag_args+=(--only-rule "${rule_name}")
    done

    if [[ -n "${LINT_FILES:-}" ]]; then
        swiftlint_files_env "${LINT_FILES}"
        env_args=("${SWIFT_MK_WORDS[@]}")
        swift_mk_run_lint_capture "${raw_output}" env "${env_args[@]}" "${SWIFTLINT:-swiftlint}" lint --strict --use-script-input-files "${flag_args[@]}"
    else
        swift_mk_run_lint_capture "${raw_output}" "${SWIFTLINT:-swiftlint}" lint --strict "${flag_args[@]}" "${target_args[@]}"
    fi

    swift_mk_extract_findings "${raw_output}" "${scoped_output}" "${SWIFT_FINDING_PATTERN}" "${exclude_pattern}"
    filter_ranges_if_needed "${scoped_output}" "${findings_output}"
}

run_lint_complexity() {
    local raw_output=".make/lint-complexity.raw.out"
    local findings_output=".make/lint-complexity.out"
    local exclude_pattern
    local run_status

    mkdir -p .make
    exclude_pattern=$(swift_mk_exclude_pattern "${SWIFTLINT_DEFAULT_EXCLUDE_PATHS:-}" "${SWIFTLINT_EXCLUDE_PATHS:-}")
    capture_complexity_findings "${raw_output}" "${findings_output}"
    run_status="${SWIFT_MK_COMMAND_STATUS}"

    if ! print_or_gate_findings \
        "lint-complexity" \
        "${findings_output}" \
        "${SWIFTLINT_COMPLEXITY_BASELINE:-.swiftlint-complexity-baseline.txt}" \
        "swiftlint-complexity" \
        "Fix these findings in code. Do not disable, silence, weaken, or otherwise circumvent the checks." \
        "${exclude_pattern}"; then
        return 1
    fi

    if [[ "${run_status}" -ne 0 && ! -s "${findings_output}" ]]; then
        printf "lint-complexity: FAILED\n"
        printf "  Exit status: %s\n\n" "${run_status}"
        printf "Output:\n"
        cat "${raw_output}"
        swift_mk_record_failed_gate "lint-complexity"
        return "${run_status}"
    fi
}

capture_deadcode_findings() {
    local raw_output="$1"
    local findings_output="$2"
    local exclude_pattern
    swift_mk_setup_temp_dir
    local scoped_output="${SWIFT_MK_TEMP_DIR}/periphery-findings.out"

    exclude_pattern=$(swift_mk_exclude_pattern "${PERIPHERY_DEFAULT_EXCLUDE_PATHS:-}" "${PERIPHERY_EXCLUDE_PATHS:-}")
    swift_mk_split_words "${PERIPHERY_ARGS:-scan --config .make/.periphery.yml --strict}"
    periphery_args=("${SWIFT_MK_WORDS[@]}")
    swift_mk_run_lint_capture "${raw_output}" "${PERIPHERY:-periphery}" "${periphery_args[@]}"
    swift_mk_extract_findings "${raw_output}" "${scoped_output}" "${SWIFT_FINDING_PATTERN}" "${exclude_pattern}"
    filter_ranges_if_needed "${scoped_output}" "${findings_output}"
}

run_lint_deadcode() {
    local raw_output=".make/periphery.raw.out"
    local findings_output=".make/periphery.out"
    local exclude_pattern
    local run_status

    mkdir -p .make
    exclude_pattern=$(swift_mk_exclude_pattern "${PERIPHERY_DEFAULT_EXCLUDE_PATHS:-}" "${PERIPHERY_EXCLUDE_PATHS:-}")
    capture_deadcode_findings "${raw_output}" "${findings_output}"
    run_status="${SWIFT_MK_COMMAND_STATUS}"

    if ! print_or_gate_findings \
        "periphery" \
        "${findings_output}" \
        "${PERIPHERY_BASELINE:-.periphery-baseline.txt}" \
        "periphery" \
        "Remove the unused declarations or make their reachability explicit in code." \
        "${exclude_pattern}"; then
        return 1
    fi

    if [[ "${run_status}" -ne 0 && ! -s "${findings_output}" ]]; then
        printf "periphery: FAILED\n"
        printf "  Exit status: %s\n\n" "${run_status}"
        printf "Output:\n"
        cat "${raw_output}"
        swift_mk_record_failed_gate "periphery"
        return "${run_status}"
    fi
}

capture_swiftcheck_findings() {
    local raw_output="$1"
    local findings_output="$2"
    swift_mk_setup_temp_dir
    local scoped_output="${SWIFT_MK_TEMP_DIR}/swiftcheck-findings.out"

    bash "${SCRIPT_DIR}/swift-mk-swiftcheck-extra.sh" capture "${raw_output}" "${scoped_output}"
    filter_ranges_if_needed "${scoped_output}" "${findings_output}"
}

run_lint_swiftcheck() {
    local raw_output=".make/swiftcheck-extra.raw.out"
    local findings_output=".make/swiftcheck-extra.out"
    local exclude_pattern

    mkdir -p .make
    exclude_pattern=$(swift_mk_exclude_pattern "${SWIFTCHECK_EXTRA_DEFAULT_EXCLUDE_PATHS:-}" "${SWIFTCHECK_EXTRA_EXCLUDE_PATHS:-}")
    capture_swiftcheck_findings "${raw_output}" "${findings_output}"
    print_or_gate_findings \
        "swiftcheck-extra" \
        "${findings_output}" \
        "${SWIFTCHECK_EXTRA_BASELINE:-.swiftcheck-extra-baseline.txt}" \
        "swiftcheck-extra" \
        "Fix these findings in code. Do not disable, silence, weaken, or otherwise circumvent the checks." \
        "${exclude_pattern}"
}

run_lint_files() {
    if [[ -z "${LINT_FILES:-}" ]]; then
        printf "lint-files: LINT_FILES is empty\n"
        return 2
    fi
    run_lint_swiftlint || return $?
    run_lint_format || return $?
    run_lint_complexity || return $?
    run_lint_swiftcheck || return $?
}

run_lint_diff() {
    local staged_files
    local diff_output=".make/lint-diff.patch"
    local ranges_output=".make/lint-diff.ranges"

    mkdir -p .make
    staged_files=$(git diff --cached --name-only --diff-filter=ACM -- '*.swift' || true)
    if [[ -z "${staged_files}" ]]; then
        printf "lint-diff: no staged .swift files\n"
        return 0
    fi

    git diff --cached --unified=0 --no-color -- '*.swift' > "${diff_output}"
    awk -v action=ranges -f "$(swift_mk_findings_awk)" "${diff_output}" > "${ranges_output}"
    if [[ ! -s "${ranges_output}" ]]; then
        printf "lint-diff: no staged Swift line changes\n"
        return 0
    fi

    BASELINE="${BASELINE:-1}" LINT_FILES="${staged_files}" LINT_LINE_RANGES="${ranges_output}" run_lint_files
}

run_fmt() {
    local target_args=()

    swift_format_command format
    swift_format_targets
    target_args=("${SWIFT_MK_WORDS[@]}")
    swift_format_command format
    swift_mk_run_lint_cpu "${SWIFT_MK_WORDS[@]}" "${target_args[@]}"
}

run_test() {
    if [[ -z "${SWIFT_TEST_CMD:-}" ]]; then
        printf "test: SWIFT_TEST_CMD is not set\n"
        return 2
    fi
    eval "${SWIFT_TEST_CMD}"
}

run_log_audit() {
    if [[ -z "${SWIFT_LOG_AUDIT_CMD:-}" ]]; then
        printf "log-audit: not configured\n"
        return 0
    fi
    eval "${SWIFT_LOG_AUDIT_CMD}"
}

run_audit() {
    local audit_root

    if ! command -v osv-scanner >/dev/zero; then
        printf "audit: osv-scanner not found\n"
        return 127
    fi
    audit_root="${SWIFT_MK_ROOT:-${PWD}}"
    swift_mk_split_words "${OSV_SCANNER_ARGS:---recursive --allow-no-lockfiles}"
    swift_mk_run_lint_cpu "${OSV_SCANNER:-osv-scanner}" scan source "${SWIFT_MK_WORDS[@]}" "${audit_root}"
    if [[ -n "${SWIFT_AUDIT_EXTRA_CMD:-}" ]]; then
        eval "${SWIFT_AUDIT_EXTRA_CMD}"
    fi
}

run_lint() {
    local gate_name
    local gate_output
    local gate_error
    local gate_status
    local failed_gates
    local bypass_value
    local expected_raw
    local expected_error
    local expected_value
    local make_args=()

    mkdir -p .make
    rm -f .make/lint.failed
    swift_mk_split_words "${SWIFT_MK_RECURSIVE_MAKE_ARGS:-}"
    if [[ "${SWIFT_MK_WORDS_COUNT}" -gt 0 ]]; then
        make_args=("${SWIFT_MK_WORDS[@]}")
    fi

    for gate_name in ${LINT_GATES}; do
        gate_output=".make/${gate_name}.aggregate.out"
        gate_error=".make/${gate_name}.aggregate.err"
        gate_status=0
        printf "lint: running %s\n" "${gate_name}"
        SWIFT_MK_SKIP_FETCH=1 "${SWIFT_MK_RECURSIVE_MAKE:-${MAKE:-make}}" "${make_args[@]}" --no-print-directory "${gate_name}" > "${gate_output}" 2>"${gate_error}" || gate_status=$?
        cat "${gate_output}"
        cat "${gate_error}"
        if [[ "${gate_status}" -ne 0 ]]; then
            swift_mk_record_failed_gate "${gate_name}"
        fi
    done

    failed_gates=""
    if [[ -f .make/lint.failed ]]; then
        failed_gates=$(sort -u .make/lint.failed | awk 'NR == 1 { value = $0; next } { value = value ", " $0 } END { print value }')
    fi
    if [[ -z "${failed_gates}" ]]; then
        printf "lint: OK\n"
        return 0
    fi

    bypass_value=$(printf "%s" "${BYPASS_LINT:-}" | swift_mk_slugify)
    if [[ -n "${bypass_value}" ]]; then
        swift_mk_setup_temp_dir
        expected_raw="${SWIFT_MK_TEMP_DIR}/expected-token.raw"
        expected_error="${SWIFT_MK_TEMP_DIR}/expected-token.err"
        if eval "${BYPASS_TOKEN_CMD:-${SWIFT_MK_GATE_TOKEN_CMD:-}}" > "${expected_raw}" 2>"${expected_error}"; then
            expected_value=$(swift_mk_slugify < "${expected_raw}" || true)
            if [[ -n "${expected_value}" && "${bypass_value}" == "${expected_value}" && "${BYPASS_CONFIRM:-}" == "1" ]]; then
                printf "LINT FINDINGS NON-BLOCKING via BYPASS_LINT=%s\n" "${expected_value}"
                return 0
            fi
        fi
    fi

    printf "\nlint: FAILED\n"
    printf "  Failed gates: %s\n" "${failed_gates}"
    return 1
}

command_name="${1:-}"
case "${command_name}" in
    lint-tools)
        run_lint_tools
        ;;
    lint-swiftlint)
        run_lint_swiftlint
        ;;
    lint-format)
        run_lint_format
        ;;
    lint-complexity)
        run_lint_complexity
        ;;
    lint-deadcode)
        run_lint_deadcode
        ;;
    lint-files)
        run_lint_files
        ;;
    lint-diff)
        run_lint_diff
        ;;
    fmt)
        run_fmt
        ;;
    test)
        run_test
        ;;
    log-audit)
        run_log_audit
        ;;
    audit)
        run_audit
        ;;
    lint)
        run_lint
        ;;
    capture-swiftlint)
        mkdir -p .make
        capture_swiftlint_findings "${2:-.make/swiftlint.raw.out}" "${3:-.make/swiftlint.out}"
        ;;
    capture-complexity)
        mkdir -p .make
        capture_complexity_findings "${2:-.make/lint-complexity.raw.out}" "${3:-.make/lint-complexity.out}"
        ;;
    capture-deadcode)
        mkdir -p .make
        capture_deadcode_findings "${2:-.make/periphery.raw.out}" "${3:-.make/periphery.out}"
        ;;
    *)
        printf "swift-mk-lint: unknown command %s\n" "${command_name}"
        exit 2
        ;;
esac
