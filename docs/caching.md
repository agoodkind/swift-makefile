# Compilation caching

swift-makefile caches Swift compilation so a build replays unchanged compiles from a content-addressed store instead of recompiling them. Two stores exist because two compilers run across the consumers: `xcodebuild` for the Tuist and xcodegen consumers, and `swift build` for the SwiftPM consumers such as lmd.

## The two stores

Both stores hold LLVM content-addressed compilation results (a CAS, the compiler's term for its cache). A build that finds a result for an input replays the cached output and skips the compile.

The Xcode store serves `xcodebuild`. The engine enables it by injecting `COMPILATION_CACHE_ENABLE_CACHING=YES` and pointing `COMPILATION_CACHE_CAS_PATH` at the shared path in `Toolchain.sharedCacheArguments()`. `SWIFT_MK_XCODE_CACHE_PATH` names that path. `SWIFT_MK_XCODE_CACHE` gates it on by default on Xcode 26 and later.

The SwiftPM store serves `swift build`. The engine injects the compile-cache flags in `SwiftPM.cacheArguments()`, which every `swift build` and `swift test` that runs through the `SwiftPM` chokepoint receives. `SWIFT_MK_SWIFTPM_CACHE_PATH` names that path.

Both stores live outside DerivedData, under `SWIFT_MK_CACHE_ROOT` (default `$HOME/Library/Caches/swift-mk`). Keeping them outside DerivedData matters because the dead-code coverage build runs `rm -rf $(SWIFT_MK_DERIVED_DATA)`, which would otherwise destroy a store kept inside it. Both stores are content-addressed, so one shared copy is safe across worktrees, and both are cached cross-runner in the dependency bucket of `CachePaths`, so a code-only change restores the store and the next build replays.

## SwiftPM compilation caching is opt-in

SwiftPM compilation caching is off by default. A consumer turns it on with `SWIFT_MK_SWIFTPM_COMPILE_CACHE=auto` after validating its own build.

The reason is the required flag. `swift build` only caches when it runs in explicit-module-build mode, so the engine passes `-Xswiftc -explicit-module-build` alongside `-Xswiftc -cache-compile-job` and `-Xswiftc -cas-path`. Without `-explicit-module-build`, `swift build` prints `cannot be used without explicit module build, turn off caching` and the store stays empty.

Explicit module builds change how the compiler resolves modules, which can break a macro or C-interop target that an implicit-module build compiled. The off-by-default knob keeps that risk on the consumer that opts in, not on every `swift build` the engine runs. The make layer also forces the enable flag to NO when the toolchain does not advertise `-cache-compile-job`, so an older toolchain never receives the flags.

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

lmd routes its `swift build` and `swift test` through the `SwiftPM` chokepoint, which gives it the SwiftPM cache flags when the consumer opts in. A same-path bisect on lmd's MLX Swift target replayed 8649 outputs from the store with zero misses after a cold build of 943 compiles, which is the recompile elimination the caching exists to deliver.
