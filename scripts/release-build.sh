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
# Signing: the full swift-mk engine resolves the identity and runs codesign-run.
# When no identity resolves (a secretless fork run) signing is skipped so CI stays
# green; the workflow's notarize step is already gated on the notary secrets.
#
# Versioning: RELEASE_TAG is set by the workflow. When present and not "dev" the
# full swift-mk engine stamps it into the maintenance ReleaseVersion.swift before
# the lean release build, so the published binary reports its tag from
# `swift-mk version`. The CI checkout is disposable, so the in-place edit is safe.

set -euo pipefail

# Run from the repo root that contains this script, so the relative paths below
# (git archive, scripts/swift-mk-build.sh, and the default dist dir) resolve no
# matter the caller's working directory. This also anchors $PWD, used for
# engine_root and engine_repo below, to this checkout.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${script_dir}/.."

# This script uses macOS-only tooling (hdiutil and codesign), so fail early with
# a clear message rather than a confusing packaging error later.
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "release-build: macOS is required (hdiutil/codesign); got $(uname -s)" >&2
    exit 1
fi

dist="${SWIFT_MK_DIST_DIR:-dist}"
tag="${RELEASE_TAG:-dev}"
# tag goes into a filename, so reject anything but a safe filename charset.
if [[ ! "$tag" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "release-build: RELEASE_TAG has unsafe characters (want [A-Za-z0-9._-]): $tag" >&2
    exit 1
fi
asset="swift-mk_darwin_arm64.dmg"
# Anchor the engine SOURCE tree to the current checkout ($PWD) rather than
# inheriting SWIFT_MK_ROOT / SWIFT_MK_BUILD_REPO from the environment, so a caller
# that has those set for another swift-mk workflow cannot build this release
# package from a different source tree than the repo it runs in. SWIFT_MK_BIN is
# left as the caller set it on purpose: in CI it is the cached toolchain engine
# built from this same checkout (its cache key pins the Sources hash), so reusing
# it keeps the engine build to once per push. swift-mk-build.sh's resolve step
# still rebuilds from the anchored $PWD sources whenever they are newer than that
# cached binary, so a stale engine is not reused.
engine_root="$PWD"
engine_repo="$PWD"

mkdir -p "$dist"

# 1. Source snapshot (kept for parity with the prior self-release; unsigned).
git archive --format tar.gz --output "$dist/swift-makefile-$tag.tar.gz" HEAD

# 2. Resolve the full engine that owns stamping, lean build, dmg assembly, and signing.
SWIFT_MK_ROOT="$engine_root" SWIFT_MK_BUILD_REPO="$engine_repo" bash scripts/swift-mk-build.sh resolve
engine="$(SWIFT_MK_ROOT="$engine_root" bash scripts/swift-mk-build.sh path)"
"$engine" release-package-maint --tag "$tag" --dist-dir "$dist" --signing-engine "$engine"

# 3. Checksums over every published artifact.
(
    cd "$dist"
    shasum -a 256 "swift-makefile-$tag.tar.gz" "$asset" > checksums.txt
)

echo "release-build: built $dist/$asset and checksums.txt for tag $tag"
