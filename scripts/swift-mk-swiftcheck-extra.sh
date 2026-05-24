#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/swift-mk-common.sh"

swiftcheck_output_path() {
    printf "%s/.make/swiftcheck-extra\n" "${SWIFT_MK_ROOT:-${PWD}}"
}

swiftcheck_missing_flags() {
    local candidate_path
    local flags_text
    local available_file
    local flag_word
    local flag_name

    candidate_path="$1"
    flags_text="${SWIFTCHECK_EXTRA_FLAGS:-}"
    swift_mk_setup_temp_dir
    available_file="${SWIFT_MK_TEMP_DIR}/swiftcheck-flags.out"
    swift_mk_run_capture "${available_file}" "${candidate_path}" -flags

    for flag_word in ${flags_text}; do
        flag_name="${flag_word#-}"
        if ! grep -q "Name: ${flag_name}" "${available_file}"; then
            return 0
        fi
    done
    return 1
}

swiftcheck_build_from_repo() {
    local output_path
    local repo_path
    local product_name
    local bin_output
    local built_bin

    swift_mk_setup_temp_dir
    output_path=$(swiftcheck_output_path)
    repo_path="${SWIFTCHECK_EXTRA_BUILD_REPO:-}"
    product_name="${SWIFTCHECK_EXTRA_BUILD_PRODUCT:-swiftcheck-extra}"
    mkdir -p "$(dirname "${output_path}")"
    swift_mk_run_lint_cpu swift build --package-path "${repo_path}" -c release --product "${product_name}"
    bin_output="${SWIFT_MK_TEMP_DIR}/swiftcheck-bin.out"
    swift_mk_run_capture "${bin_output}" swift build --package-path "${repo_path}" -c release --show-bin-path
    built_bin="$(tr -d '\r' < "${bin_output}" | tail -n 1)/${product_name}"
    cp "${built_bin}" "${output_path}"
    chmod +x "${output_path}"
}

swiftcheck_resolve_bin() {
    local configured_bin
    local repo_path
    local output_path
    local newest_source

    configured_bin="${SWIFTCHECK_EXTRA_BIN:-}"
    repo_path="${SWIFTCHECK_EXTRA_BUILD_REPO:-}"
    output_path=$(swiftcheck_output_path)

    if [[ -n "${configured_bin}" ]]; then
        if [[ ! -x "${configured_bin}" ]]; then
            printf "swiftcheck-extra: %s not executable\n" "${configured_bin}"
            return 1
        fi
        if swiftcheck_missing_flags "${configured_bin}"; then
            printf "swiftcheck-extra: %s does not support requested flags\n" "${configured_bin}"
            return 1
        fi
        return 0
    fi

    if [[ -z "${repo_path}" || ! -d "${repo_path}" ]]; then
        printf "swiftcheck-extra: build repo %s not present\n" "${repo_path}"
        return 1
    fi

    newest_source=""
    if [[ -x "${output_path}" ]]; then
        newest_source=$(find "${repo_path}" -name "*.swift" -newer "${output_path}" | head -n 1 || true)
    fi
    if [[ ! -x "${output_path}" || -n "${newest_source}" ]] || swiftcheck_missing_flags "${output_path}"; then
        swiftcheck_build_from_repo
    fi
}

swiftcheck_selected_bin() {
    local configured_bin
    local output_path

    configured_bin="${SWIFTCHECK_EXTRA_BIN:-}"
    output_path=$(swiftcheck_output_path)
    if [[ -n "${configured_bin}" ]]; then
        printf "%s\n" "${configured_bin}"
        return
    fi
    if [[ -x "${output_path}" ]]; then
        printf "%s\n" "${output_path}"
        return
    fi
    printf "\n"
}

swiftcheck_capture_findings() {
    local raw_output
    local findings_output
    local selected_bin
    local exclude_pattern
    local flags_text
    local normalized_output
    local filtered_output

    raw_output="$1"
    findings_output="$2"
    selected_bin=$(swiftcheck_selected_bin)
    if [[ -z "${selected_bin}" ]]; then
        printf "swiftcheck-extra: not configured\n"
        : > "${findings_output}"
        return 0
    fi
    if [[ ! -x "${selected_bin}" ]]; then
        printf "swiftcheck-extra: binary %s not executable\n" "${selected_bin}"
        : > "${findings_output}"
        return 0
    fi

    flags_text="${SWIFTCHECK_EXTRA_FLAGS:-}"
    swift_mk_split_words "${flags_text}"
    flag_args=("${SWIFT_MK_WORDS[@]}")
    swift_mk_split_words "${SWIFTCHECK_EXTRA_TARGETS:-Sources Tests Package.swift}"
    target_args=("${SWIFT_MK_WORDS[@]}")
    exclude_pattern=$(swift_mk_exclude_pattern "${SWIFTCHECK_EXTRA_DEFAULT_EXCLUDE_PATHS:-}" "${SWIFTCHECK_EXTRA_EXCLUDE_PATHS:-}")

    swift_mk_setup_temp_dir
    normalized_output="${SWIFT_MK_TEMP_DIR}/swiftcheck-normalized.out"
    filtered_output="${SWIFT_MK_TEMP_DIR}/swiftcheck-filtered.out"
    swift_mk_run_lint_capture "${raw_output}" "${selected_bin}" "${flag_args[@]}" "${target_args[@]}"
    swift_mk_normalize_file "${raw_output}" "${normalized_output}"
    swift_mk_filter_file "${normalized_output}" "${filtered_output}" "${exclude_pattern}"
    sort -u "${filtered_output}" > "${findings_output}"
}

swiftcheck_run_gate() {
    local raw_output
    local findings_output
    local exclude_pattern

    mkdir -p .make
    raw_output=".make/swiftcheck-extra.raw.out"
    findings_output=".make/swiftcheck-extra.out"
    exclude_pattern=$(swift_mk_exclude_pattern "${SWIFTCHECK_EXTRA_DEFAULT_EXCLUDE_PATHS:-}" "${SWIFTCHECK_EXTRA_EXCLUDE_PATHS:-}")
    swiftcheck_capture_findings "${raw_output}" "${findings_output}"
    swift_mk_run_baseline_diff_gate \
        "swiftcheck-extra" \
        "${findings_output}" \
        "${SWIFTCHECK_EXTRA_BASELINE:-.swiftcheck-extra-baseline.txt}" \
        "swiftcheck-extra" \
        "Fix these findings in code. Do not disable, silence, weaken, or otherwise circumvent the checks." \
        "${exclude_pattern}"
}

command_name="${1:-}"
case "${command_name}" in
    bin)
        swiftcheck_resolve_bin
        ;;
    run)
        swiftcheck_run_gate
        ;;
    capture)
        mkdir -p .make
        swiftcheck_capture_findings "${2:-.make/swiftcheck-extra.raw.out}" "${3:-.make/swiftcheck-extra.out}"
        ;;
    *)
        printf "swift-mk-swiftcheck-extra: unknown command %s\n" "${command_name}"
        exit 2
        ;;
esac
