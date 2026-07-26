#!/usr/bin/env bash

set -euo pipefail

release_tag=""
source_ref=""

next_stable_tag() {
    local base_tag
    local release_view_error
    local revision

    base_tag=$1
    if ! release_view_error="$(gh release view "${base_tag}" --repo "${GITHUB_REPOSITORY}" 2>&1)"; then
        if [[ "${release_view_error}" == *"release not found"* ]]; then
            printf '%s\n' "${base_tag}"
            return 0
        fi
        printf 'could not determine whether stable release %s exists: %s\n' "${base_tag}" "${release_view_error}" >&2
        return 1
    fi

    revision=1
    while true; do
        if release_view_error="$(gh release view "${base_tag}-r${revision}" --repo "${GITHUB_REPOSITORY}" 2>&1)"; then
            revision=$((revision + 1))
            continue
        fi
        if [[ "${release_view_error}" == *"release not found"* ]]; then
            break
        fi
        printf 'could not determine whether stable release %s-r%s exists: %s\n' "${base_tag}" "${revision}" "${release_view_error}" >&2
        return 1
    done
    printf '%s-r%s\n' "${base_tag}" "${revision}"
}

if [[ "${RELEASE_TRACK}" == "prerelease" ]]; then
    if [[ -n "${CANDIDATE_TAG}" || -n "${SOURCE_SHA}" || "${ALLOW_SOURCE_SHA}" == "true" ]]; then
        echo "prerelease releases use the workflow commit and cannot select a stable source" >&2
        exit 1
    fi
    source_ref="${GITHUB_SHA}"
elif [[ "${RELEASE_TRACK}" == "stable" ]]; then
    if [[ -n "${CANDIDATE_TAG}" && -n "${SOURCE_SHA}" ]]; then
        echo "candidate-tag and source-sha conflict" >&2
        exit 1
    fi
    if [[ -n "${CANDIDATE_TAG}" ]]; then
        if [[ ! "${CANDIDATE_TAG}" =~ ^[0-9]+\.[0-9]+\.[0-9]+-pre\.[0-9]{12}\+[A-Za-z0-9]+$ ]]; then
            echo "candidate-tag must use the prerelease tag format" >&2
            exit 1
        fi
        if [[ "$(gh release view "${CANDIDATE_TAG}" --repo "${GITHUB_REPOSITORY}" --json isPrerelease --jq .isPrerelease)" != "true" ]]; then
            echo "candidate-tag must identify a published GitHub pre-release" >&2
            exit 1
        fi
        candidate_asset="$(gh release view "${CANDIDATE_TAG}" --repo "${GITHUB_REPOSITORY}" --json assets --jq '.assets[].name' | while IFS= read -r asset_name; do if [[ "${asset_name}" == ${CANDIDATE_ASSET_PATTERN} ]]; then printf '%s\n' "${asset_name}"; break; fi; done)"
        if [[ -z "${candidate_asset}" ]]; then
            echo "candidate-tag does not contain an asset matching ${CANDIDATE_ASSET_PATTERN}" >&2
            exit 1
        fi
        source_ref="${CANDIDATE_TAG}"
        release_tag="$(next_stable_tag "${CANDIDATE_TAG%%-pre.*}")"
    elif [[ -n "${SOURCE_SHA}" && "${ALLOW_SOURCE_SHA}" == "true" ]]; then
        source_ref="${SOURCE_SHA}"
        release_tag="$(next_stable_tag "$(date -u +%y).$(date -u +%-m).$(date -u +%-d)")"
    elif [[ -n "${SOURCE_SHA}" ]]; then
        echo "source-sha requires allow-source-sha=true" >&2
        exit 1
    else
        echo "stable releases require candidate-tag or acknowledged source-sha" >&2
        exit 1
    fi
else
    echo "release-track must be prerelease or stable" >&2
    exit 1
fi

source_sha="$(gh api "repos/${GITHUB_REPOSITORY}/commits/${source_ref}" --jq .sha)"
{
    echo "source_sha=${source_sha}"
    echo "release_tag=${release_tag}"
} >> "${GITHUB_OUTPUT}"
