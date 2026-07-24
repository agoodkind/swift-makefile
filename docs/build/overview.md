# Build

The engine runs every build through one of two chokepoints, so the gate, the per-worktree lock, and the shared cache flags apply in one place and no consumer reimplements them. [`Toolchain`](../../Sources/SwiftMkCore/Toolchain.swift) is the one site that runs `xcodebuild`. [`SwiftPM`](../../Sources/SwiftMkCore/SwiftPM.swift) is the one site that runs `swift build`, `swift test`, and `swift run`.

A consumer or a dev tool calls these types in process, or routes a make recipe through `swift-mk toolchain`, rather than shelling the compiler itself. A build that shelled the compiler directly would skip the gate, the lock, and the cache flags, and each consumer would drift on its own copy. The [enforcement](enforcement.md) rules fail a build that spawns the compiler outside the chokepoint.

## The engine drives the CLI, not a build library

The engine drives the command-line tools as subprocesses rather than importing their build libraries. Xcode 26 ships no importable `Build` or `Workspace` module under its toolchain, so an in-process SwiftPM build would need a heavy, version-pinned source dependency on swift-package-manager. Driving the gated CLI tool keeps the engine free of that dependency, and [`NoLibSwiftPMImportTests`](../../Tests/SwiftMkCoreTests/NoLibSwiftPMImportTests.swift) fails the build if that dependency reappears.

## The gate and the lock

Every chokepoint compile proves it is authorized before it runs and holds the per-worktree lock while it runs. The [build gate](../gate/overview.md) owns the authorization proof, through real `make` ancestry or an in-memory receipt a caller cannot forge. The [per-worktree build lock](lock.md) serializes builds that share one worktree's `.build` directory, while builds in separate worktrees stay parallel.

## The cache flags

Each chokepoint applies the shared compile-cache flags, so a consumer sets nothing and the engine owns the cache with no opt-out. [caching](../caching/overview.md) owns the cache plan, the compile-cache stores, and the cross-runner behavior.

## Freshness

`make build` does no work when the tracked inputs and the built product are unchanged since the last successful build, so a repeated `make build` or `make run` returns at once. [freshness](freshness.md) owns the record, the source digest, and the make guard that ships the no-op to every consumer.

## Verification

`make verify` runs `SWIFT_VERIFY_BUILD_CMD` and `SWIFT_VERIFY_TEST_CMD` when configured, and falls back to the consumer's normal `SWIFT_BUILD_CMD` and `SWIFT_TEST_CMD` when either verify command is empty. It generates the project before building, runs the build through `swift-mk build`, runs the source-quality lint chain without dead-code analysis, and audits dependency lockfiles for known vulnerabilities.

This repository configures each package's verify commands to build the product and test targets together in one release `swift build --build-tests`, then run `swift test --skip-build` against that build tree. The build keeps the gate proof and per-worktree lock while avoiding a second compile.

## Consumer contract

A consumer routes build, test, and generate work through the `swift-mk` toolchain surface. The default SwiftPM commands call `swift-mk toolchain swiftpm build` and `swift-mk toolchain swiftpm test`; Xcode consumers set their normal project inputs and receive `swift-mk toolchain build`, `test`, `generate`, and `install` commands from `swift.mk`. The command a consumer provides is still its project build, but the engine owns the compiler boundary.

The enforcement rules keep that boundary visible. The makefile audit fails direct recipe calls to `swift build`, `swift test`, `swift run`, `xcodebuild`, `tuist`, `xcodegen`, and `codesign` when they bypass `$(SWIFT_MK_BIN)`. The shared SwiftSyntax analyzer's `unrouted_build_tooling` rule fails Swift source that spawns `swift build`, `swift test`, or `swift run` outside the engine chokepoint. The [enforcement](enforcement.md) overview links to the rules and tests that hold the contract.
