# Consumer fetch

A consumer does not clone the engine. It fetches a subset of engine files into its own `.make` directory and builds the `swift-mk` binary from there. [`swift-mk-sync.sh`](../../scripts/swift-mk-sync.sh) performs the fetch, and [`swift-mk-build.sh`](../../scripts/swift-mk-build.sh) builds the binary, resolving the package path to `.make` when no `SWIFT_MK_DEV_DIR` override points at a full checkout.

## The fetch manifest

The fetched file set is the `SWIFT_MK_SCRIPT_FILES` list in [`swift.mk`](../../swift.mk). It carries `Package.swift`, every engine source the package's targets declare, the shared lint configs, and the helper scripts. `swift-mk-sync.sh` copies each listed path into `.make`, so a consumer's `.make` is a real SwiftPM package that builds `swift-mk`.

## Every target's sources must be in the manifest

Because `.make/Package.swift` is fetched, a consumer's `.make` declares every engine target. SwiftPM validates each declared target's source directory when it loads the package, so a source file left out of the manifest makes `.make` a declared target with missing sources, and the consumer's build of `swift-mk` fails at manifest load. The failure appears only on a cold toolchain-cache run, because a warm cache restores the prebuilt binary and never rebuilds from `.make`.

[`ManifestCompletenessTests`](../../Tests/SwiftMkCoreTests/ManifestCompletenessTests.swift) is the source of truth for this invariant. It walks every fetched source tree and fails the build when a `.swift` file is absent from `SWIFT_MK_SCRIPT_FILES`, so a newly added module cannot ship unfetched.

## Fetch-path smoke test

`make smoke-fetch` runs `swift-mk-sync.sh smoke-fetch`, which clears `.make`, performs a real fetch, and builds the swiftcheck package from the fetched tree, so a fetch that copies the wrong paths fails at the pipeline rather than in a consumer.
