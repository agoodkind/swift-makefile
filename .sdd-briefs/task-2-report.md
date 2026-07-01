# Task 2 Report

## Status

DONE

## Built

Added `Sources/SwiftMkCore/Toolchain+Coverage.swift` with
`Toolchain.coverageDestination(for:)`.

The mapper uses an exhaustive `CoveragePlatform` switch with no `default`.

Registered both new files in `swift.mk` `SWIFT_MK_SCRIPT_FILES`:

- `Sources/SwiftMkCore/Toolchain+Coverage.swift`
- `Tests/SwiftMkCoreTests/ToolchainCoverageTests.swift`

## Tests Added

Added `Tests/SwiftMkCoreTests/ToolchainCoverageTests.swift`.

The test suite asserts these exact mappings:

- `.macosx` returns `platform=macOS`
- `.iphoneos` returns `generic/platform=iOS Simulator`
- `.iphonesimulator` returns `generic/platform=iOS Simulator`
- `.maccatalyst` returns `generic/platform=macOS,variant=Mac Catalyst`

The suite also iterates `CoveragePlatform.allCases` and asserts every platform returns
a non-empty destination.

## TDD Evidence

First `make test` failed before implementation because
`Toolchain.coverageDestination(for:)` did not exist.

Expected red failure tail:

```text
Tests/SwiftMkCoreTests/ToolchainCoverageTests.swift:19:23: error: type 'Toolchain' has no member 'coverageDestination'
Tests/SwiftMkCoreTests/ToolchainCoverageTests.swift:34:26: error: type 'Toolchain' has no member 'coverageDestination'
make[1]: *** [test] Error 1
make: *** [test] Error 2
```

## Verification

`make build` passed after fixing the new extension access lint finding.

Tail:

```text
lint-deadcode: OK
  New findings: 0
swiftcheck-extra: OK
  New findings: 0
Build of product 'swiftcheck-extra' complete! (0.61s)
```

`make test` passed.

Tail:

```text
Test run with 347 tests in 21 suites passed after 17.815 seconds.
Test run with 8 tests in 0 suites passed after 0.006 seconds.
Build complete! (0.60s)
```

`make fmt` passed.

Tail:

```text
Build of product 'swiftcheck-extra' complete! (102.85s)
Build of product 'swiftcheck-extra' complete! (0.62s)
```

`make lint` passed.

Tail:

```text
lint-deadcode: OK
  New findings: 0
swiftcheck-extra: OK
  New findings: 0
```

`git diff --check` passed with no output.

## Deviations

No requested behavior was changed.

I added private destination constants in `Toolchain+Coverage.swift` because the repo's
SwiftLint and swift-format rules conflict when a one-member extension carries a public
member directly. The public API signature remains
`public static func coverageDestination(for platform: CoveragePlatform) -> String`.

## Concerns

No concerns.
