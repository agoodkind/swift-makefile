# swift-mk owns build-time code signing (single source of truth)

Date: 2026-06-05
Status: approved (acceptance criteria set as session goal)

## Problem

swift-makefile delegates the actual `xcodebuild`/`tuist` invocation to each
consumer through the `SWIFT_BUILD_CMD` hook, because the build line differs per
project (`swift-app.mk:11-12`). Build-time code-signing therefore lives scattered
across consumer code: a Swift dev tool (`iphone-cell-tunnel/Tools/CellTunnelDev/BuildDispatch.swift`),
an `app-local` make target (`macos-fan-curve`), and project-embedded settings
(`stickies-improved`). swift-mk never sees those signing flags, so it can neither
apply nor enforce them.

The root cause of the recurring drift is that Tuist defaults every target to
`CODE_SIGN_IDENTITY = -` (ad-hoc) at the target level, which overrides xcconfig
values. Consumers work around it by forwarding `$(CODE_SIGN_IDENTITY)` /
`$(CODE_SIGN_STYLE)` / `$(DEVELOPMENT_TEAM)` into every target and SDK slice
(`iphone-cell-tunnel/Project.swift:49-57,78-85`). Any target that forgets the
forwarding silently signs ad-hoc, which is exactly what happened to the Mac agent
("Signing Identity: Sign to Run Locally", `TeamIdentifier=not set`).

There is no signing verification gate in `LINT_GATES` (`swift.mk:248`), so the
drift passes every check.

The CI release path is already centralized through swift-makefile's shared
GitHub Actions (`.github/actions/import-signing-cert`, `.github/actions/notarize-staple`),
used by `macos-fan-curve` and `stickies-improved`. The gap this design closes is
the build-time (local + PR-check) signing path.

## Approach

swift-mk owns a top-precedence override xcconfig, mirroring the proven
`DeadcodeBuildConfig` pattern (`Sources/SwiftMkCore/DeadcodeBuildConfig.swift`),
which already uses `XCODE_XCCONFIG_FILE` to override target settings (it forces
`CODE_SIGNING_ALLOWED = NO` for the dead-code build over the consumer's target
settings, proving the precedence holds in this toolchain).

### 1. `SigningBuildConfig` (new, `Sources/SwiftMkCore/`)

Writes `.make/signing.xcconfig` and returns `{XCODE_XCCONFIG_FILE: <abs path>}`.
Style is inferred from the two values consumers already set, never chosen:

| `CODE_SIGN_IDENTITY` | `DEVELOPMENT_TEAM` | xcconfig written |
| --- | --- | --- |
| `-` | (any) | ad-hoc: `CODE_SIGN_IDENTITY = -`, `CODE_SIGN_STYLE = Manual`, `CODE_SIGNING_ALLOWED = YES`, `CODE_SIGNING_REQUIRED = NO` |
| real identity | set | Manual / Developer ID: identity + team + `CODE_SIGN_STYLE = Manual` |
| empty | set | Automatic development: team + `CODE_SIGN_STYLE = Automatic` |
| empty | empty | empty env, no override (unsigned builds still work) |

Write failure returns an empty env and logs, exactly like `DeadcodeBuildConfig`,
so a filesystem hiccup never blocks a build.

### 2. CLI + wiring

A `swift-mk` subcommand writes the file and yields its path. `swift-build.mk`'s
`build` and `deploy` recipes export `XCODE_XCCONFIG_FILE` from it before running
`SWIFT_GENERATE_CMD` / `SWIFT_BUILD_CMD`, gated on team-or-identity being set.
Scoped to `build`/`deploy` only, so the dead-code coverage path keeps its own
disable-signing xcconfig and never sees the signing one. If `XCODE_XCCONFIG_FILE`
is already set on entry, swift-mk warns rather than silently clobbering.

Variable contract: swift-mk reads the bare `DEVELOPMENT_TEAM` / `CODE_SIGN_IDENTITY`
/ `CODE_SIGN_STYLE` make vars the consumers already define, with optional
`SWIFT_MK_SIGN_*` overrides for explicitness.

### 3. Per-consumer minor edits (mostly deletions)

- **iphone-cell-tunnel**: delete per-scheme signing `buildSettings` from
  `BuildDispatch.swift`; drop `$(CODE_SIGN_IDENTITY)` forwarding in
  `macHardenedRuntimeSettings` and the `[sdk=macosx*]` Catalyst forwarding in
  `Project.swift`; remove `ENABLE_DEBUG_DYLIB = NO` and verify the team-signed
  Debug agent spawns. Keep the vars exported for swift-mk to read.
- **macos-fan-curve**: drop `CODE_SIGN_IDENTITY` / `DEVELOPMENT_TEAM` from
  `XCODE_BUILD_SETTINGS` / `HELPER_BUILD_SETTINGS`; keep the vars defined. PR path
  (`-`) stays ad-hoc; release path (Developer ID sha1 + team) stays Manual.
- **stickies-improved**: set `DEVELOPMENT_TEAM` / `CODE_SIGN_IDENTITY` so swift-mk
  drives signing instead of project-embedded settings.

### 4. Debug == Release parity (in scope)

After the override lands in iphone-cell-tunnel, remove `ENABLE_DEBUG_DYLIB = NO`,
build Debug, install, confirm the agent spawns. Predicted: it spawns because the
`debug.dylib` is now team-signed and library validation passes, confirming the
workaround was a signing artifact. Fallback: if it still fails `EX_CONFIG`,
swift-mk owns `ENABLE_DEBUG_DYLIB = NO` as a hardened-runtime-app setting instead
of leaving it hand-rolled, so Debug and Release behave identically either way.

## Testing / validation

- swift-mk unit tests for `SigningBuildConfig` mirroring `DeadcodeBuildConfigTests`:
  the inference table, written contents, env output, and write-failure-degrades-safely.
- Risk check first: build one iphone-cell-tunnel target with the override but
  before removing any consumer plumbing, and confirm `codesign -dvvv` reports
  `TeamIdentifier=H3BMXM4W7H` (not "Sign to Run Locally"). Only then remove
  consumer plumbing.
- Per-consumer acceptance in a worktree branch consuming this swift-mk via
  `SWIFT_MK_DEV_DIR`: each target shows the expected `TeamIdentifier` (or ad-hoc
  for `-`); iphone Debug agent spawns; macos-fan-curve and stickies releases
  notarize unchanged. CI paths (PR ad-hoc, release Developer ID) validated against
  the workflow definitions.

## Known limitation (stated, not hidden)

This design drives signing but does not add a verification gate, so a consumer
command-line setting that beats the override could still drift. The dead-code
evidence says the xcconfig wins in this toolchain, so within these three consumers
it is a real guarantee. A `verify-signing` lint gate would close the gap
permanently and is a candidate follow-up.
