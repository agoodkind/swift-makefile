#!/usr/bin/env bash
set -euo pipefail

INTERRUPTED=false
STAGING_DIRECTORY=""

cleanup() {
    if [[ -n "${STAGING_DIRECTORY}" && -d "${STAGING_DIRECTORY}" ]]; then
        rm -rf "${STAGING_DIRECTORY}"
    fi
}

handle_interrupt() {
    INTERRUPTED=true
}

require_value() {
    local variable_name="$1"
    local variable_value="$2"

    if [[ -z "${variable_value}" ]]; then
        printf '%s is required\n' "${variable_name}" >&2
        exit 2
    fi
}

trap cleanup EXIT
trap handle_interrupt INT TERM

require_value "RELEASE_TRACK" "${RELEASE_TRACK:-}"
require_value "APPCAST_SOURCE" "${APPCAST_SOURCE:-}"
require_value "PUBLIC_DIRECTORY" "${PUBLIC_DIRECTORY:-}"
require_value "STABLE_FEED_URL" "${STABLE_FEED_URL:-}"
require_value "PRERELEASE_FEED_URL" "${PRERELEASE_FEED_URL:-}"

if [[ ! -s "${APPCAST_SOURCE}" ]]; then
    printf 'APPCAST_SOURCE is missing or empty: %s\n' "${APPCAST_SOURCE}" >&2
    exit 2
fi

case "${RELEASE_TRACK}" in
    prerelease)
        current_relative_path="prerelease/appcast.xml"
        sibling_relative_path="appcast.xml"
        sibling_feed_url="${STABLE_FEED_URL}"
        sibling_track="stable"
        ;;
    stable)
        current_relative_path="appcast.xml"
        sibling_relative_path="prerelease/appcast.xml"
        sibling_feed_url="${PRERELEASE_FEED_URL}"
        sibling_track="prerelease"
        ;;
    *)
        printf 'RELEASE_TRACK must be prerelease or stable: %s\n' "${RELEASE_TRACK}" >&2
        exit 2
        ;;
esac

STAGING_DIRECTORY="$(mktemp -d)"
staged_current_path="${STAGING_DIRECTORY}/${current_relative_path}"
staged_sibling_path="${STAGING_DIRECTORY}/${sibling_relative_path}"
mkdir -p "$(dirname "${staged_current_path}")" "$(dirname "${staged_sibling_path}")"
cp "${APPCAST_SOURCE}" "${staged_current_path}"

printf 'Preserving %s appcast from %s\n' "${sibling_track}" "${sibling_feed_url}"
if ! curl \
    --fail \
    --location \
    --show-error \
    --silent \
    --output "${staged_sibling_path}" \
    "${sibling_feed_url}"
then
    printf 'could not preserve %s appcast from %s\n' \
        "${sibling_track}" \
        "${sibling_feed_url}" >&2
    exit 1
fi

if [[ ! -s "${staged_sibling_path}" ]]; then
    printf 'could not preserve %s appcast because the response was empty: %s\n' \
        "${sibling_track}" \
        "${sibling_feed_url}" >&2
    exit 1
fi

if [[ "${INTERRUPTED}" == "true" ]]; then
    printf 'appcast staging interrupted before publication\n' >&2
    exit 130
fi

current_destination="${PUBLIC_DIRECTORY}/${current_relative_path}"
sibling_destination="${PUBLIC_DIRECTORY}/${sibling_relative_path}"
mkdir -p "$(dirname "${current_destination}")" "$(dirname "${sibling_destination}")"
cp "${staged_current_path}" "${current_destination}"
cp "${staged_sibling_path}" "${sibling_destination}"

printf 'Staged %s appcast at %s\n' "${RELEASE_TRACK}" "${current_destination}"
printf 'Staged preserved %s appcast at %s\n' "${sibling_track}" "${sibling_destination}"
