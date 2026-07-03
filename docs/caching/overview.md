# Caching

The cache subsystem speeds builds across runs and across worktrees, and the engine owns it, so a consumer hand-rolls no caching. The goal is build speed and macOS CI cost, not a cheap skip.

## Engine-owned cache plan

[`CachePlan`](../../Sources/SwiftMkCore/CachePlan.swift), [`CachePaths`](../../Sources/SwiftMkCore/CachePaths.swift), and [`CacheService`](../../Sources/SwiftMkCore/CacheService.swift) compute the cache plan, resolve the cache paths, and run the cache operations. [`BuildCache`](../../Sources/SwiftMkCore/BuildCache.swift) auto-detects ccache and compiles through it. The deleted `cache-plan.sh` does not return; the logic is Swift.

## Three cache buckets

[`CachePaths`](../../Sources/SwiftMkCore/CachePaths.swift) sorts the cacheable directories into three buckets, because they have different lifetimes and writers:

- The dependency bucket holds job-invariant downloads: SPM checkouts, the module cache, and mise installs. Every gate fetches the same ones, so one shared key is correct.
- The build bucket holds commit-keyed intermediates: the `.build` dirs and the DerivedData build database.
- The compile bucket holds the compilation cache (CAS) stores. These are build products, not downloads, and only the compiling gates fill them, so they get their own bucket and their own keying.

## Compile-cache stores live outside DerivedData

The compilation cache stores sit under `~/Library/Caches/swift-mk`, outside DerivedData, so the dead-code coverage build's `rm -rf` of DerivedData cannot destroy them. The two stores and the SwiftPM compile cache are described in [build chokepoints](../build-chokepoints.md), and the cache plan and paths in [caching](../caching.md).

## The compile bucket rolls per writer

GitHub `actions/cache` keeps only the first save under a key, and the compiling gates fill the compile cache by different amounts, so a single shared key would let whichever gate finishes first fix the contents. [`CachePlan`](../../Sources/SwiftMkCore/CachePlan.swift) keys the compile bucket as a rolling cache instead: the key carries the writing gate and a value unique to the run attempt, so every save lands under a fresh name and the pile accumulates across runs and re-runs. Restore-keys prefer the gate's own latest pile, then any sibling gate's pile for the same dependencies. Only a compiling gate (`build`, `test`, `lint-deadcode`, `deadcode`) restores and saves the compile bucket. The key also carries the weekly epoch, so the rolling history is capped: the pile rolls forward within a week, and each new week starts a fresh family so old piles age out under GitHub's expiry rather than one entry per run accumulating against the cache quota. Locally there is no such constraint, because every worktree appends to one live content-addressed folder; the rolling key is how that same pile is carried across separate CI machines, which have no shared folder.

## Cross-runner reuse

The compile bucket is content-addressed and restored by architecture-stable keys, so a pile built on one runner replays on another, pool or hosted. The SwiftPM compile cache is on by default, the SwiftPM peer of the Xcode cache, enabled by the engine on any toolchain that supports the flag (Swift 6.3+) and routed through the [`SwiftPM`](../../Sources/SwiftMkCore/SwiftPM.swift) chokepoint; a consumer sets nothing and the engine owns it with no opt-out.

## The default branch warms the cache for pull requests

GitHub scopes each cache to the branch that wrote it and to the repository default branch. A build on a pull request restores caches from its own branch and from the default branch, and nothing from a sibling branch. So a pull request restores a warm compile cache only when the default branch already holds one.

The default branch holds a compile cache after a build runs on it. A consumer that builds on the default branch gives every later pull request a warm pile to restore. A consumer whose CI runs only on pull requests never fills the default branch, so each first pull-request build compiles cold. The consumer trigger for this is in [ci](../ci/overview.md).
