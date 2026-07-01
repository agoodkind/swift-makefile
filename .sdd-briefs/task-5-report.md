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
