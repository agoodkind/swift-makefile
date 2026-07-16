# Consumer fetch

A consumer does not clone the engine. It fetches one engine snapshot into its own `.make` directory and builds the `swift-mk` binary from there. [`swift-mk-build.sh`](../../scripts/swift-mk-build.sh) builds the binary, resolving the package path to `.make` when no `SWIFT_MK_DEV_DIR` override points at a full checkout.

## Bootstrap source

`bootstrap.mk` fetches only `swift.mk`. It reads `SWIFT_MK_DEV_DIR` first, so a consumer can test a local engine checkout without changing the committed bootstrap. When no local override supplies the file, it fetches `swift.mk` from the engine repository's `main` ref through `gh api` or `curl`.

After `swift.mk` is present, it owns the rest of the fetch. A standalone `make help` is the exception: once the bootstrap has fetched `swift.mk`, the top-of-file `help` target prints immediately and skips the wider fetch, module load, and toolchain probes. Every other invocation continues through the normal fetch path, so the bootstrap stub stays thin and consumers route through the same fetched engine surface whether the first file came from `SWIFT_MK_DEV_DIR` or from `main`.

## The engine snapshot

`swift.mk` fetches the whole engine as one snapshot and extracts it into `.make`. The consumer path downloads the archive for the pinned ref from GitHub, tries `gh api` first and falls back to a plain `curl` of the public codeload archive, and extracts it with `tar --strip-components=1` so the tree lands flat under `.make`. The result is a real SwiftPM package: `.make/Package.swift`, every engine source under `.make/Sources` and `.make/Tests`, the helper scripts under `.make/scripts`, and the swiftcheck package under `.make/swiftcheck`. A source added to the engine is present in the snapshot with no manifest to maintain, so a new engine file can never leave a consumer's cold build with a declared target and missing sources.

The extract is idempotent. It records the resolved ref in `.make/.swift-mk-snapshot-ref`, and a later run whose marker matches the pinned ref with a present `.make/Package.swift` skips the re-extract, so file mtimes stay stable and the tool-binary staleness guard does not force a rebuild. The extract only adds files, so it leaves `.make/logs`, `.make/build.lock`, and the built binary in place.

The engine repository commits `Package.resolved`, and the snapshot carries it into `.make`, so a consumer resolves the same dependency graph the engine reviewed with the lockfile change that selected it.

## Dev-dir mode

With `SWIFT_MK_DEV_DIR` set, the engine's own build and test read the checkout directly and never download. The snapshot mechanism still runs for `make smoke-fetch`, which extracts the local working tree into `.make` with `git ls-files` so a source added on disk is included before it is committed.

## Fetch-path smoke test

`make smoke-fetch` runs `swift-mk-sync.sh smoke-fetch`, which clears `.make`, extracts a fresh snapshot, and builds the swiftcheck package from `.make/swiftcheck`. SwiftPM validates every declared target's source directory at manifest load, so a snapshot that is missing a swiftcheck source fails the build here rather than in a consumer. This build is the completeness proof for the extracted tree.
