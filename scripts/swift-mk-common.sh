#!/usr/bin/env bash
set -eo pipefail

SWIFT_MK_TEMP_DIR=""
SWIFT_MK_WORDS=()
SWIFT_MK_WORDS_COUNT=0
SWIFT_MK_COMMAND_STATUS=0
SWIFT_MK_EFFECTIVE_LINT_CONCURRENCY=""

swift_mk_cleanup() {
    if [[ -n "${SWIFT_MK_TEMP_DIR}" && -d "${SWIFT_MK_TEMP_DIR}" ]]; then
        rm -rf "${SWIFT_MK_TEMP_DIR}"
    fi
}

trap swift_mk_cleanup EXIT

swift_mk_setup_temp_dir() {
    if [[ -z "${SWIFT_MK_TEMP_DIR}" ]]; then
        SWIFT_MK_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/swift-mk.XXXXXX")
    fi
}

swift_mk_script_dir() {
    local source_path

    source_path="${BASH_SOURCE[0]}"
    cd "$(dirname "${source_path}")" && pwd
}

swift_mk_findings_awk() {
    printf "%s/swift-mk-findings.awk\n" "${SWIFT_MK_HELPER_DIR:-$(swift_mk_script_dir)}"
}

swift_mk_baseline_awk() {
    printf "%s/swift-mk-baseline.awk\n" "${SWIFT_MK_HELPER_DIR:-$(swift_mk_script_dir)}"
}

swift_mk_split_words() {
    local input_text

    input_text="${1:-}"
    SWIFT_MK_WORDS=()
    SWIFT_MK_WORDS_COUNT=0
    if [[ -n "${input_text}" ]]; then
        eval "SWIFT_MK_WORDS=( ${input_text} )"
        SWIFT_MK_WORDS_COUNT=${#SWIFT_MK_WORDS[@]}
    fi
}

swift_mk_count_file_lines() {
    local input_file

    input_file="$1"
    wc -l < "${input_file}" | tr -d " "
}

swift_mk_slugify() {
    local error_file

    swift_mk_setup_temp_dir
    error_file="${SWIFT_MK_TEMP_DIR}/slugify.err"
    { iconv -f UTF-8 -t ASCII//TRANSLIT 2>"${error_file}" || cat; } \
        | LC_ALL=C tr -cd "A-Za-z0-9_-" \
        | LC_ALL=C tr "A-Z" "a-z"
}

swift_mk_exclude_pattern() {
    local default_patterns
    local extra_patterns

    default_patterns="${1:-}"
    extra_patterns="${2:-}"
    printf "%s,%s\n" "${default_patterns}" "${extra_patterns}" \
        | tr "," "\n" \
        | awk "NF" \
        | paste -sd "|" -
}

swift_mk_filter_file() {
    local input_file
    local output_file
    local exclude_pattern

    input_file="$1"
    output_file="$2"
    exclude_pattern="${3:-}"
    if [[ -z "${exclude_pattern}" ]]; then
        cat "${input_file}" > "${output_file}"
        return
    fi
    grep -Ev "${exclude_pattern}" "${input_file}" > "${output_file}" || true
}

swift_mk_scope_file() {
    local input_file
    local output_file
    local scope_pattern

    input_file="$1"
    output_file="$2"
    scope_pattern="${3:-}"
    if [[ -z "${scope_pattern}" ]]; then
        cat "${input_file}" > "${output_file}"
        return
    fi
    grep -E "${scope_pattern}" "${input_file}" > "${output_file}" || true
}

swift_mk_normalize_file() {
    local input_file
    local output_file
    local awk_file
    local root_dir

    input_file="$1"
    output_file="$2"
    awk_file=$(swift_mk_findings_awk)
    root_dir="${SWIFT_MK_ROOT:-${PWD}}"
    awk -v action=normalize -v pwd="${PWD}/" -v cwd="${root_dir}/" -f "${awk_file}" "${input_file}" > "${output_file}"
}

swift_mk_extract_findings() {
    local input_file
    local output_file
    local match_pattern
    local exclude_pattern
    local matched_file
    local normalized_file
    local filtered_file

    input_file="$1"
    output_file="$2"
    match_pattern="$3"
    exclude_pattern="${4:-}"
    swift_mk_setup_temp_dir
    matched_file="${SWIFT_MK_TEMP_DIR}/matched-findings.out"
    normalized_file="${SWIFT_MK_TEMP_DIR}/normalized-findings.out"
    filtered_file="${SWIFT_MK_TEMP_DIR}/filtered-findings.out"

    grep -E "${match_pattern}" "${input_file}" > "${matched_file}" || true
    swift_mk_normalize_file "${matched_file}" "${normalized_file}"
    swift_mk_filter_file "${normalized_file}" "${filtered_file}" "${exclude_pattern}"
    sort -u "${filtered_file}" > "${output_file}"
}

swift_mk_keyize_file() {
    local input_file
    local output_file
    local awk_file

    input_file="$1"
    output_file="$2"
    awk_file=$(swift_mk_findings_awk)
    awk -v action=key -f "${awk_file}" "${input_file}" | sort -u > "${output_file}"
}

swift_mk_baseline_findings() {
    local baseline_file
    local label
    local output_file
    local exclude_pattern
    local scope_pattern
    local extracted_file
    local excluded_file
    local scoped_file
    local awk_file

    baseline_file="$1"
    label="$2"
    output_file="$3"
    exclude_pattern="${4:-}"
    scope_pattern="${5:-}"
    swift_mk_setup_temp_dir
    extracted_file="${SWIFT_MK_TEMP_DIR}/baseline-findings.out"
    excluded_file="${SWIFT_MK_TEMP_DIR}/baseline-findings.excluded.out"
    scoped_file="${SWIFT_MK_TEMP_DIR}/baseline-findings.scoped.out"
    awk_file=$(swift_mk_findings_awk)

    if [[ ! -f "${baseline_file}" ]]; then
        : > "${output_file}"
        return
    fi

    awk -v action=baseline -v label="${label}" -f "${awk_file}" "${baseline_file}" > "${extracted_file}"
    swift_mk_filter_file "${extracted_file}" "${excluded_file}" "${exclude_pattern}"
    swift_mk_scope_file "${excluded_file}" "${scoped_file}" "${scope_pattern}"
    sort -u "${scoped_file}" > "${output_file}"
}

swift_mk_map_keys_to_findings() {
    local keys_file
    local findings_file
    local awk_file

    keys_file="$1"
    findings_file="$2"
    awk_file=$(swift_mk_findings_awk)
    awk -v action=map -f "${awk_file}" "${keys_file}" "${findings_file}"
}

swift_mk_print_findings() {
    local awk_file

    awk_file=$(swift_mk_findings_awk)
    awk -v action=print -f "${awk_file}"
}

swift_mk_run_capture() {
    local output_file
    local error_file

    output_file="$1"
    shift
    error_file="${output_file}.err"
    SWIFT_MK_COMMAND_STATUS=0
    "$@" > "${output_file}" 2>"${error_file}" || SWIFT_MK_COMMAND_STATUS=$?
    cat "${error_file}" >> "${output_file}"
    rm -f "${error_file}"
}

swift_mk_resolve_lint_concurrency() {
    local requested_concurrency
    local processor_count
    local load_text
    local load_average
    local error_file

    if [[ -n "${SWIFT_MK_EFFECTIVE_LINT_CONCURRENCY}" ]]; then
        return
    fi

    requested_concurrency="${LINT_CONCURRENCY:-auto}"
    if [[ "${requested_concurrency}" != "auto" ]]; then
        SWIFT_MK_EFFECTIVE_LINT_CONCURRENCY="${requested_concurrency}"
        return
    fi

    swift_mk_setup_temp_dir
    error_file="${SWIFT_MK_TEMP_DIR}/concurrency.err"
    processor_count=$(getconf _NPROCESSORS_ONLN 2>"${error_file}" || sysctl -n hw.ncpu 2>"${error_file}" || printf "4")
    if [[ -z "${processor_count}" || "${processor_count}" -lt 1 ]]; then
        processor_count=1
    fi

    if [[ "$(uname)" == "Darwin" ]]; then
        load_text=$(sysctl -n vm.loadavg 2>"${error_file}" || printf "")
        load_average=$(printf "%s\n" "${load_text}" | awk "{ print \$2 + 0 }")
    else
        load_text=$(cat /proc/loadavg 2>"${error_file}" || printf "")
        load_average=$(printf "%s\n" "${load_text}" | awk "{ print \$1 + 0; exit }")
    fi
    if [[ -z "${load_average}" ]]; then
        load_average=0
    fi

    SWIFT_MK_EFFECTIVE_LINT_CONCURRENCY=$(
        awk -v processor_count="${processor_count}" -v load_average="${load_average}" '
            BEGIN {
                value = int(processor_count - load_average - 1)
                minimum = processor_count < 2 ? 1 : 2
                if (value < minimum) {
                    value = minimum
                }
                if (value > processor_count) {
                    value = processor_count
                }
                print value
            }
        '
    )
}

swift_mk_run_lint_cpu() {
    swift_mk_resolve_lint_concurrency
    if [[ "${SWIFT_MK_EFFECTIVE_LINT_CONCURRENCY}" == "0" ]]; then
        "$@"
        return
    fi
    env SWIFTLINT_NUMBER_OF_THREADS="${SWIFT_MK_EFFECTIVE_LINT_CONCURRENCY}" "$@"
}

swift_mk_run_lint_capture() {
    local output_file
    local error_file

    output_file="$1"
    shift
    error_file="${output_file}.err"
    SWIFT_MK_COMMAND_STATUS=0
    swift_mk_run_lint_cpu "$@" > "${output_file}" 2>"${error_file}" || SWIFT_MK_COMMAND_STATUS=$?
    cat "${error_file}" >> "${output_file}"
    rm -f "${error_file}"
}

swift_mk_record_failed_gate() {
    local gate_name

    gate_name="$1"
    mkdir -p .make
    printf "%s\n" "${gate_name}" >> .make/lint.failed
}

swift_mk_run_baseline_diff_gate() {
    local gate_name
    local findings_file
    local baseline_file
    local label
    local remediation_text
    local exclude_pattern
    local baseline_output
    local findings_keys
    local baseline_keys
    local new_keys
    local gone_keys
    local new_findings
    local gone_findings
    local new_count
    local gone_count

    gate_name="$1"
    findings_file="$2"
    baseline_file="$3"
    label="$4"
    remediation_text="$5"
    exclude_pattern="${6:-}"
    mkdir -p .make
    swift_mk_setup_temp_dir
    baseline_output=".make/${gate_name}.baseline.out"
    findings_keys=".make/${gate_name}.keys.out"
    baseline_keys=".make/${gate_name}.keys.baseline.out"
    new_keys=".make/${gate_name}.keys.new"
    gone_keys=".make/${gate_name}.keys.gone"
    new_findings="${SWIFT_MK_TEMP_DIR}/${gate_name}.new.out"
    gone_findings="${SWIFT_MK_TEMP_DIR}/${gate_name}.gone.out"

    swift_mk_baseline_findings "${baseline_file}" "${label}" "${baseline_output}" "${exclude_pattern}" ""
    swift_mk_keyize_file "${findings_file}" "${findings_keys}"
    swift_mk_keyize_file "${baseline_output}" "${baseline_keys}"
    comm -23 "${findings_keys}" "${baseline_keys}" > "${new_keys}" || true
    comm -13 "${findings_keys}" "${baseline_keys}" > "${gone_keys}" || true
    swift_mk_map_keys_to_findings "${new_keys}" "${findings_file}" > "${new_findings}"
    swift_mk_map_keys_to_findings "${gone_keys}" "${baseline_output}" > "${gone_findings}"

    if [[ -s "${new_findings}" ]]; then
        new_count=$(swift_mk_count_file_lines "${new_findings}")
        printf "%s: FAILED\n" "${gate_name}"
        printf "  New findings: %s\n\n" "${new_count}"
        printf "Findings:\n"
        swift_mk_print_findings < "${new_findings}"
        printf "\n  %s\n" "${remediation_text}"
        swift_mk_record_failed_gate "${gate_name}"
        return 1
    fi

    gone_count=0
    if [[ -s "${gone_findings}" ]]; then
        gone_count=$(swift_mk_count_file_lines "${gone_findings}")
    fi

    printf "%s: OK\n" "${gate_name}"
    printf "  New findings: 0\n"
    if [[ "${gone_count}" -gt 0 ]]; then
        printf "  Saved findings now fixed: %s\n" "${gone_count}"
    fi
}

swift_mk_print_baseline_update_counts() {
    local gate_name
    local baseline_file
    local findings_file
    local label
    local mode
    local exclude_pattern
    local baseline_output
    local findings_keys
    local baseline_keys
    local new_keys
    local gone_keys
    local refreshed_keys
    local current_finding_count
    local new_count
    local gone_count
    local refreshed_count

    gate_name="$1"
    baseline_file="$2"
    findings_file="$3"
    label="$4"
    mode="$5"
    exclude_pattern="${6:-}"
    swift_mk_setup_temp_dir
    baseline_output="${SWIFT_MK_TEMP_DIR}/${gate_name}.baseline.counts.out"
    findings_keys="${SWIFT_MK_TEMP_DIR}/${gate_name}.current.keys"
    baseline_keys="${SWIFT_MK_TEMP_DIR}/${gate_name}.baseline.keys"
    new_keys="${SWIFT_MK_TEMP_DIR}/${gate_name}.new.keys"
    gone_keys="${SWIFT_MK_TEMP_DIR}/${gate_name}.gone.keys"
    refreshed_keys="${SWIFT_MK_TEMP_DIR}/${gate_name}.refreshed.keys"

    swift_mk_baseline_findings "${baseline_file}" "${label}" "${baseline_output}" "${exclude_pattern}" ""
    swift_mk_keyize_file "${findings_file}" "${findings_keys}"
    swift_mk_keyize_file "${baseline_output}" "${baseline_keys}"
    comm -23 "${findings_keys}" "${baseline_keys}" > "${new_keys}" || true
    comm -13 "${findings_keys}" "${baseline_keys}" > "${gone_keys}" || true
    comm -12 "${findings_keys}" "${baseline_keys}" > "${refreshed_keys}" || true
    current_finding_count=$(swift_mk_count_file_lines "${findings_file}")
    new_count=$(swift_mk_count_file_lines "${new_keys}")
    refreshed_count=$(swift_mk_count_file_lines "${refreshed_keys}")
    gone_count=$(swift_mk_count_file_lines "${gone_keys}")

    printf "This update:\n"
    printf "  Findings captured: %s\n" "${current_finding_count}"

    case "${mode}" in
        prune-fixed | remove-fixed)
            printf "  Keys added: 0\n"
            printf "  Keys refreshed: %s\n" "${refreshed_count}"
            printf "  Keys removed: %s\n" "${gone_count}"
            if [[ "${new_count}" -gt 0 ]]; then
                printf "  Keys left unsaved: %s\n" "${new_count}"
            fi
            ;;
        accept-new)
            printf "  Keys added: %s\n" "${new_count}"
            printf "  Keys refreshed: %s\n" "${refreshed_count}"
            printf "  Keys removed: 0\n"
            if [[ "${gone_count}" -gt 0 ]]; then
                printf "  Keys kept unchanged: %s\n" "${gone_count}"
            fi
            ;;
        *)
            printf "  Keys added: %s\n" "${new_count}"
            printf "  Keys refreshed: %s\n" "${refreshed_count}"
            printf "  Keys removed: %s\n" "${gone_count}"
            ;;
    esac
}

swift_mk_print_baseline_overall_counts() {
    local gate_name
    local baseline_file
    local findings_file
    local label
    local exclude_pattern
    local baseline_output
    local findings_keys
    local baseline_keys
    local covered_keys
    local covered_findings
    local covered_count
    local total_count

    gate_name="$1"
    baseline_file="$2"
    findings_file="$3"
    label="$4"
    exclude_pattern="${5:-}"
    swift_mk_setup_temp_dir
    baseline_output="${SWIFT_MK_TEMP_DIR}/${gate_name}.baseline.overall.out"
    findings_keys="${SWIFT_MK_TEMP_DIR}/${gate_name}.current.overall.keys"
    baseline_keys="${SWIFT_MK_TEMP_DIR}/${gate_name}.baseline.overall.keys"
    covered_keys="${SWIFT_MK_TEMP_DIR}/${gate_name}.covered.overall.keys"
    covered_findings="${SWIFT_MK_TEMP_DIR}/${gate_name}.covered.overall.out"

    swift_mk_baseline_findings "${baseline_file}" "${label}" "${baseline_output}" "${exclude_pattern}" ""
    swift_mk_keyize_file "${findings_file}" "${findings_keys}"
    swift_mk_keyize_file "${baseline_output}" "${baseline_keys}"
    comm -12 "${findings_keys}" "${baseline_keys}" > "${covered_keys}" || true
    swift_mk_map_keys_to_findings "${covered_keys}" "${findings_file}" > "${covered_findings}"

    covered_count=$(swift_mk_count_file_lines "${covered_findings}")
    total_count=$(swift_mk_count_file_lines "${baseline_keys}")

    printf "\nOverall baseline:\n"
    printf "  Current findings covered: %s\n" "${covered_count}"
    printf "  Total keys: %s\n" "${total_count}"
}

swift_mk_write_baseline_file() {
    local title
    local old_baseline_file
    local findings_file
    local label
    local output_file
    local mode
    local now
    local awk_file

    title="$1"
    old_baseline_file="$2"
    findings_file="$3"
    label="$4"
    output_file="$5"
    mode="$6"
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    awk_file=$(swift_mk_baseline_awk)

    printf "# %s: generated_at=%s\n" "${title}" "${now}" > "${output_file}"
    awk -v mode="${mode}" -v now="${now}" -v label="${label}" -v current_file="${findings_file}" -f "${awk_file}" "${old_baseline_file}" >> "${output_file}"
}
