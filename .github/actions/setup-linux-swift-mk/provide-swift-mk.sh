#!/usr/bin/env bash
# Provide the Linux swift-mk binary, in order: the restored cache, the engine's rolling release
# asset, or a from-source build. Writes the chosen path to SWIFT_MK_BIN in GITHUB_ENV.
#
# Why this is shell, not a typed swift-mk subcommand: this runs BEFORE swift-mk exists in the job,
# because its whole purpose is to produce swift-mk. It cannot be `swift-mk <verb>`. A typed Swift
# rewrite would need its own SwiftPM package that compiles before swift-mk, which adds a build step
# to the very cache-miss path this exists to make fast. Shell needs no build, so it runs at once.
# The logic stays small and is exercised by container tests; correctness rests on `set -euo
# pipefail` with no silent fallbacks (only a published-asset 404 falls through to the source build).
#
# Each source has one contract, and this trusts it rather than re-checking it:
#   cache    the cache key folds the runtime fingerprint, so a hit is the right ABI.
#   download the sha256 checksum proves the bytes, and the key proves the ABI.
#   build    swift-mk-build.sh exits non-zero on failure.
# So there is no launch probe on any path. The single recovery point is the Detect step, which
# runs the binary and falls back to a full run if it does not work.
#
# Fails loud. apt, a curl transport error, a non-404 HTTP status, a missing checksum for a present
# binary, a checksum mismatch, or a build failure each exits non-zero so the step goes red. The
# only expected miss is a 404 on the asset, meaning no binary is published for this engine source
# yet, which falls through to the source build.
set -euo pipefail

repo_root="${SWIFT_MK_SRC:?SWIFT_MK_SRC is required}"
asset="${SWIFT_MK_ASSET:?SWIFT_MK_ASSET is required}"
cache_hit="${SWIFT_MK_CACHE_HIT:-false}"

readonly RELEASE_BASE="https://github.com/agoodkind/swift-makefile/releases/download/linux-swift-mk"
readonly TOOLCHAIN_DIR="${HOME}/.swift-mk-ci-toolchain"
readonly BINARY_PATH="${TOOLCHAIN_DIR}/swift-mk"
readonly CONNECT_TIMEOUT_SECONDS=15
readonly BINARY_MAX_SECONDS=300
readonly CHECKSUM_MAX_SECONDS=60

announce_binary() {
    printf 'SWIFT_MK_BIN=%s\n' "${BINARY_PATH}" >> "${GITHUB_ENV}"
}

build_from_source() {
    echo "setup-linux-swift-mk: building swift-mk from source"
    rm -rf "${TOOLCHAIN_DIR}"
    SWIFT_MK_BIN="${BINARY_PATH}" SWIFT_MK_BUILD_REPO="${repo_root}" \
        bash "${repo_root}/scripts/swift-mk-build.sh" resolve
    echo "setup-linux-swift-mk: built ${BINARY_PATH}"
    announce_binary
}

# 1. Cache hit: trust the key for the ABI, but confirm the restore actually produced the binary
# file. A key hit whose archive is empty or partial would otherwise announce a missing path,
# leaving Setup green while Detect full-runs on every run with no self-heal. That is a real state
# to surface, so log it and fall through to re-fetch rather than trust a hit with no file. This is
# an existence check, not the launch probe that the key already makes redundant.
if [[ "${cache_hit}" == "true" ]]; then
    if [[ -x "${BINARY_PATH}" ]]; then
        echo "setup-linux-swift-mk: cache hit; using ${BINARY_PATH}"
        announce_binary
        exit 0
    fi
    echo "setup-linux-swift-mk: cache reported a hit but ${BINARY_PATH} is missing; re-fetching" >&2
fi
echo "setup-linux-swift-mk: cache miss"
rm -rf "${TOOLCHAIN_DIR}"
mkdir -p "${TOOLCHAIN_DIR}"

# 2. Download the published binary. curl is absent in the Swift container, so install it; an apt
# failure fails the step.
if ! command -v curl >/dev/null 2>&1; then
    echo "setup-linux-swift-mk: installing curl"
    apt-get update
    apt-get install -y --no-install-recommends curl
fi

# `-w '%{http_code}'` captures the status without `-f`, so an HTTP error still returns 0 and the
# code is inspected below; a transport failure makes curl itself exit non-zero and `set -e` fails
# the step.
echo "setup-linux-swift-mk: downloading ${asset}"
binary_status=$(curl -sS -L \
    --connect-timeout "${CONNECT_TIMEOUT_SECONDS}" --max-time "${BINARY_MAX_SECONDS}" \
    -o "${TOOLCHAIN_DIR}/${asset}" -w '%{http_code}' "${RELEASE_BASE}/${asset}")
echo "setup-linux-swift-mk: HTTP ${binary_status} for ${asset}"

if [[ "${binary_status}" == "404" ]]; then
    echo "setup-linux-swift-mk: no published binary for this engine source yet"
    build_from_source
    exit 0
fi
if [[ "${binary_status}" != "200" ]]; then
    echo "setup-linux-swift-mk: unexpected HTTP ${binary_status} downloading ${asset}" >&2
    exit 1
fi

echo "setup-linux-swift-mk: downloading checksum"
checksum_status=$(curl -sS -L \
    --connect-timeout "${CONNECT_TIMEOUT_SECONDS}" --max-time "${CHECKSUM_MAX_SECONDS}" \
    -o "${TOOLCHAIN_DIR}/${asset}.sha256" -w '%{http_code}' "${RELEASE_BASE}/${asset}.sha256")
if [[ "${checksum_status}" != "200" ]]; then
    echo "setup-linux-swift-mk: checksum missing (HTTP ${checksum_status}) for a present binary" >&2
    exit 1
fi

echo "setup-linux-swift-mk: verifying checksum"
( cd "${TOOLCHAIN_DIR}" && shasum -a 256 -c "${asset}.sha256" )
mv "${TOOLCHAIN_DIR}/${asset}" "${BINARY_PATH}"
chmod +x "${BINARY_PATH}"
rm -f "${TOOLCHAIN_DIR}/${asset}.sha256"
echo "setup-linux-swift-mk: using downloaded ${BINARY_PATH}"
announce_binary
