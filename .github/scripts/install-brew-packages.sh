#!/usr/bin/env bash

set -euo pipefail

brew_packages="${BREW_PACKAGES:-}"

if [[ -z "${brew_packages}" ]]; then
    printf 'install-brew-packages: BREW_PACKAGES is empty\n' >&2
    exit 1
fi

read -r -a brew_package_array <<< "${brew_packages}"
brew install "${brew_package_array[@]}"
