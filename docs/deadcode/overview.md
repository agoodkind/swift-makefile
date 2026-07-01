# Dead-code gate

The dead-code gate finds unused Swift in a consumer's own code and fails the build when it appears outside the baseline. It runs the Periphery tool over a Swift index store, never over source text, so it sees only what the build compiled.

## Two scans

The gate runs two scans, and the coverage check below requires every owned source to fall under one of them.

- The package scan runs Periphery over the SwiftPM package targets. It is always on. The runner is [`Lint.captureDeadcode`](../../Sources/SwiftMkCore/Lint.swift).
- The Xcode scan runs Periphery over an index store the engine builds. It runs when the repository declares an Xcode build, which the make layer detects from a declared workspace, project, or scheme. The runner is [`DeadcodeScan.appendXcodeFindings`](../../Sources/SwiftMkCore/DeadcodeScan.swift).

A failing run labels each scan in both the terminal and the raw capture, so the package scan's "No unused code detected" never reads as contradicting an Xcode-scan failure. The labels and the classifying verdict line live in [`Lint+DeadcodeVerdict.swift`](../../Sources/SwiftMkCore/Lint+DeadcodeVerdict.swift).

## The engine derives and owns the coverage build

The Xcode scan needs an index store, and the engine builds one from the consumer's normal inputs. The consumer declares no dead-code coverage command and no scheme list. It sets its usual Xcode inputs (a workspace or project, a generator, and an optional coverage configuration and build settings), and the engine derives the rest. The driver is [`Toolchain.buildCoverage`](../../Sources/SwiftMkCore/Toolchain+Coverage.swift).

The coverage matrix comes from the generated project. [`DeadcodeCoverageMatrix`](../../Sources/SwiftMkCore/DeadcodeCoverageMatrix.swift) reads the shared schemes and, for each scheme's buildable target, the platforms it supports, and emits one `(scheme, platform)` entry per supported platform. Test bundles, command-line tools, and SwiftPM package targets drop out, since the package scan already covers the package. [`Toolchain.coverageDestination`](../../Sources/SwiftMkCore/Toolchain+Coverage.swift) maps each platform to its xcodebuild destination. [`DeadcodeCoverageMatrixTests`](../../Tests/SwiftMkCoreTests/DeadcodeCoverageMatrixTests.swift) covers the derivation, and [`ToolchainBuildCoverageTests`](../../Tests/SwiftMkCoreTests/ToolchainBuildCoverageTests.swift) covers the per-entry build, including a distinct result bundle per platform so the same scheme built on two platforms does not collide.

Each scheme builds on every platform it supports because the completeness check below is file-granular. A file compiled on one platform counts as indexed even when its platform-conditional branch on another platform never compiled, so covering that branch needs the scheme built on every platform.

The engine owns every setting that keeps the index complete, through a single xcconfig it points xcodebuild at with `XCODE_XCCONFIG_FILE`. Signing is disabled, since the gate needs the index, not a signed product, and a signed build can fail provisioning and leave a partial index. The compilation cache is disabled, since the index store is written only when the compiler compiles a file, and a cache hit replays a cached object and skips the compiler, so a warm cache would leave the index empty. The build stays on one architecture to avoid a cross-arch module-build race, `OBJROOT` sits under the cleared DerivedData so every coverage build recompiles, and `SYMROOT` is left alone. [`DeadcodeBuildConfig`](../../Sources/SwiftMkCore/DeadcodeBuildConfig.swift) writes the xcconfig and [`DeadcodeBuildConfigTests`](../../Tests/SwiftMkCoreTests/DeadcodeBuildConfigTests.swift) pins each setting.

A consumer whose build needs a native library before xcodebuild links it declares one command in `SWIFT_XCODE_PREBUILD_CMD`. [`ToolchainPrebuild`](../../Sources/SwiftMkCore/ToolchainPrebuild.swift) runs it before every xcodebuild the engine drives, so the prep is a normal-build concern the coverage build reuses rather than a dead-code input.

## A partial index is never scanned

Periphery learns which files exist from the index alone, so an unindexed file looks like a symbol that is never referenced, and a real symbol reads as unused. [`IndexCompleteness`](../../Sources/SwiftMkCore/IndexCompleteness.swift) compares the indexed sources against the project's target sources and refuses to scan when any expected source is missing. The expected set comes from the Xcode project rather than the build, because the coverage build clears its tree and leaves no compiled-file list. The check scopes the expected set to the targets the index actually recorded, so a build that compiles a subset of targets is complete for what it built.

## Every owned source is covered by some scan

[`DeadcodeCoverageCompleteness`](../../Sources/SwiftMkCore/DeadcodeCoverageCompleteness.swift) asserts that every owned Swift source is in the package scan or the Xcode index, so own code in an Xcode target with no coverage build is not silently unscanned. The owned set is the hard-gate [`LintSourceSet`](../../Sources/SwiftMkCore/LintPolicy.swift), minus build-system manifests (`Package.swift`, `Project.swift`, `Tuist.swift`, the `Tuist/` directory) and shebang scripts, which no index records. Sources in a nested package are covered by that package's subtree. The assertion runs on both runner paths and a consumer cannot narrow it. [`DeadcodeCoverageCompletenessTests`](../../Tests/SwiftMkCoreTests/DeadcodeCoverageCompletenessTests.swift) covers the set logic and the manifest, shebang, and nested-package rules.

## Concurrency

Two builds in one worktree share SwiftPM's `.build` and the DerivedData, and the loser of the single-instance lock aborts with a partial index. [`BuildLock`](../../Sources/SwiftMkCore/BuildLock.swift) serializes every build the engine drives in one worktree behind one re-entrant per-worktree `flock`, while builds in separate worktrees stay parallel.
