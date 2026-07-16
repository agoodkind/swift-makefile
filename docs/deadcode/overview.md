# Dead-code gate

The dead-code gate finds unused Swift in a consumer's own code and fails the build when it appears outside the baseline. It runs the Periphery tool over a Swift index store, never over source text, so it sees only what the build compiled.

## Two scans

The gate runs two scans, and the coverage check below requires every owned source to fall under one of them.

- The package scan runs Periphery over the SwiftPM package targets. It is always on. The runner is [Lint.captureDeadcode](../../Sources/SwiftMkCore/Lint.swift).
- The Xcode scan runs Periphery over an index store the engine builds. It runs when the repository declares an Xcode build, which the make layer detects from a declared workspace, project, or scheme. The runner is [DeadcodeScan.appendXcodeFindings](../../Sources/SwiftMkCore/DeadcodeScan.swift).

A failing run labels each scan in both the terminal and the raw capture, so the package scan's "No unused code detected" never reads as contradicting an Xcode-scan failure. The labels and the classifying verdict line live in [Lint+DeadcodeVerdict.swift](../../Sources/SwiftMkCore/Lint+DeadcodeVerdict.swift).

The package scan builds in the same module mode as the product build, so both can share one SwiftPM `.build`. Periphery runs its own `swift build` for the index, and the engine forwards the product build's compile-cache flags (explicit module build) to that scan build. A plain build and an explicit-module build leave `.swiftmodule` files the other cannot reuse, so a later product build fails to resolve their clang module dependencies. The forwarding lives in [Lint.swift](../../Sources/SwiftMkCore/Lint.swift), and [PeripheryPackageScanArgsTests](../../Tests/SwiftMkCoreTests/PeripheryPackageScanArgsTests.swift) pins it.

## The engine derives and owns the coverage build

The Xcode scan needs an index store, and the engine builds one from the consumer's normal inputs. The consumer declares no dead-code coverage command and no scheme list. It sets its usual Xcode inputs (a workspace or project, a generator, and an optional coverage configuration and build settings), and the engine derives the rest. The driver is [Toolchain.buildCoverage](../../Sources/SwiftMkCore/Toolchain+Coverage.swift).

The coverage matrix comes from two authoritative sources, and neither guesses from the raw project file. [DeadcodeCoverageMatrix](../../Sources/SwiftMkCore/DeadcodeCoverageMatrix.swift) selects the schemes to build, then reads each scheme's platforms from `xcodebuild -showdestinations`, and emits one `(scheme, platform)` entry per destination. [Toolchain.coverageDestination](../../Sources/SwiftMkCore/Toolchain+Coverage.swift) maps each platform to its xcodebuild destination, and iOS builds on the simulator so the coverage build needs no device signing. [DeadcodeCoverageMatrixTests](../../Tests/SwiftMkCoreTests/DeadcodeCoverageMatrixTests.swift) covers scheme selection and the destination parser, and [ToolchainBuildCoverageTests](../../Tests/SwiftMkCoreTests/ToolchainBuildCoverageTests.swift) covers the per-entry build, including a distinct result bundle per platform so the same scheme built on two platforms does not collide.

`xcodebuild -showdestinations` is the platform source because it resolves through the consumer's xcconfigs the way a real build does. Reading `SUPPORTED_PLATFORMS` from the project file instead misses a value the generator resolves dynamically, which is how an iOS-plus-Mac-Catalyst app looks Catalyst-only in the raw file and loses its iPhone build. [Toolchain.showDestinations](../../Sources/SwiftMkCore/Toolchain.swift) runs the query.

The scheme set comes from the project's schemes, filtered two ways. A scheme stays only when a build-for-testing target carries indexable app or framework code, so test bundles, command-line tools, and SwiftPM package targets drop out. A scheme also stays only when `xcodebuild -list` reports it for the container, so a scheme read from a workspace's dependency project (a vendored package, WireGuardKit) that the workspace cannot build drops out. A project with no shared schemes, which is what xcodegen writes by default, uses one auto-scheme per indexable native target instead.

Each scheme builds on every platform it supports because the completeness check below is file-granular. A file compiled on one platform counts as indexed even when its platform-conditional branch on another platform never compiled, so covering that branch needs the scheme built on every platform.

The engine owns every setting that keeps the index complete, through a single xcconfig it points xcodebuild at with `XCODE_XCCONFIG_FILE`. Signing is disabled, since the gate needs the index, not a signed product, and a signed build can fail provisioning and leave a partial index. The compilation cache is disabled, since the index store is written only when the compiler compiles a file, and a cache hit replays a cached object and skips the compiler, so a warm cache would leave the index empty. The build stays on one architecture to avoid a cross-arch module-build race, `OBJROOT` sits under the cleared DerivedData so every coverage build recompiles, and `SYMROOT` is left alone. [DeadcodeBuildConfig](../../Sources/SwiftMkCore/DeadcodeBuildConfig.swift) writes the xcconfig and [DeadcodeBuildConfigTests](../../Tests/SwiftMkCoreTests/DeadcodeBuildConfigTests.swift) pins each setting.

A relative derived-data path resolves against the consumer's working directory before the engine writes `OBJROOT`, so the coverage build puts its intermediates in the consumer's tree rather than in the shared SwiftPM clone. SwiftPM dependency targets that wrote into the shared clone would scatter their intermediates outside the coverage tree and leave the index incomplete. The anchoring lives in [DeadcodeBuildConfig](../../Sources/SwiftMkCore/DeadcodeBuildConfig.swift) and [DeadcodeScan](../../Sources/SwiftMkCore/DeadcodeScan.swift), and [deadcodeBuildConfigResolvesRelativeObjrootAgainstConsumerRoot](../../Tests/SwiftMkCoreTests/DeadcodeBuildConfigTests.swift) verifies it.

A consumer whose build needs a native library before xcodebuild links it declares one command in `SWIFT_XCODE_PREBUILD_CMD`. [ToolchainPrebuild](../../Sources/SwiftMkCore/ToolchainPrebuild.swift) runs it before every xcodebuild the engine drives, so the prep is a normal-build concern the coverage build reuses rather than a dead-code input.

## A partial index is never scanned

Periphery learns which files exist from the index alone, so an unindexed file looks like a symbol that is never referenced, and a real symbol reads as unused. [IndexCompleteness](../../Sources/SwiftMkCore/IndexCompleteness.swift) compares the indexed sources against the project's target sources and refuses to scan when any expected source is missing. The expected set comes from the Xcode project rather than the build, because the coverage build clears its tree and leaves no compiled-file list. The check scopes the expected set to the targets the index actually recorded, so a build that compiles a subset of targets is complete for what it built.

## A protocol witness is not reported unused

The gate keeps a protocol witness that runs only through the protocol, so a method called by dynamic dispatch does not read as dead. A witness reached only through its protocol has no direct reference in the index, and Periphery reports it unused even though a real call runs it. The engine reads the index facts, sees the witness overrides a requirement that other code references, and drops the finding. A witness whose requirement no code ever calls still reports, so a truly unused conformance member is not hidden. [WitnessFilter](../../Sources/SwiftMkCore/WitnessFilter.swift) applies the rule and [WitnessFilterTests](../../Tests/SwiftMkCoreTests/WitnessFilterTests.swift) covers both outcomes.

## Every owned source is covered by some scan

[DeadcodeCoverageCompleteness](../../Sources/SwiftMkCore/DeadcodeCoverageCompleteness.swift) asserts that every owned Swift source is in the package scan or the Xcode index, so own code in an Xcode target with no coverage build is not silently unscanned. The owned set is the hard-gate [LintSourceSet](../../Sources/SwiftMkCore/LintPolicy.swift), minus build-system manifests (`Package.swift`, `Project.swift`, `Tuist.swift`, the `Tuist/` directory) and shebang scripts, which no index records. Sources in a nested package are covered by that package's subtree. The assertion runs on both runner paths and a consumer cannot narrow it. [DeadcodeCoverageCompletenessTests](../../Tests/SwiftMkCoreTests/DeadcodeCoverageCompletenessTests.swift) covers the set logic and the manifest, shebang, and nested-package rules.

## Concurrency

Two builds in one worktree share SwiftPM's `.build` and the DerivedData, and the loser of the single-instance lock aborts with a partial index. [BuildLock](../../Sources/SwiftMkCore/BuildLock.swift) serializes every build the engine drives in one worktree behind one re-entrant per-worktree `flock`, while builds in separate worktrees stay parallel.
