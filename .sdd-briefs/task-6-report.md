# Task 6 report

Status: complete.

## Summary

`DeadcodeScan.ensureIndexStore` now always builds Xcode coverage through
`Toolchain.buildCoverage(_:)`. The make path no longer shells
`SWIFT_DEADCODE_BUILD_CMD` or `SWIFT_BUILD_CMD`, and the in-process path no
longer accepts a consumer coverage callback.

## Files changed

- `Sources/SwiftMkCore/DeadcodeScan.swift`
- `Sources/SwiftMkCore/Toolchain+Coverage.swift`
- `Sources/SwiftMkCore/Toolchain+GatedCompile.swift`
- `Sources/SwiftMkCore/GatedBuild.swift`
- `Sources/SwiftMkCore/Lint.swift`
- `Sources/SwiftMkCore/LintPolicy.swift`
- `Sources/SwiftMkCore/Toolchain.swift`
- `Sources/SwiftMkCore/DeadcodeCoverageCompleteness.swift`
- Deleted `Sources/SwiftMkCore/DeadcodeCoverageAuthorization.swift`
- `Tests/SwiftMkCoreTests/DeadcodeCoverageTests.swift`
- `Tests/SwiftMkCoreTests/GatedBuildHarness.swift`
- `Tests/SwiftMkCoreTests/HardGateTests.swift`
- `Tests/SwiftMkCoreTests/ToolchainReceiptTests.swift`
- `swift.mk`
- `README.md`
- `docs/deadcode/overview.md`

## New ensureIndexStore control flow

`scanProject` discovers schemes, reads package target names, filters package
schemes out of the Xcode scan, then passes `path`, `isWorkspace`, and
`packageTargets` into `ensureIndexStore`.

`ensureIndexStore` resolves DerivedData with
`DeadcodeBuildConfig.resolvedDerivedDataRoot(Env.get("SWIFT_MK_DERIVED_DATA"))`,
builds a `Toolchain.CoverageBuildOptions` value, and calls
`Toolchain.buildCoverage(_:)`.

On nonzero coverage status, it still calls `diagnoseFailedCoverage(...)` with
the captured output and returns nil. On success, it still checks
`existingIndexStore(derivedData)`, waits with `IndexStoreSettle.waitForStable`,
and returns the produced index store. If no index store exists, it still fails
hard before Periphery can scan a partial index.

## Coverage environment variables

The coverage options now read these variables:

- `SWIFT_XCODE_GENERATOR`: resolves `Toolchain.Generator`, defaulting to
  `Toolchain.Generator.tuist.rawValue`.
- `SWIFT_XCODE_COVERAGE_CONFIGURATION`: selects the coverage build
  configuration, defaulting to `Debug`.
- `SWIFT_XCODE_BUILD_SETTINGS`: parsed as `KEY=value` words into
  `CoverageBuildOptions.extraSettings`.
- `SWIFT_MK_DERIVED_DATA`: passed as `CoverageBuildOptions.derivedDataPath`.

The signing-disabled, cache-off, index-enabled environment still comes from
`DeadcodeBuildConfig.buildEnvironment(derivedData:)`, using the resolved
DerivedData path.

## Removed symbols and call-site updates

- Removed `DeadcodeCoverageBuild`.
- Removed `DeadcodeCoverageAuthorization`.
- Removed `GatedBuild.Hooks.deadcodeCoverage`.
- Removed `Toolchain.buildForTesting(_:authorization:environment:)`.
- Removed `Toolchain.buildForTestingCapturingOutput(_:authorization:environment:)`.
- Removed `DeadcodeScan.coverageBuildCommand()`.
- Removed the `SWIFT_DEADCODE_BUILD_CMD` default and export from `swift.mk`.
- Moved `DeadcodeCoverageResult` into `Toolchain+Coverage.swift`.
- Updated `LintPolicy.deadcode` and `Lint.runHardBuildCheck` to call the
  dead-code gate without a callback.
- Updated `DeadcodeScan.appendXcodeFindings` to key only off
  `SWIFT_MK_XCODE_BUILD`.
- Updated `swift.mk` Xcode detection to use `SWIFT_XCODE_SCHEME`,
  `SWIFT_XCODE_WORKSPACE`, or `SWIFT_XCODE_PROJECT`.
- Removed `DeadcodeCoverageAuthorization.swift` from `SWIFT_MK_SCRIPT_FILES`.

## Tests adapted

- `DeadcodeCoverageTests` now covers the `CoverageBuildOptions` builder and its
  environment-derived generator, configuration, build settings, package targets,
  DerivedData path, and `DeadcodeBuildConfig` environment.
- `DeadcodeCoverageTests` now calls the new
  `ensureIndexStore(path:isWorkspace:packageTargets:rawPath:)` signature.
- `ToolchainReceiptTests` now covers only the remaining receipt-authorized product
  build overload.
- `HardGateTests` now calls `LintPolicy.deadcode(context:)`.
- `GatedBuildHarness` no longer snapshots or clears `SWIFT_DEADCODE_BUILD_CMD`.

## Verification

Red step:

```text
make test
DeadcodeCoverageTests.swift:51:34: error: type 'DeadcodeScan' has no member 'coverageBuildOptions'
DeadcodeCoverageTests.swift:80:49: error: extra arguments at positions #1, #2, #3 in call
```

`make build` passed:

```text
lint-deadcode: OK
  New findings: 0
swiftcheck-extra: OK
  New findings: 0
Build of product 'swiftcheck-extra' complete! (0.61s)
```

`make test` passed:

```text
Test run with 354 tests in 23 suites passed after 20.165 seconds.
Test run with 8 tests in 0 suites passed after 0.005 seconds.
Build complete! (0.61s)
```

`make fmt` passed:

```text
Build of product 'swiftcheck-extra' complete! (102.63s)
Build of product 'swiftcheck-extra' complete! (0.62s)
```

`make lint` passed:

```text
lint-deadcode: OK
  New findings: 0
swiftcheck-extra: OK
  New findings: 0
```

`make check` passed:

```text
lint-deadcode: OK
  New findings: 0
swiftcheck-extra: OK
  New findings: 0
```

## Notes

The deleted `DeadcodeCoverageAuthorization.swift` file had to be staged before
the gate could pass, because `LintSourceSet` reads the git index and otherwise
still treated the deleted tracked file as owned Swift source.

The existing untracked task brief files were left uncommitted. This report file
is the only new `.sdd-briefs` artifact intended for this task.
