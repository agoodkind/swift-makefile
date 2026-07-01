# Dead-code gate

The dead-code gate finds unused Swift in a consumer's own code and fails the build when it appears outside the baseline. It runs the Periphery tool over a Swift index store, never over source text, so it sees only what the build compiled.

## Two scans

The gate runs two scans, and the coverage check below requires every owned source to fall under one of them.

- The package scan runs Periphery over the SwiftPM package targets. It is always on. The runner is [`Lint.captureDeadcode`](../../Sources/SwiftMkCore/Lint.swift).
- The Xcode scan runs Periphery over an index store built by `Toolchain.buildCoverage`, and it runs only when the consumer sets `SWIFT_MK_XCODE_BUILD=1`. The runner is [`DeadcodeScan.appendXcodeFindings`](../../Sources/SwiftMkCore/DeadcodeScan.swift).

A failing run labels each scan in both the terminal and the raw capture, so the package scan's "No unused code detected" never reads as contradicting an Xcode-scan failure. The labels and the classifying verdict line live in [`Lint+DeadcodeVerdict.swift`](../../Sources/SwiftMkCore/Lint+DeadcodeVerdict.swift).

## The coverage build is separate and signing-disabled

The Xcode scan needs an index store, and it builds one with a coverage build that disables code signing. A signed build can fail provisioning, exit non-zero, and leave a partial index, so the coverage build is never the real signed build. [`DeadcodeBuildConfig`](../../Sources/SwiftMkCore/DeadcodeBuildConfig.swift) writes the signing-disabled xcconfig and points `OBJROOT` at an absolute path under the cleared DerivedData, with `SYMROOT` left alone. [`DeadcodeBuildConfigTests`](../../Tests/SwiftMkCoreTests/DeadcodeBuildConfigTests.swift) pins each setting.

## A partial index is never scanned

Periphery learns which files exist from the index alone, so an unindexed file looks like a symbol that is never referenced, and a real symbol reads as unused. [`IndexCompleteness`](../../Sources/SwiftMkCore/IndexCompleteness.swift) compares the indexed sources against the project's target sources and refuses to scan when any expected source is missing. The expected set comes from the Xcode project rather than the build, because the coverage build clears its tree and leaves no compiled-file list. The check scopes the expected set to the targets the index actually recorded, so a build that compiles a subset of targets is complete for what it built.

## Every owned source is covered by some scan

[`DeadcodeCoverageCompleteness`](../../Sources/SwiftMkCore/DeadcodeCoverageCompleteness.swift) asserts that every owned Swift source is in the package scan or the Xcode index, so own code in an Xcode target with no coverage build is not silently unscanned. The owned set is the hard-gate [`LintSourceSet`](../../Sources/SwiftMkCore/LintPolicy.swift), minus build-system manifests (`Package.swift`, `Project.swift`, `Tuist.swift`, the `Tuist/` directory) and shebang scripts, which no index records. Sources in a nested package are covered by that package's subtree. The assertion runs on both runner paths and a consumer cannot narrow it. [`DeadcodeCoverageCompletenessTests`](../../Tests/SwiftMkCoreTests/DeadcodeCoverageCompletenessTests.swift) covers the set logic and the manifest, shebang, and nested-package rules.

## Concurrency

Two builds in one worktree share SwiftPM's `.build` and the DerivedData, and the loser of the single-instance lock aborts with a partial index. [`BuildLock`](../../Sources/SwiftMkCore/BuildLock.swift) serializes every build the engine drives in one worktree behind one re-entrant per-worktree `flock`, while builds in separate worktrees stay parallel.
