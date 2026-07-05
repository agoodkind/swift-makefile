#!/usr/bin/env bash
#
# install.sh downloads the signed, notarized swift-mk CLI from the latest
# GitHub release and installs it into a user bin directory.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/agoodkind/swift-makefile/main/install.sh | bash
#
# Local checkout:
#   ./install.sh [flags]
#
# Flags:
#   --version TAG   pin to a specific release tag (default: latest)
#   --bin-dir DIR   override install dir (default: $XDG_BIN_HOME or $HOME/.local/bin)
#   -h, --help      show this help
#
# Exit codes:
#   0 success
#   1 usage / unsupported platform
#   2 download / mount / verify / install failure

set -euo pipefail

REPO="agoodkind/swift-makefile"
ASSET="swift-mk_darwin_arm64.dmg"
# Pin the expected Developer ID team so a validly-signed binary from a different
# team cannot pass verification (the update engine pins the same team).
TEAM_ID="H3BMXM4W7H"
BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
VERSION=""

usage() {
    # Embed the help text rather than reading $0, which is `bash` (not this
    # script) under the documented `curl | bash` pattern.
    cat <<'USAGE'
install.sh downloads the signed, notarized swift-mk CLI from the latest
GitHub release and installs it into a user bin directory.

Usage:
  curl -fsSL https://raw.githubusercontent.com/agoodkind/swift-makefile/main/install.sh | bash

Local checkout:
  ./install.sh [flags]

Flags:
  --version TAG   pin to a specific release tag (default: latest)
  --bin-dir DIR   override install dir (default: $XDG_BIN_HOME or $HOME/.local/bin)
  -h, --help      show this help
USAGE
}

# die prints a message and exits. The second argument is the exit code and
# defaults to 1 (usage / unsupported platform); operational failures pass 2.
die() {
    printf 'install.sh: %s\n' "$1" >&2
    exit "${2:-1}"
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"
}

require_darwin_arm64() {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        die "swift-mk is macOS only (got $(uname -s))"
    fi
    if [[ "$(uname -m)" != "arm64" ]]; then
        die "swift-mk ships only for Apple silicon (got $(uname -m))"
    fi
}

resolve_version() {
    if [[ -n "$VERSION" ]]; then
        printf '%s' "$VERSION"
        return
    fi
    # /releases/latest returns the newest published release and excludes drafts,
    # so a stray draft never resolves to a tag that 404s on download. The engine
    # publishes full releases. Parse tag_name with grep/sed so a fresh host needs
    # no jq.
    curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
        | grep -m1 '"tag_name"' \
        | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' \
        || die "failed to query latest release from $REPO" 2
}

install_bin() {
    local tag url tmpdir dmg mnt
    tag="$(resolve_version)"
    [[ -n "$tag" ]] || die "could not resolve release tag (use --version)"

    url="https://github.com/$REPO/releases/download/$tag/$ASSET"
    tmpdir="$(mktemp -d)"
    mnt="$tmpdir/mnt"
    # shellcheck disable=SC2064
    trap "hdiutil detach '$mnt' -quiet 2>/dev/null || true; rm -rf '$tmpdir'" EXIT

    dmg="$tmpdir/$ASSET"
    printf 'install.sh: downloading %s\n' "$url"
    curl -fsSL "$url" -o "$dmg" || die "download failed: $url" 2

    # The staple is the offline proof of notarization; validate before trusting.
    xcrun stapler validate "$dmg" || die "notarization staple invalid: $dmg" 2

    mkdir -p "$mnt"
    hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$mnt" >/dev/null \
        || die "could not mount $dmg" 2

    local extracted="$mnt/swift-mk"
    [[ -x "$extracted" ]] || die "swift-mk not found in $dmg at $extracted" 2

    # Verify the mounted binary BEFORE writing it into the bin dir, so a binary
    # that fails verification is never left on disk. Pin the Developer ID team.
    codesign --verify --strict "$extracted" || die "codesign verify failed: $extracted" 2
    local details
    details="$(codesign -dvv "$extracted" 2>&1 || true)"
    case "$details" in
        *"TeamIdentifier=$TEAM_ID"*) : ;;
        *) die "unexpected code-signing team (want $TEAM_ID): $extracted" 2 ;;
    esac

    mkdir -p "$BIN_DIR"
    install -m 0755 "$extracted" "$BIN_DIR/swift-mk" || die "install failed: $BIN_DIR/swift-mk" 2
    printf 'install.sh: installed %s (%s)\n' "$BIN_DIR/swift-mk" "$tag"
    "$BIN_DIR/swift-mk" version
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) shift; VERSION="${1:?--version requires a value}" ;;
        --bin-dir) shift; BIN_DIR="${1:?--bin-dir requires a value}" ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown flag: $1 (try --help)" ;;
    esac
    shift
done

require_darwin_arm64
need curl
need hdiutil
need xcrun
need codesign
need install

install_bin

printf 'install.sh: done\n'
