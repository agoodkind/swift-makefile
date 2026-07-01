# Task 5 Report

Status: DONE_WITH_CONCERNS

## Implementation

Added `Toolchain.CoverageBuildOptions`, `Toolchain.buildCoverage(_:)`, and `Toolchain.buildCoverageEntries(_:options:)` in `Sources/SwiftMkCore/Toolchain+Coverage.swift`.

`buildCoverage(_:)` enumerates the matrix through `DeadcodeCoverageMatrix.entries(containerPath:isWorkspace:packageTargetNames:)`, returns a nonzero `DeadcodeCoverageResult` with a logged message on enumeration failure or an empty matrix, wipes the resolved DerivedData root through `DeadcodeBuildConfig.resolvedDerivedDataRoot(_:)`, and then calls the entries loop.

`buildCoverageEntries(_:options:)` creates a `Toolchain.Request` for each `DeadcodeCoverageEntry`, sets the container as `workspace` or `project`, sets the entry scheme and requested configuration, forwards `derivedDataPath` and `extraSettings`, and injects `["-destination", Toolchain.coverageDestination(for: entry.platform)]` through `extraArguments`. It calls the raw `runXcodebuildCapturing(_:actions:environment:)` runner with `["build-for-testing"]`, concatenates captured stdout, and returns the first nonzero xcodebuild status.

When `SWIFT_MK_RESULT_BUNDLE_DIR` is present in the coverage environment, each entry receives a copied environment with the platform raw value appended to the result-bundle directory. This makes the same scheme built for macOS and Mac Catalyst write to separate result-bundle roots.

Added `Toolchain.deadcodeCoverageEnvironment(derivedDataPath:)` so the CLI can reuse `DeadcodeBuildConfig.buildEnvironment(derivedData:)` without exposing `DeadcodeBuildConfig` directly from `SwiftMkCore`.

## CLI

Added `swift-mk toolchain coverage` in `Sources/SwiftMkCLI/ToolchainCommand.swift`.

The command accepts `--generator`, exactly one of `--workspace` or `--project`, `--configuration`, `--derived-data-path`, and trailing `KEY=value` build settings. It rejects missing or double containers and reuses the same signing-setting validation as the existing build command path.

The command checks `GateProof.refusal(entry: "toolchain coverage")`, builds the coverage environment via `Toolchain.deadcodeCoverageEnvironment(derivedDataPath:)`, emits the captured output, and exits with the coverage result status.

The CLI passes an empty `packageTargetNames` set because `DeadcodeScan.packageTargetNames()` is internal to `SwiftMkCore` and is not reachable from `SwiftMkCLI` without exposing more gate internals.

## Tests

Added `Tests/SwiftMkCoreTests/ToolchainBuildCoverageTests.swift` and registered it in `swift.mk` `SWIFT_MK_SCRIPT_FILES`.

Extended `GatedBuildHarness` so the fake xcodebuild records argument vectors, records each per-call `SWIFT_MK_RESULT_BUNDLE_DIR`, emits captured stdout, and can fail a selected scheme.

The new tests cover:

- `buildCoverageEntries(_:options:)` runs one xcodebuild call per hand-built coverage entry.
- Each xcodebuild call carries the mapped `-destination`.
- Workspace and project containers are selected correctly.
- Result-bundle roots are scoped by platform when `SWIFT_MK_RESULT_BUNDLE_DIR` is set.
- The aggregated result status is zero when every fake xcodebuild succeeds.
- The aggregated result status is the first nonzero status when one fake xcodebuild fails, and later entries still run.

The on-disk project enumeration path stays covered by Task 1 matrix tests and later consumer end-to-end coverage, as requested.

## Verification

Red test: `make test` failed before implementation because `Toolchain.buildCoverageEntries` did not exist.

`make fmt` passed after formatting.

`make build` passed. Tail:

```text
lint-deadcode: OK
  New findings: 0
swiftcheck-extra: OK
  New findings: 0
Build of product 'swiftcheck-extra' complete!
```

`make test` passed. Tail:

```text
Test run with 355 tests in 23 suites passed
Test run with 8 tests in 0 suites passed
```

`make lint` passed. Tail:

```text
lint-deadcode: OK
  New findings: 0
swiftcheck-extra: OK
  New findings: 0
```

## Concerns

The brief requested exact eight-parameter `buildCoverage(...)` and `buildCoverageEntries(...)` signatures. The repo's gates reject functions with more than five parameters, and they also reject inline SwiftLint disables. I used `Toolchain.CoverageBuildOptions` instead so the implementation can pass `make build`, `make test`, `make fmt`, and `make lint`.

## Fix pass

Status: DONE

Threaded the per-platform result-bundle directory into the real xcodebuild argument path. `runXcodebuildCapturing(_:actions:environment:resultBundleDirectory:)` now forwards the explicit directory to `xcodebuildArguments(_:actions:resultBundleDirectory:)`, and `buildCoverageEntries(_:options:)` computes the directory from the same base `SWIFT_MK_RESULT_BUNDLE_DIR` environment value that `DeadcodeBuildConfig.buildEnvironment(derivedData:)` sets.

Updated `ToolchainBuildCoverageTests` so the result-bundle uniqueness assertion reads the fake xcodebuild argument vector and verifies each invocation contains a unique `-resultBundlePath`. The red proof failed under `make test` before the production fix because the recorded argv did not contain `-resultBundlePath`, and the same run also showed the empty derived-data path regression.

Fixed coverage derived-data handling so an empty coverage path becomes nil before building the `Toolchain.Request`, which omits `-derivedDataPath` instead of sending an empty value. The coverage CLI now also returns immediately after a gate refusal exits.

`make test` tail:

```text
􁁛  Test run with 356 tests in 23 suites passed after 20.048 seconds.
[0/1] Planning build
[1/1] Compiling plugin GRPCSwiftPlugin
[2/2] Compiling plugin SwiftProtobufPlugin
[3/3] Compiling plugin GenerateManual
[4/4] Compiling plugin GenerateDoccReference
Building for debugging...
[4/10] Write swift-version-69A768CDF2A0BEE1.txt
Build complete! (11.71s)
/Applications/Xcode-26.5.0.app/Contents/Developer/usr/bin/make -C swiftcheck -f ../swift.mk SWIFT_MK_DEV_DIR='/Users/agoodkind/Sites/swift-makefile/.claude/worktrees/deadcode-coverage-owned' SWIFT_MK_MODULES=swift-build.mk SWIFT_BUILD_CMD='swift build --product swiftcheck-extra' SWIFT_TEST_CMD='swift test' SWIFT_CLEAN_CMD='swift package clean' SWIFT_FORMAT_TARGETS='Package.swift Sources Tests' SWIFTLINT_TARGETS='Package.swift Sources Tests' SWIFT_MK_SWIFTLINT_CONFIG='../.swiftlint.yml' SWIFT_MK_SWIFT_FORMAT_CONFIG='../.swift-format' SWIFT_MK_PERIPHERY_CONFIG='../.periphery.yml' SWIFTLINT_FLAGS='--config ../.swiftlint.yml --reporter xcode' PERIPHERY_ARGS='scan --config ../.periphery.yml --exclude-tests' SWIFT_MK_BIN='/Users/agoodkind/Sites/swift-makefile/.claude/worktrees/deadcode-coverage-owned/.make/swift-mk' SWIFTCHECK_EXTRA_BUILD_REPO='/Users/agoodkind/Sites/swift-makefile/.claude/worktrees/deadcode-coverage-owned/swiftcheck' test
Test Suite 'All tests' started at 2026-06-30 21:52:38.273.
Test Suite 'All tests' passed at 2026-06-30 21:52:38.275.
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.002) seconds
􁁛  Test run with 8 tests in 0 suites passed after 0.006 seconds.
[0/1] Planning build
Building for debugging...
[0/4] Write swift-version-69A768CDF2A0BEE1.txt
Build complete! (0.60s)
```

`make lint` tail:

```text
deadcode: package scan (Swift package targets)
* Building...
* Indexing...
* Analyzing...

* No unused code detected.
lint-deadcode: OK
  New findings: 0
swiftcheck-extra: OK
  New findings: 0
/Applications/Xcode-26.5.0.app/Contents/Developer/usr/bin/make -C swiftcheck -f ../swift.mk SWIFT_MK_DEV_DIR='/Users/agoodkind/Sites/swift-makefile/.claude/worktrees/deadcode-coverage-owned' SWIFT_MK_MODULES=swift-build.mk SWIFT_BUILD_CMD='swift build --product swiftcheck-extra' SWIFT_TEST_CMD='swift test' SWIFT_CLEAN_CMD='swift package clean' SWIFT_FORMAT_TARGETS='Package.swift Sources Tests' SWIFTLINT_TARGETS='Package.swift Sources Tests' SWIFT_MK_SWIFTLINT_CONFIG='../.swiftlint.yml' SWIFT_MK_SWIFT_FORMAT_CONFIG='../.swift-format' SWIFT_MK_PERIPHERY_CONFIG='../.periphery.yml' SWIFTLINT_FLAGS='--config ../.swiftlint.yml --reporter xcode' PERIPHERY_ARGS='scan --config ../.periphery.yml --exclude-tests' SWIFT_MK_BIN='/Users/agoodkind/Sites/swift-makefile/.claude/worktrees/deadcode-coverage-owned/.make/swift-mk' SWIFTCHECK_EXTRA_BUILD_REPO='/Users/agoodkind/Sites/swift-makefile/.claude/worktrees/deadcode-coverage-owned/swiftcheck' lint
[0/1] Planning build
Building for production...
[0/2] Write swift-version-69A768CDF2A0BEE1.txt
Build of product 'swiftcheck-extra' complete! (0.70s)
build-tooling-audit: OK
swiftlint: OK
  New findings: 0
lint-complexity: OK
  New findings: 0
deadcode: package scan (Swift package targets)
* Building...
* Indexing...
* Analyzing...

* No unused code detected.
lint-deadcode: OK
  New findings: 0
swiftcheck-extra: OK
  New findings: 0
```
