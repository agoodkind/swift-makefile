# Build

The engine runs every build through one of two chokepoints, so the gate, the per-worktree lock, and the shared cache flags apply in one place and no consumer reimplements them. [`Toolchain`](../../Sources/SwiftMkCore/Toolchain.swift) is the one site that runs `xcodebuild`. [`SwiftPM`](../../Sources/SwiftMkCore/SwiftPM.swift) is the one site that runs `swift build`, `swift test`, and `swift run`.

A consumer or a dev tool calls these types in process, or routes a make recipe through `swift-mk toolchain`, rather than shelling the compiler itself. A build that shelled the compiler directly would skip the gate, the lock, and the cache flags, and each consumer would drift on its own copy. The [enforcement](enforcement.md) rules fail a build that spawns the compiler outside the chokepoint.

## The engine drives the CLI, not a build library

The engine drives the command-line tools as subprocesses rather than importing their build libraries. Xcode 26 ships no importable `Build` or `Workspace` module under its toolchain, so an in-process SwiftPM build would need a heavy, version-pinned source dependency on swift-package-manager. Driving the gated CLI tool keeps the engine free of that dependency, and [`NoLibSwiftPMImportTests`](../../Tests/SwiftMkCoreTests/NoLibSwiftPMImportTests.swift) fails the build if that dependency reappears.

## The gate and the lock

Every chokepoint compile proves it is authorized before it runs and holds the per-worktree lock while it runs. The [build gate](../gate/overview.md) owns the authorization proof, through real `make` ancestry or an in-memory receipt a caller cannot forge. The [per-worktree build lock](lock.md) serializes builds that share one worktree's `.build` directory, while builds in separate worktrees stay parallel.

## The cache flags

Each chokepoint applies the shared compile-cache flags, so a consumer sets nothing and the engine owns the cache with no opt-out. [caching](../caching/overview.md) owns the cache plan, the compile-cache stores, and the cross-runner behavior.
