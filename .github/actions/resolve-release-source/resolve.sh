#!/usr/bin/env bash

set -euo pipefail

release_tag=""
source_ref=""
source_sha="${GITHUB_SHA}"
enabled="true"
release_track="${RELEASE_TRACK}"
release_on_merge="${RELEASE_ON_MERGE:-manual}"

case "${release_on_merge}" in
    manual | prerelease | stable)
        ;;
    *)
        echo "release-on-merge must be manual, prerelease, or stable" >&2
        exit 1
        ;;
esac

case "${GITHUB_EVENT_NAME:-}" in
    pull_request)
        release_track="prerelease"
        ;;
    workflow_dispatch)
        if [[ -z "${release_track}" ]]; then
            release_track="stable"
        fi
        ;;
    push)
        if [[ "${GITHUB_REF:-}" == "refs/heads/main" ]]; then
            case "${release_on_merge}" in
                manual)
                    enabled="false"
                    release_track=""
                    ;;
                prerelease | stable)
                    release_track="${release_on_merge}"
                    ;;
            esac
        fi
        ;;
esac

stable_tag_is_available() {
    local remote_ref
    local release_view_error
    local tag
    local tag_query_result

    tag=$1
    if release_view_error="$(gh release view "${tag}" --repo "${GITHUB_REPOSITORY}" 2>&1)"; then
        return 1
    fi
    if [[ "${release_view_error}" != *"release not found"* ]]; then
        printf 'could not determine whether stable release %s exists: %s\n' "${tag}" "${release_view_error}" >&2
        return 2
    fi
    if ! tag_query_result="$(
        gh api --paginate "repos/${GITHUB_REPOSITORY}/git/matching-refs/tags/${tag}" --jq '.[].ref' 2>&1
    )"; then
        printf 'could not determine whether stable tag %s exists: %s\n' "${tag}" "${tag_query_result}" >&2
        return 2
    fi
    while IFS= read -r remote_ref; do
        if [[ "${remote_ref}" == "refs/tags/${tag}" ]]; then
            return 1
        fi
    done <<< "${tag_query_result}"
    return 0
}

next_stable_tag() {
    local availability_status
    local base_tag
    local candidate_tag
    local revision

    base_tag=$1
    candidate_tag="${base_tag}"
    revision=0
    while true; do
        if stable_tag_is_available "${candidate_tag}"; then
            printf '%s\n' "${candidate_tag}"
            return 0
        else
            availability_status=$?
        fi
        if [[ "${availability_status}" -ne 1 ]]; then
            return "${availability_status}"
        fi
        revision=$((revision + 1))
        candidate_tag="${base_tag}-r${revision}"
    done
}

if [[ "${enabled}" != "true" ]]; then
    :
elif [[ -z "${release_track}" ]]; then
    :
elif [[ "${release_track}" == "prerelease" ]]; then
    if [[ -n "${CANDIDATE_TAG}" || -n "${SOURCE_SHA}" || "${ALLOW_SOURCE_SHA}" == "true" ]]; then
        echo "pre-release builds use the workflow commit and cannot select a stable source" >&2
        exit 1
    fi
    source_ref="${GITHUB_SHA}"
elif [[ "${release_track}" == "stable" ]]; then
    if [[ -n "${CANDIDATE_TAG}" && -n "${SOURCE_SHA}" ]]; then
        echo "candidate-tag and source-sha conflict" >&2
        exit 1
    fi
    if [[ -n "${CANDIDATE_TAG}" ]]; then
        if [[ ! "${CANDIDATE_TAG}" =~ ^[0-9]+\.[0-9]+\.[0-9]+-pre\.[0-9]{12}\+[A-Za-z0-9]+$ ]]; then
            echo "candidate-tag must use the pre-release tag format" >&2
            exit 1
        fi
        candidate_release_state="$(gh release view "${CANDIDATE_TAG}" --repo "${GITHUB_REPOSITORY}" --json isPrerelease,isDraft --jq '[.isPrerelease, .isDraft] | @tsv')"
        if [[ "${candidate_release_state}" != $'true\tfalse' ]]; then
            echo "candidate-tag must identify a published non-draft GitHub pre-release" >&2
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
        utc_calendar_tag="$(date -u '+%y.%-m.%-d')"
        release_tag="$(next_stable_tag "${utc_calendar_tag}")"
    elif [[ -n "${SOURCE_SHA}" ]]; then
        echo "source-sha requires allow-source-sha=true" >&2
        exit 1
    else
        source_ref="${GITHUB_SHA}"
        utc_calendar_tag="$(date -u '+%y.%-m.%-d')"
        release_tag="$(next_stable_tag "${utc_calendar_tag}")"
    fi
else
    echo "release-track must be prerelease or stable" >&2
    exit 1
fi

if [[ -n "${source_ref}" ]]; then
    source_sha="$(gh api "repos/${GITHUB_REPOSITORY}/commits/${source_ref}" --jq .sha)"
fi
{
    echo "enabled=${enabled}"
    echo "release_track=${release_track}"
    echo "source_sha=${source_sha}"
    echo "release_tag=${release_tag}"
} >> "${GITHUB_OUTPUT}"
