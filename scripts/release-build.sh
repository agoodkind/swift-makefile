#!/usr/bin/env bash
#
# release-build.sh builds the swift-makefile release artifacts into
# $SWIFT_MK_DIST_DIR (default dist). It is the SWIFT_MK_RELEASE_BUILD_CMD hook
# the shared _release.yml workflow runs via `make release-build`.
#
# Artifacts:
#   - swift-makefile-<tag>.tar.gz  the source snapshot (unsigned)
#   - swift-mk_darwin_arm64.dmg    the signed swift-mk CLI, ready for notarize+staple
#   - checksums.txt                sha256 of both artifacts
#
# Signing: both the binary and the dmg sign with the identity swift-mk resolves,
# which reads CODE_SIGN_IDENTITY (or SWIFT_MK_SIGN_IDENTITY), the make variable the
# workflow exports into this script's environment. When no identity resolves (a
# secretless fork run) signing is skipped so CI stays green; the workflow's
# notarize step is already gated on the notary secrets.
#
# Versioning: RELEASE_TAG is set by the workflow. When present and not "dev" the
# script stamps it into ReleaseVersion.swift before the release build, so the
# published binary reports its tag from `swift-mk version`. The CI checkout is
# disposable, so the in-place edit is safe.

set -euo pipefail

# This script uses macOS-only tooling (hdiutil, codesign, BSD sed -i ''), so fail
# early with a clear message rather than a confusing sed/hdiutil error later.
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "release-build: macOS is required (hdiutil/codesign); got $(uname -s)" >&2
    exit 1
fi

# The script builds the release binary as arm64 and then executes it
# (signing-identity, codesign-run), so it must run on Apple silicon. Fail fast
# with a clear message rather than a confusing "wrong CPU type" exec error on an
# x86_64 runner.
if [[ "$(uname -m)" != "arm64" ]]; then
    echo "release-build: Apple silicon (arm64) is required; got $(uname -m)" >&2
    exit 1
fi

dist="${SWIFT_MK_DIST_DIR:-dist}"
tag="${RELEASE_TAG:-dev}"
# tag goes into a filename and a sed replacement, so reject anything but a safe
# filename charset rather than fail obscurely or stamp the wrong version.
if [[ ! "$tag" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "release-build: RELEASE_TAG has unsafe characters (want [A-Za-z0-9._-]): $tag" >&2
    exit 1
fi
version_file="Sources/SwiftMkMaintCore/ReleaseVersion.swift"
product="swift-mk"
asset="${product}_darwin_arm64.dmg"
identifier="io.goodkind.swift-mk"
volume="swift-mk"

mkdir -p "$dist"

# 1. Source snapshot (kept for parity with the prior self-release; unsigned).
git archive --format tar.gz --output "$dist/swift-makefile-$tag.tar.gz" HEAD

# 2. Stamp the release tag into the version enum for a real (non-dev) release.
# Fail loud if the stamp did not take, so a release binary never silently reports
# "dev". Engine tags are timestamp-hex-sha (no sed-special characters).
if [[ "$tag" != "dev" ]]; then
    sed -i '' "s/static let current = \"dev\"/static let current = \"$tag\"/" "$version_file"
    if ! grep -q "static let current = \"$tag\"" "$version_file"; then
        echo "release-build: failed to stamp version $tag into $version_file" >&2
        exit 1
    fi
fi

# 3. Build the release swift-mk binary (arm64; the only consumer is Apple silicon).
swift build -c release --product "$product" --arch arm64
bin_dir="$(swift build -c release --product "$product" --arch arm64 --show-bin-path)"
built="$bin_dir/$product"
if [[ ! -x "$built" ]]; then
    echo "release-build: built binary not found at $built" >&2
    exit 1
fi

# 4. Resolve the signing identity the way codesign-run does: swift-mk's own
# channel first (env plus the ad-hoc allowlist), then Config/local.xcconfig as a
# fallback. This avoids skipping signing (an unexpectedly unsigned dmg) when the
# identity lives only in the xcconfig, and preserves the ad-hoc safeguard.
resolve_sign_identity() {
    local resolved
    resolved="$("$built" signing-identity || true)"
    if [[ -n "$resolved" ]]; then
        printf '%s' "$resolved"
        return
    fi
    local xcconfig="Config/local.xcconfig"
    if [[ -f "$xcconfig" ]]; then
        # Match CODE_SIGN_IDENTITY with an optional [sdk=...] build condition,
        # then take the value after its =. Strip an inline // comment, a trailing
        # ;, surrounding quotes, and whitespace so the result matches what
        # codesign-run resolves from the same xcconfig.
        awk '/^[[:space:]]*CODE_SIGN_IDENTITY([[:space:]]*\[[^]]*\])?[[:space:]]*=/ {
            sub(/^[[:space:]]*CODE_SIGN_IDENTITY([[:space:]]*\[[^]]*\])?[[:space:]]*=/, "")
            sub(/\/\/.*/, "")
            sub(/;[[:space:]]*$/, "")
            sub(/^[[:space:]]+/, "")
            sub(/[[:space:]]+$/, "")
            if ($0 ~ /^".*"$/) {
                sub(/^"/, "")
                sub(/"$/, "")
            }
            print
            exit
        }' "$xcconfig"
    fi
}
sign_identity="$(resolve_sign_identity)"

# Stage a copy and sign it through the one canonical codesign channel.
stage="$dist/.stage"
rm -rf "$stage"
mkdir -p "$stage"
cp "$built" "$stage/$product"
if [[ -n "$sign_identity" ]]; then
    "$built" codesign-run --mode binary --identifier "$identifier" "$stage/$product"
else
    echo "release-build: no signing identity resolved; shipping an unsigned binary (secretless run)" >&2
fi

# 5. Package as a dmg and sign the image, so notarize can staple the ticket onto it.
dmg="$dist/$asset"
rm -f "$dmg"
hdiutil create -volname "$volume" -srcfolder "$stage" -ov -format UDZO "$dmg"
if [[ -n "$sign_identity" ]]; then
    "$built" codesign-run --mode dmg "$dmg"
fi
rm -rf "$stage"

# 6. Checksums over every published artifact.
(
    cd "$dist"
    shasum -a 256 "swift-makefile-$tag.tar.gz" "$asset" > checksums.txt
)

echo "release-build: built $dist/$asset and checksums.txt for tag $tag"
