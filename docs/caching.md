# Compilation caching

swift-makefile caches Swift compilation so a build replays unchanged compiles from a content-addressed store instead of recompiling them. Two stores exist because two compilers run across the consumers: `xcodebuild` for the Tuist and xcodegen consumers, and `swift build` for the SwiftPM consumers such as lmd.

## The two stores

Both stores hold LLVM content-addressed compilation results (a CAS, the compiler's term for its cache). A build that finds a result for an input replays the cached output and skips the compile.

The Xcode store serves `xcodebuild`. The engine enables it by injecting `COMPILATION_CACHE_ENABLE_CACHING=YES` and pointing `COMPILATION_CACHE_CAS_PATH` at the shared path in `Toolchain.sharedCacheArguments()`. `SWIFT_MK_XCODE_CACHE_PATH` names that path. `SWIFT_MK_XCODE_CACHE` gates it on by default on Xcode 26 and later.

The SwiftPM store serves `swift build`. The engine injects the compile-cache flags in `SwiftPM.cacheArguments()`, which every `swift build` and `swift test` that runs through the `SwiftPM` chokepoint receives. `SWIFT_MK_SWIFTPM_CACHE_PATH` names that path.

Both stores live outside DerivedData, under `SWIFT_MK_CACHE_ROOT` (default `$HOME/Library/Caches/swift-mk`). Keeping them outside DerivedData matters because the dead-code coverage build runs `rm -rf $(SWIFT_MK_DERIVED_DATA)`, which would otherwise destroy a store kept inside it. Both stores are content-addressed, so one shared copy is safe across worktrees, and both sit in the compile bucket of `CachePaths`, which the CI cache plan keys as a rolling per-writer cache so the store carries across runners.

## SwiftPM compilation caching is on by default

SwiftPM compilation caching is on by default, the SwiftPM peer of the Xcode compilation cache, so a consumer sets nothing and the engine owns it with no consumer opt-out.

The required flag is explicit-module-build. `swift build` only caches when it runs in explicit-module-build mode, so the engine passes `-Xswiftc -explicit-module-build` alongside `-Xswiftc -cache-compile-job` and `-Xswiftc -cas-path`. Without `-explicit-module-build`, `swift build` prints `cannot be used without explicit module build, turn off caching` and the store stays empty.

The engine enables the flags only on a toolchain that supports them: it detects the capability from the frontend help, and falls back to a Swift 6.3 version floor when that help text is absent, so a toolchain that lacks the flag never receives it.

`SWIFT_MK_SWIFTPM_CACHE_DIAGNOSTICS=1` adds `-Xswiftc -Rcache-compile-job`, which prints a replay or miss remark per output file. Use it to confirm replay.

### Cross-runner replay works, cross-local-path replay does not

The SwiftPM store replays across CI runners because GitHub-hosted runners check out to a stable path (`/Users/runner/work/<repo>/<repo>`). The store, restored from the Actions cache, finds the same keys on the next run because the build path is identical.

The store does not replay across two local checkouts at different absolute paths. The compilation key folds in the `.build` output paths, not only the source path, so a different checkout directory produces different keys. The flag that would remap those paths, `-cache-replay-prefix-map`, crashes `swift build` when passed through `-Xswiftc`, so local cross-worktree sharing is not available. The Xcode store does not have this limitation, because its prefix mapping works.

## Why the engine drives the compilers, not a library

`Toolchain` is the one site that runs `xcodebuild`. `SwiftPM` is the one site that runs `swift build`, `swift test`, and `swift run`. A consumer or a dev tool calls these types in process rather than shelling the compiler itself, so the engine injects the cache flags, the build lock, and the gate in one place and no consumer hand-rolls them.

The engine drives the `swift` command-line tool as a subprocess rather than importing the SwiftPM build libraries. Xcode 26 ships no importable `Build` or `Workspace` module under its toolchain, so an in-process SwiftPM build would need a heavy, version-pinned source dependency on swift-package-manager. Driving the gated CLI tool keeps the engine free of that dependency.

## lmd

lmd is the consumer this lever targets, because its Swift products build with `swift build`, not `xcodebuild`, so the Xcode store never reaches them.

lmd's build is a hybrid. The Swift products compile through `swift build`. The Metal shader library compiles through `xcodebuild`, because SwiftPM cannot compile `.metal` files. The `xcodebuild` step already routes through `Toolchain`, so it already uses the Xcode store; only the `swift build` half needed the SwiftPM store.

lmd routes its `swift build` and `swift test` through the `SwiftPM` chokepoint, so its Swift products compile through the SwiftPM store and replay unchanged compiles instead of rebuilding them.
