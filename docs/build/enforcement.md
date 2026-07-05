# Build tooling enforcement

A build that spawns the compiler directly skips the chokepoint, so the gate, the lock, and the cache flags do not apply. Two rules fail such a build, one for make recipes and one for Swift dev-tool source. Both allow `swift package` and a `swift <file>.swift` script argument, because neither compiles a package outside the chokepoint.

## Make recipes

[`BuildToolingAudit`](../../Sources/SwiftMkCore/BuildToolingAudit.swift) fails the gate when a tab-indented recipe command runs `swift build`, `swift test`, or `swift run` instead of routing through `$(SWIFT_MK_BIN)`. The audit inspects only recipe command lines, so a make variable assignment such as `SWIFT_BUILD_CMD := swift build` stays legal: the engine runs that command through the [`SwiftPM`](../../Sources/SwiftMkCore/SwiftPM.swift) chokepoint under the gate and the lock. The same audit fails a direct `tuist`, `xcodegen`, `xcodebuild`, or `codesign`, described in the [build gate](../gate/overview.md). The verification is in [`BuildToolingAuditTests`](../../Tests/SwiftMkCoreTests/BuildToolingAuditTests.swift).

## Swift dev-tool source

The `unrouted_build_tooling` rule in the shared analyzer fails when a Swift source spawns the `swift` executable with a compiling subcommand, the shape `run("swift", ["build", ...])` or `["swift", "build", ...]`. A dynamically built argument vector carries no literal subcommand and is not matched, so a dev tool routes its build through the engine [`SwiftPM`](../../Sources/SwiftMkCore/SwiftPM.swift) API rather than a computed spawn. The rule lives in [`RuleSupport.swift`](../../swiftcheck/Sources/SwiftCheckCore/RuleSupport.swift) with its call site in [`Rule.swift`](../../swiftcheck/Sources/SwiftCheckCore/Rule.swift), and the verification is in [`SwiftCheckCoreTests`](../../swiftcheck/Tests/SwiftCheckCoreTests/SwiftCheckCoreTests.swift).
