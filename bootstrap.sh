#!/usr/bin/env bash
set -euo pipefail

BASE_URL="https://raw.githubusercontent.com/agoodkind/swift-makefile/main"
CACHE_ROOT="${HOME}/.cache/swift-makefile"
SCRIPT_FILES=(
    "Package.swift"
    "Sources/SwiftMkRenderCore/TemplateRenderer.swift"
    "Sources/SwiftMkRenderCLI/main.swift"
    "templates/Makefile.tmpl"
    "bootstrap.mk"
)

warn() {
    printf 'warning: %s\n' "$1"
}

die() {
    printf 'error: %s\n' "$1"
    exit 1
}

usage() {
    cat <<'EOF'
bootstrap.sh writes a small SwiftPM consumer Makefile and bootstrap.mk.

Usage:
    bootstrap.sh
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi

fetch_asset() {
    local relative_path="$1"
    local destination_path="${CACHE_ROOT}/${relative_path}"

    mkdir -p "$(dirname "${destination_path}")"
    if curl -fsSL --connect-timeout 5 --max-time 10 \
        "${BASE_URL}/${relative_path}?v=${EPOCHSECONDS:-$(date +%s)}" \
        -o "${destination_path}.new"; then
        mv "${destination_path}.new" "${destination_path}"
        return 0
    fi
    rm -f "${destination_path}.new"
    [[ -f "${destination_path}" ]] || die "${relative_path} fetch failed"
}

for relative_path in "${SCRIPT_FILES[@]}"; do
    fetch_asset "${relative_path}"
done

[[ -f Package.swift ]] || die "bootstrap.sh expects Package.swift in the current directory"

if [[ -f Makefile ]]; then
    warn "Makefile already exists, leaving it unchanged"
else
    CONTEXT_JSON='{"values":{"BUILD_CMD":"swift build","TEST_CMD":"swift test","RUN_CMD":"swift run","CLEAN_CMD":"swift package clean","FORMAT_TARGETS":"Sources Tests Package.swift","LINT_TARGETS":"Sources Tests Package.swift"}}'
    printf '%s' "${CONTEXT_JSON}" | swift run --package-path "${CACHE_ROOT}" swift-mk-render "${CACHE_ROOT}/templates/Makefile.tmpl" > Makefile
    printf 'created Makefile\n'
fi

if [[ -f bootstrap.mk ]]; then
    warn "bootstrap.mk already exists, leaving it unchanged"
else
    cp "${CACHE_ROOT}/bootstrap.mk" bootstrap.mk
    printf 'created bootstrap.mk\n'
fi

if [[ -f .gitignore ]]; then
    if ! grep -q '^\.make/$' .gitignore; then
        printf '.make/\n' >> .gitignore
    fi
else
    printf '.make/\n' > .gitignore
fi
