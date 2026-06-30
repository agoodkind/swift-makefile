# Build gate

The build gate runs the lint gates before any compile and refuses to compile when the lint gates have not passed in the same run. It is unbypassable: authorization comes from real `make` ancestry or an in-memory receipt, never from a value a caller can set.

## Two entry paths, one check

A consumer reaches a gated compile two ways, and both run the same hard check over the same owned source set.

- The make path marks the run with [`GateProof`](../../Sources/SwiftMkCore/GateProof.swift), which proves the compile descends from a `make` invocation that ran the gates.
- The in-process path is [`GatedBuild`](../../Sources/SwiftMkCore/GatedBuild.swift), which runs the gates and mints a capability receipt the compile consumes. The receipt has no public initializer, so a caller cannot forge one.

Both paths run `Lint.runHardBuildCheck` over [`LintSourceSet`](../../Sources/SwiftMkCore/LintPolicy.swift), which discovers every tracked and untracked-but-not-ignored Swift file from git. A caller cannot narrow it, so `LINT_GATES`, `LINT_FILES`, `SWIFTLINT_TARGETS`, and `BYPASS_LINT` change neither the gates that run nor the files they see. The verification is in [`GateProofTests`](../../Tests/SwiftMkCoreTests/GateProofTests.swift) and [`HardGateTests`](../../Tests/SwiftMkCoreTests/HardGateTests.swift).

## Build chokepoints

Every build the engine drives goes through one of two chokepoints, so the gate, the lock, and the cache apply uniformly. [`Toolchain`](../../Sources/SwiftMkCore/Toolchain.swift) drives xcodebuild, and [`SwiftPM`](../../Sources/SwiftMkCore/SwiftPM.swift) drives the `swift` command-line tool as a subprocess. The engine links no swift-package-manager library; [NoLibSwiftPMImportTests](../../Tests/SwiftMkCoreTests/NoLibSwiftPMImportTests.swift) enforces that. See [build chokepoints](../build-chokepoints.md) for the compile-cache stores.

## No direct toolchain in consumer files

[`BuildToolingAudit`](../../Sources/SwiftMkCore/BuildToolingAudit.swift) fails the gate when a consumer Makefile invokes `tuist`, `xcodegen`, `xcodebuild`, or `codesign` directly instead of routing through `$(SWIFT_MK_BIN) toolchain`. There is no opt-out marker.

## Serialized per worktree

[`BuildLock`](../../Sources/SwiftMkCore/BuildLock.swift) serializes every build the engine drives in one worktree behind one re-entrant `flock`, while builds in separate worktrees stay parallel. See the [dead-code gate](../deadcode/overview.md) for why a partial index must never be scanned.
