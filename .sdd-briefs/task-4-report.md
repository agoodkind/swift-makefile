# Task 4 Report

## Status

DONE

## Files Added

- `Sources/SwiftMkCore/ToolchainPrebuild.swift`
- `Tests/SwiftMkCoreTests/ToolchainPrebuildTests.swift`

## Implementation

`ToolchainPrebuild.run()` now reads `SWIFT_XCODE_PREBUILD_CMD` through `Env.get`, trims whitespace, and returns `true` without side effects when the command is empty.

The helper returns `true` without running the command when `SWIFT_MK_IN_PREBUILD=1`, which prevents recursive prebuild execution when a consumer prebuild command drives another xcodebuild path.

The helper sets `SWIFT_MK_IN_PREBUILD=1` while running the command through `Shell.sh(command)`, emits combined output through `Output.emitStandardOutput`, restores the prior guard value afterward, logs `prebuild: SWIFT_XCODE_PREBUILD_CMD failed status=N` on failure, and returns `false` for a nonzero command status.

## Toolchain Wiring

`Sources/SwiftMkCore/Toolchain.swift` now defines `prebuildFailureStatus` next to the existing nonzero build failure status.

The three requested xcodebuild spawn sites now guard with `ToolchainPrebuild.run()`:

- `runXcodebuildForwarding(_:actions:environment:)` returns `prebuildFailureStatus` when prebuild fails.
- `runXcodebuildCapturing(_:actions:environment:)` returns `Shell.StreamingResult(status: prebuildFailureStatus, stdout: "", timedOut: false)` when prebuild fails.
- `buildWritingLog(_:logPath:clean:)` keeps `GateProof.refusal` first, then returns `prebuildFailureStatus` when prebuild fails before `Shell.runWritingOutput`.

`GatedBuild.Hooks` was not modified.

## swift.mk

`SWIFT_XCODE_PREBUILD_CMD ?=` is declared beside the other `SWIFT_XCODE_*` variables.

`SWIFT_XCODE_PREBUILD_CMD` is exported beside the Xcode build argument variables.

`SWIFT_MK_SCRIPT_FILES` now includes both new files:

- `Sources/SwiftMkCore/ToolchainPrebuild.swift`
- `Tests/SwiftMkCoreTests/ToolchainPrebuildTests.swift`

## Tests Added

`ToolchainPrebuildTests` is serialized because it mutates process environment.

The suite covers:

- Unset and whitespace-only `SWIFT_XCODE_PREBUILD_CMD` return `true` and do not create a marker.
- A configured marker command returns `true` and creates the marker.
- A failing command returns `false`.
- `SWIFT_MK_IN_PREBUILD=1` skips the marker command and returns `true`.
- `runXcodebuildForwarding` with the existing `GatedBuildHarness` fake xcodebuild runs the prebuild marker command and the xcodebuild marker command.

## TDD Evidence

Initial red run:

```text
make test
error: cannot find 'ToolchainPrebuild' in scope
make: *** [test] Error 2
```

Green run after implementation:

```text
make test
Test run with 352 tests in 22 suites passed
Test run with 8 tests in 0 suites passed
exit 0
```

## Final Verification

`make build`:

```text
build-tooling-audit: OK
swiftlint: OK
lint-complexity: OK
lint-deadcode: OK
swiftcheck-extra: OK
Build of product 'swift-mk-render' complete
Build of product 'swiftcheck-extra' complete
exit 0
```

`make fmt`:

```text
Build of product 'swiftcheck-extra' complete
exit 0
```

`make lint`:

```text
build-tooling-audit: OK
swiftlint: OK
lint-complexity: OK
lint-deadcode: OK
swiftcheck-extra: OK
nested swiftcheck lint also exited 0
```

Final `make test`:

```text
Test run with 352 tests in 22 suites passed
ToolchainPrebuildTests passed
Test run with 8 tests in 0 suites passed
exit 0
```

`git diff --check`:

```text
exit 0
```

## Notes

The first `make build` after adding the guards found a `Toolchain.swift` file-length finding because the new failure status added a counted line. I changed it to share the existing status declaration line, reran `make build`, and the gate passed.

A direct typographic dash scan command was blocked by the repo hook because this indexed codebase requires semantic search for grep-like commands. The inspected added code and comments use ASCII hyphens only, and `git diff --check` is clean.

## Fix pass

The xcodegen branch of `Toolchain.test(_:)` now routes `xcodebuild test` through `runXcodebuildForwarding(request, actions: ["test"], environment: [:])`, so `ToolchainPrebuild.run()` fires before that xcodebuild spawn while the tuist branch remains unchanged.

`gateFailureStatus` is restored as its own documented constant, and `prebuildFailureStatus` is now a separate documented constant in the raw xcodebuild invocation extension near the runners that use it.

The regression test `xcodegenTestRunsPrebuildCommandFirst` first failed because the prebuild marker was missing, then passed after the xcodegen test path used the xcodebuild chokepoint.

The single-action `xcodebuildArguments(_:action:resultBundleDirectory:)` overload was removed after `make build` reported it as newly unused, and the tests now call the existing multi-action assembler directly.

`make test` tail:

```text
Test run with 353 tests in 22 suites passed after 18.284 seconds.
/Applications/Xcode-26.5.0.app/Contents/Developer/usr/bin/make -C swiftcheck -f ../swift.mk ...
Test run with 8 tests in 0 suites passed after 0.006 seconds.
[0/1] Planning build
Building for debugging...
[0/4] Write swift-version-69A768CDF2A0BEE1.txt
Build complete! (0.63s)
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
```
