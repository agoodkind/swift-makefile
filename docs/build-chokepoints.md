# Build chokepoints

The engine runs every build through one of two chokepoint types, so the gate, the build lock, and the shared cache flags apply in one place and no consumer reimplements them. `Toolchain` is the one site that runs `xcodebuild`. `SwiftPM` is the one site that runs `swift build`, `swift test`, and `swift run`.

A consumer or a dev tool calls these types in process, or routes a make recipe through `swift-mk toolchain`, rather than shelling the compiler itself. A build that shelled the compiler directly would skip the gate, the lock, and the cache flags, and each consumer would drift on its own copy.

The engine drives the command-line tools as subprocesses rather than importing their build libraries. Xcode 26 ships no importable `Build` or `Workspace` module under its toolchain, so an in-process SwiftPM build would need a heavy, version-pinned source dependency on swift-package-manager. Driving the gated CLI tool keeps the engine free of that dependency.

## The gate

A build proves it is authorized before it runs, so a consumer cannot compile unreviewed code through the engine. Two proofs exist for the two ways a build starts.

A make-path entry proves a live `make` or `swift-mk` ancestor through `GateProof`. When no such ancestor is present, the entry refuses and returns a non-zero status rather than building.

An in-process entry carries a `GateReceipt`, which only a passed hard gate mints through `GatedBuild.run`. A dev tool that builds in process, such as lmd-dev, runs the engine's lint gate first and then compiles under the minted receipt, so a build decoupled from `make` still gates without a make ancestor.

## The per-worktree build lock

Two builds in one worktree share the same SwiftPM `.build` directory and the same DerivedData. SwiftPM allows one instance per `.build` directory, so an unserialized second build aborts the first and leaves a partial index. `BuildLock` serializes every build the engine drives in one worktree behind one advisory `flock`.

Builds in different worktrees stay fully parallel, because the lock file is keyed to the worktree root from `git rev-parse --show-toplevel`. The lock releases when the holding process dies, so a build killed mid-run never wedges it.

The lock is re-entrant two ways, so the chain of make build, then build-the-dev-tool, then the dev tool calling the engine in process never deadlocks on itself. A depth counter covers a nested call inside one process. An inherited environment marker, carrying the holder's process id and honored only when the worktree root matches and that process is still alive, covers a child process the holder spawned.

The lock file lives under `.make`, not inside DerivedData, so the dead-code coverage build's `rm -rf $(SWIFT_MK_DERIVED_DATA)` cannot delete it from under a held lock.
