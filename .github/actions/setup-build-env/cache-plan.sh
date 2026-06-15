#!/usr/bin/env bash
set -euo pipefail

sanitize_key_part() {
    local raw_value="$1"

    printf '%s' "${raw_value}" | tr -cs '[:alnum:]_.-' '-'
}

write_cache_paths() {
    local output_file="$1"
    local home_dir="${HOME:?}"

    {
        printf 'dependency-paths<<CACHE_PATHS\n'
        printf '%s\n' \
            "${home_dir}/.cache/tuist" \
            "${home_dir}/.local/share/mise/downloads" \
            "${home_dir}/.local/share/mise/installs" \
            "${home_dir}/.local/share/mise/plugins" \
            "${home_dir}/Library/Caches/org.swift.swiftpm" \
            "${home_dir}/Library/Caches/ccache" \
            "${home_dir}/Library/Caches/Mozilla.sccache" \
            "${home_dir}/.cache/sccache" \
            'Tuist/.build'
        printf 'CACHE_PATHS\n'
        printf 'build-paths<<CACHE_PATHS\n'
        printf '%s\n' \
            '.build' \
            'swiftcheck/.build' \
            'Tools/.build' \
            '.make/swift-mk-build' \
            '.make/swiftcheck/.build' \
            'build/Build/Intermediates.noindex' \
            'build/Index.noindex' \
            'build/SourcePackages' \
            '.derived-data/Build/Intermediates.noindex' \
            '.derived-data/Index.noindex' \
            '.derived-data/SourcePackages' \
            'DerivedData/Build/Intermediates.noindex' \
            'DerivedData/Index.noindex' \
            'DerivedData/SourcePackages' \
            'Derived/Build/Intermediates.noindex' \
            'Derived/Index.noindex' \
            'Derived/SourcePackages'
        if [[ -n "${EXTRA_CACHE_PATHS:-}" ]]; then
            printf '%s\n' "${EXTRA_CACHE_PATHS}"
        fi
        printf 'CACHE_PATHS\n'
    } >> "${output_file}"
}

write_cache_plan() {
    local output_file="$1"
    local cache_profile
    local cache_version
    local dependency_hash
    local build_hash
    local runner_os
    local runner_arch
    local xcode_version
    local swift_version
    local weekly_epoch
    local dependency_cache_enabled
    local build_cache_enabled
    local cache_prefix

    cache_profile=$(printf '%s' "${CACHE_PROFILE:-safe}" | tr '[:upper:]' '[:lower:]')
    cache_version=$(sanitize_key_part "${CACHE_VERSION:-v1}")
    dependency_hash="${DEPENDENCY_HASH:-}"
    build_hash="${BUILD_HASH:-}"
    runner_os=$(sanitize_key_part "${RUNNER_OS:-$(uname -s)}")
    runner_arch=$(sanitize_key_part "${RUNNER_ARCH:-$(uname -m)}")
    xcode_version=$(sanitize_key_part "$(xcodebuild -version 2>/dev/null || printf 'xcode-unavailable')")
    swift_version=$(sanitize_key_part "$(swift --version 2>/dev/null || printf 'swift-unavailable')")
    weekly_epoch=$(date -u '+%Yw%U')

    if [[ -z "${cache_version}" ]]; then
        cache_version="v1"
    fi
    if [[ -z "${dependency_hash}" ]]; then
        dependency_hash="no-dependencies"
    fi
    if [[ -z "${build_hash}" ]]; then
        build_hash="no-build-config"
    fi

    dependency_cache_enabled=false
    build_cache_enabled=false
    case "${cache_profile}" in
        safe)
            dependency_cache_enabled=true
            build_cache_enabled=true
            ;;
        dependencies | dependency | deps)
            dependency_cache_enabled=true
            ;;
        off | none | false | 0)
            ;;
        *)
            printf 'setup-build-env: unknown cache-profile %s\n' "${cache_profile}" >&2
            exit 2
            ;;
    esac

    cache_prefix="${runner_os}-${runner_arch}-swift-mk-${cache_version}-${xcode_version}-${swift_version}"

    {
        printf 'dependency-cache-enabled=%s\n' "${dependency_cache_enabled}"
        printf 'build-cache-enabled=%s\n' "${build_cache_enabled}"
        printf 'dependency-key=%s-deps-%s\n' "${cache_prefix}" "${dependency_hash}"
        printf 'dependency-restore-keys<<CACHE_KEYS\n'
        printf '%s-deps-\n' "${cache_prefix}"
        printf 'CACHE_KEYS\n'
        printf 'build-key=%s-build-%s-%s\n' "${cache_prefix}" "${weekly_epoch}" "${build_hash}"
        printf 'build-restore-keys<<CACHE_KEYS\n'
        printf '%s-build-%s-\n' "${cache_prefix}" "${weekly_epoch}"
        printf '%s-build-\n' "${cache_prefix}"
        printf 'CACHE_KEYS\n'
    } >> "${output_file}"

    write_cache_paths "${output_file}"
}

main() {
    if [[ -z "${GITHUB_OUTPUT:-}" ]]; then
        printf 'setup-build-env: GITHUB_OUTPUT is not set\n' >&2
        exit 2
    fi

    write_cache_plan "${GITHUB_OUTPUT}"
}

main "$@"
