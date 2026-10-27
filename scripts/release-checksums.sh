#!/usr/bin/env bash
#
# release-checksums.sh writes and checks checksums.txt in a release dist
# folder. Each line contains the shasum -a 256 output for one asset.
#
# Usage:
#   release-checksums.sh write <dist-dir> <asset>...
#   release-checksums.sh refresh <dist-dir>
#   release-checksums.sh verify <dist-dir>
#
# write hashes the given assets in argument order and replaces checksums.txt.
# refresh hashes the assets in checksums.txt in their listed order and
# replaces checksums.txt.
# Stapling changes each notarized file's bytes. The release workflow runs
# refresh after stapling.
# verify hashes the listed assets again and fails if any line differs from
# checksums.txt. The release workflow runs verify before uploading the assets.
# refresh and verify exit 0 without changing anything when checksums.txt
# does not exist.

set -euo pipefail

readonly CHECKSUMS_FILE="checksums.txt"
readonly DIGEST_LINE_PATTERN='^[0-9a-fA-F]{64} [ *](.+)$'

usage() {
    echo "usage: release-checksums.sh write <dist-dir> <asset>... | refresh <dist-dir> | verify <dist-dir>" >&2
    exit 2
}

# hash_assets prints one shasum -a 256 line for each asset in argument order.
# All three modes use this function to compute digests.
hash_assets() {
    shasum -a 256 "$@"
}

# listed_assets reads the asset file names from checksums.txt and prints
# one file name per line.
listed_assets() {
    local line
    local asset_count

    asset_count=0
    while IFS= read -r line || [[ -n "${line}" ]]; do
        if [[ -z "${line}" ]]; then
            continue
        fi
        if [[ ! "${line}" =~ ${DIGEST_LINE_PATTERN} ]]; then
            echo "release-checksums: ${CHECKSUMS_FILE} has a malformed line: ${line}" >&2
            exit 1
        fi
        printf '%s\n' "${BASH_REMATCH[1]}"
        asset_count=$((asset_count + 1))
    done < "${CHECKSUMS_FILE}"
    if ((asset_count == 0)); then
        echo "release-checksums: ${CHECKSUMS_FILE} does not list any assets" >&2
        exit 1
    fi
}

write_checksums() {
    local temporary_file

    temporary_file="$(mktemp "${CHECKSUMS_FILE}.XXXXXX")"
    if ! hash_assets "$@" > "${temporary_file}"; then
        rm -f "${temporary_file}"
        echo "release-checksums: could not hash $*" >&2
        exit 1
    fi
    mv "${temporary_file}" "${CHECKSUMS_FILE}"
}

read_listed_assets() {
    local listed_output
    local asset

    listed_output="$(listed_assets)"
    assets=()
    while IFS= read -r asset; do
        assets+=("${asset}")
    done <<< "${listed_output}"
}

if (($# < 2)); then
    usage
fi

mode="$1"
dist_dir="$2"
shift 2

cd "${dist_dir}"

case "${mode}" in
    write)
        if (($# == 0)); then
            usage
        fi
        write_checksums "$@"
        echo "release-checksums: wrote ${CHECKSUMS_FILE} for $*"
        ;;
    refresh | verify)
        if (($# != 0)); then
            usage
        fi
        if [[ ! -f "${CHECKSUMS_FILE}" ]]; then
            echo "release-checksums: ${dist_dir} does not contain ${CHECKSUMS_FILE}; ${mode} skipped"
            exit 0
        fi
        assets=()
        read_listed_assets
        if [[ "${mode}" == "refresh" ]]; then
            write_checksums "${assets[@]}"
            echo "release-checksums: refreshed ${CHECKSUMS_FILE} for ${assets[*]}"
        else
            expected_file="$(mktemp "${TMPDIR:-/tmp}/release-checksums.XXXXXX")"
            if ! hash_assets "${assets[@]}" > "${expected_file}"; then
                rm -f "${expected_file}"
                echo "release-checksums: could not hash ${assets[*]}" >&2
                exit 1
            fi
            if ! diff -u "${CHECKSUMS_FILE}" "${expected_file}" >&2; then
                rm -f "${expected_file}"
                echo "release-checksums: ${CHECKSUMS_FILE} does not match the assets in ${dist_dir}" >&2
                exit 1
            fi
            rm -f "${expected_file}"
            echo "release-checksums: ${CHECKSUMS_FILE} matches ${assets[*]}"
        fi
        ;;
    *)
        usage
        ;;
esac
