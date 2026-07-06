# Per-worktree build lock

Two builds in one worktree share the same SwiftPM `.build` directory and the same DerivedData. SwiftPM allows one instance per `.build` directory, so an unserialized second build aborts the first and leaves a partial index. [`BuildLock`](../../Sources/SwiftMkCore/BuildLock.swift) serializes every build the engine drives in one worktree behind one advisory `flock`.

Builds in different worktrees stay fully parallel, because the lock file is keyed to the worktree root from `git rev-parse --show-toplevel`. The lock releases when the holding process dies, so a build killed mid-run never wedges it.

The lock is re-entrant two ways, so the chain of make build, then build-the-dev-tool, then the dev tool calling the engine in process never deadlocks on itself. A depth counter covers a nested call inside one process. An inherited environment marker, carrying the holder's process id and honored only when the worktree root matches and that process is still alive, covers a child process the holder spawned.

The lock file lives under `.make`, not inside DerivedData, so the dead-code coverage build's `rm -rf $(SWIFT_MK_DERIVED_DATA)` cannot delete it from under a held lock. The [dead-code gate](../deadcode/overview.md) explains why a partial index must never be scanned.
