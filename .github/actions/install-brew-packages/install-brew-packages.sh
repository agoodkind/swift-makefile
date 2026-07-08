#!/usr/bin/env bash

set -euo pipefail

brew_locked() {
    flock -w 300 /tmp/swift-mk-brew.lock brew "$@"
}

# The workflow passes `brew-packages` as one space-delimited string, so this
# helper performs the single intentional split before calling Homebrew.
main() {
    local brew_packages
    local -a brew_package_array

    brew_packages="${BREW_PACKAGES:-}"
    if [[ -z "${brew_packages}" ]]; then
        printf 'install-brew-packages: BREW_PACKAGES is empty\n' >&2
        exit 1
    fi

    read -r -a brew_package_array <<< "${brew_packages}"
    brew_locked install "${brew_package_array[@]}"
}

main "$@"
