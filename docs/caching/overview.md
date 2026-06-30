# Caching

The cache subsystem speeds builds across runs and across worktrees, and the engine owns it, so a consumer hand-rolls no caching. The goal is build speed and macOS CI cost, not a cheap skip.

## Engine-owned cache plan

[`CachePlan`](../../Sources/SwiftMkCore/CachePlan.swift), [`CachePaths`](../../Sources/SwiftMkCore/CachePaths.swift), and [`CacheService`](../../Sources/SwiftMkCore/CacheService.swift) compute the cache plan, resolve the cache paths, and run the cache operations. [`BuildCache`](../../Sources/SwiftMkCore/BuildCache.swift) auto-detects ccache and compiles through it. The deleted `cache-plan.sh` does not return; the logic is Swift.

## Compile-cache stores live outside DerivedData

The compilation cache stores sit under `~/Library/Caches/swift-mk`, outside DerivedData, so the dead-code coverage build's `rm -rf` of DerivedData cannot destroy them. The two stores and the SwiftPM compile cache are described in [build chokepoints](../build-chokepoints.md), and the cache plan and paths in [caching](../caching.md).

## Cross-runner reuse

Xcode compilation caching uses prefix mapping and a shared store so a cache built on one runner replays on another. The SwiftPM compile cache is opt-in and routed through the [`SwiftPM`](../../Sources/SwiftMkCore/SwiftPM.swift) chokepoint, because explicit-module builds change the build mode.
