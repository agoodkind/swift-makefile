# Consumer fetch

A consumer does not clone the engine. It commits a bootstrap stub, includes it from its Makefile, and provisions one engine snapshot into `.make`. The snapshot carries the whole engine tree, shared configs, helper scripts, and selected modules. [`swift-mk-build.sh`](../../scripts/swift-mk-build.sh) builds the binary from that tree, resolving the package path to `.make` when no `SWIFT_MK_DEV_DIR` override points at a full checkout.

## Bootstrap and provisioning

The bootstrap stub obtains the provisioning helper and runs it. A helper already on disk is left alone. `SWIFT_MK_DEV_DIR` wins when it supplies the helper from a local checkout. Only a missing helper downloads the pinned-ref tarball from the same codeload host, repository, and ref the snapshot uses elsewhere. That download does not use the raw `main` URL, so a ref-pinned consumer does not pin its helper to `main` forever. A cold offline start fails.

The helper provisions the whole `.make` snapshot, including `swift.mk`, shared lint and audit configs, and every selected module. It owns validation, reuse, and failure from that point on, so a policy change there reaches every consumer on its next parse with no consumer-repo change.

After the helper succeeds in fetched mode, the later include does not provision again. In dev-dir mode the helper returns immediately without provisioning, because the checkout is the source of truth. The bootstrap copies `swift.mk` from the checkout directly, and modules and shared configs still copy from the checkout through the fetch-path fallback.

Make assignments for helper-read variables are forwarded into the helper explicitly, because Make does not export Makefile assignments to `$(shell)` children. A value set on the make command line or in the consumer Makefile before the include reaches the bootstrap but not the helper unless it is forwarded.

A standalone `make help` is the exception: once the bootstrap has provisioned enough for `swift.mk` to parse, the top-of-file `help::` target prints immediately and skips the wider fetch, module load, and toolchain probes. Every other invocation continues through the normal fetch path.

The engine declares `help` as a double-colon target so a consumer Makefile can append recipes after `include bootstrap.mk`. Content after the include still parses on `make help`, and the fast path remains when `MAKECMDGOALS` is exactly `help`. A consumer may print project lines or delegate to a project tool:

```makefile
help::
	@printf '  %-40s %s\n' 'my-target' 'one-line description'
```

Mixing a single-colon consumer `help:` with the engine `help::` is a Make error.

## The engine snapshot

The helper downloads the archive for the pinned ref from GitHub and extracts it with `tar --strip-components=1` so the tree lands flat under `.make`. The result is a real SwiftPM package: `.make/Package.swift`, every engine source under `.make/Sources` and `.make/Tests`, the helper scripts under `.make/scripts`, and the swiftcheck package under `.make/swiftcheck`. A source added to the engine is present in the snapshot with no manifest to maintain, so a new engine file can never leave a consumer's cold build with a declared target and missing sources.

The extract is idempotent. It records an ETag in `.make/.swift-mk-snapshot-ref`, and a later run whose marker validates against upstream with a present `.make/Package.swift` skips the re-extract, so file mtimes stay stable and the tool-binary staleness guard does not force a rebuild. The extract only adds files, so it leaves `.make/logs`, `.make/build.lock`, and the built binary in place.

The engine repository commits `Package.resolved`, and the snapshot carries it into `.make`, so a consumer resolves the same dependency graph the engine reviewed with the lockfile change that selected it. That file records the macOS graph; a Linux Dependabot resolve that drops Darwin-only pins fails Verify until the lockfile is re-resolved on macOS with `swift package resolve`.

## Dev-dir mode

With `SWIFT_MK_DEV_DIR` set, the engine's own build and test read the checkout directly and never download. The snapshot mechanism still runs for `make smoke-fetch`, which extracts the local working tree into `.make` with `git ls-files` so a source added on disk is included before it is committed.

## Fetch-path smoke test

`make smoke-fetch` runs `swift-mk-sync.sh smoke-fetch`, which clears `.make`, extracts a fresh snapshot, and builds the swiftcheck package from `.make/swiftcheck`. SwiftPM validates every declared target's source directory at manifest load, so a snapshot that is missing a swiftcheck source fails the build here rather than in a consumer. This build is the completeness proof for the extracted tree.
