#!/usr/bin/env bash

set -euo pipefail

# Publish one named GitHub check run for a CI stage, so a branch ruleset can
# require a stage by name instead of requiring the whole job.
#
# Publishing is reporting, never a gate. A token without `checks: write` (a fork
# pull request, or a caller whose workflow-level permissions omit it) must not
# change the job's own result, so a failed API call is logged with its exit
# status and output and the script still exits 0.

publish_check() {
    local check_name
    local conclusion
    local head_sha
    local api_output
    local api_status

    check_name="$1"
    conclusion="$2"
    head_sha="${HEAD_SHA:-}"

    if [[ -z "${head_sha}" ]]; then
        printf 'publish-check: no head sha; did not publish %s=%s\n' \
            "${check_name}" "${conclusion}" >&2
        return 0
    fi

    api_status=0
    api_output="$(
        gh api "repos/${GITHUB_REPOSITORY}/check-runs" \
            --method POST \
            --field "name=${check_name}" \
            --field "head_sha=${head_sha}" \
            --field status=completed \
            --field "conclusion=${conclusion}" 2>&1
    )" || api_status=$?

    if ((api_status != 0)); then
        printf 'publish-check: could not publish %s=%s (exit %s): %s\n' \
            "${check_name}" "${conclusion}" "${api_status}" "${api_output}" >&2
        return 0
    fi

    printf 'publish-check: published %s=%s on %s\n' \
        "${check_name}" "${conclusion}" "${head_sha}"
}

main() {
    if (($# != 2)); then
        printf 'publish-check: usage: publish-check.sh <check name> <conclusion>\n' >&2
        exit 2
    fi

    publish_check "$1" "$2"
}

main "$@"
