# swift-mk owns the build, sign, package, and CI path for every consumer

## Why

Each Swift consumer hand-rolls its own build command. There are five different shapes across five repos. The one that diverged most (stickies) broke.

Confirmed root cause (stickies, branch `crdt-note-text`), established by direct inspection, not assertion:
- `tuist generate` produces two separate Xcode projects: the app project `StickiesImproved.xcodeproj`, and the external dependency project `Tuist/.build/tuist-derived/Projects/Automerge/Automerge.xcodeproj`.
- The `.xcworkspace` is the only thing that joins them. Its `contents.xcworkspacedata` has a `Dependencies` group referencing the Automerge project; the app `.xcodeproj` does not reference it.
- `tuist xcodebuild test/build` forwards `xcodebuild -scheme StickiesImproved` with NO `-workspace` and NO `-project` (proven by the v1 failure log, which prints the forwarded command). xcodebuild then auto-discovers and builds the bare app project in the working directory, which has no Automerge target, so `import Automerge` fails: `unable to resolve module dependency: 'Automerge'`.
- `xcodebuild -workspace ... build` and native `tuist build` both load the workspace, so the Automerge sibling project builds first and the module resolves.

Proven by running, same code:

| Command | Forwarded invocation | Result |
|---|---|---|
| `make app` / `make test` | `xcodebuild -scheme StickiesImproved` (no -workspace) | fails, Automerge |
| `tuist build` (native) | tuist loads its own workspace | passes |
| `xcodebuild -workspace ... build` | explicit workspace | passes |

So `-workspace` is load-bearing because the external SPM dependency is a sibling project joined only at the workspace level. The fix is one rule: always pass the workspace (Tuist) or the project (xcodegen) explicitly, never let xcodebuild auto-discover. swift-mk owns that, not each consumer.

Goal: every consumer routes all build, test, sign, package, and CI through swift-mk. A consumer declares app name, scheme, config, and generator type, and nothing else.

## Current shared layer

- `swift.mk`: lint, format, deadcode, swiftcheck, baselines, signing prelude, fetch manifest. Used by all.
- `swift-build.mk`: `build`/`deploy` run generate then `SWIFT_BUILD_CMD`. The build command is a consumer hook. This is the gap.
- `swift-app.mk`: app-bundle (inside-out Sparkle signing), dmg, appcast, coverage build. Already shared and good.
- CI: three composite actions (`setup-build-env`, `import-signing-cert`, `notarize-staple`). The `_ci.yml`/`_release.yml` build swift-makefile itself, not a consumer app. So each consumer hand-writes its workflow YAML.

## Inspected per-consumer reality

Each consumer was inspected directly (generator, build artifact, generated-file policy, dependency wiring, actual invocation), not generalized from an inventory pass.

| Consumer | Generator | Build artifact | Generated files | Current invocation | Works? |
|---|---|---|---|---|---|
| stickies-improved | Tuist | `.xcworkspace` (app proj + Automerge sibling proj) | committed (tracked; drift shows as `M`) | `tuist xcodebuild build/test`, no `-workspace` | no |
| macos-fan-curve | Tuist | `FanCurveApp.xcworkspace` | gitignored | `xcodebuild -workspace ... build/test` | yes |
| iphone-cell-tunnel | Tuist | `CellTunnel.xcworkspace` | gitignored | `xcodebuild -workspace ...` per scheme (dev tool) | yes |
| macos-smc-fan | xcodegen | `SMCFanApp.xcodeproj` (no workspace) | gitignored | `xcodebuild -project ... -scheme SMCFanHelper`; `swift build` in its own CI | yes |
| lmd | Tuist + SPM | `LMD.xcworkspace` + SPM | gitignored | `swift build` (products) + `xcodebuild` (Metal) | yes |

Three facts that change the design and only direct inspection surfaced:

1. The canonical invocation is what 4 of 5 already do. fan-curve and iphone-cell-tunnel pass `-workspace`; macos-smc-fan passes `-project` (xcodegen makes a project, not a workspace). stickies alone uses bare `tuist xcodebuild`. The fix standardizes on the proven-working invocation; it is not a new compromise abstraction layered over five different builds.
2. stickies commits its generated `.xcodeproj`/`.xcworkspace`; every other consumer gitignores them. Its migration must untrack and gitignore them, or the canonical regenerate step fights committed drift.
3. lmd and macos-smc-fan have a plain `swift build` SPM axis that is not a tuist/xcodebuild call. The chokepoint coexists with `swift build`; the ban covers tuist, xcodegen, and xcodebuild only.
4. Only 3 of 5 include `swift-build.mk` today: stickies, macos-fan-curve, iphone-cell-tunnel. macos-smc-fan (main) is a standalone Makefile (`xcodegen generate` + raw `xcodebuild`, no `SWIFT_MK_MODULES`, no `bootstrap.mk`), and lmd is thin aliases over its own `lmd-dev.swift` with no swift-mk build modules. Routing those two through the chokepoint also means making them swift-mk consumers, which is a larger lift than swapping a command. The swift-mk adoption an earlier inventory attributed to macos-smc-fan lives only on the other session's `build-signing-sot` branch, not on main.

Detailed per-consumer evidence with file:line and captured run logs is in `2026-06-06-per-consumer-evidence.md`.

5. DEMONSTRATION FINDING (fan-curve, captured): native `tuist build` resolves external SPM but writes products to Tuist's own DerivedData, not the consumer's `-derivedDataPath`. A consumer that packages its product (swift-app.mk reads `build/Build/Products/...`) then cannot find the app. So the chokepoint BUILD form is `tuist generate` then `xcodebuild -workspace <ws> -scheme <s> -derivedDataPath <dd> [settings] build` (explicit workspace resolves SPM; `-derivedDataPath` and settings serve packaging). The chokepoint TEST form stays native `tuist test --no-selective-testing` (resolves SPM, runs the full suite; no packaging path needed). Verified: stickies builds and tests green through this form; fan-curve build finding came from a captured rc=1 run that failed only on the skipped helper prereq and the DerivedData location, not on SPM.

## Design

### 1. The Toolchain chokepoint in SwiftMkCore

Add `Toolchain` to SwiftMkCore. It is the one and only place in the entire fleet allowed to spawn `tuist`, `xcodegen`, or `xcodebuild`. One Swift implementation, used by make consumers (through a CLI) and by Swift dev tools (through a typed import).

The ban is total. Every native call moves onto a `Toolchain` method:

| Native call today | Becomes |
|---|---|
| `tuist install` | `Toolchain.installDependencies()` |
| `tuist generate` / `xcodegen generate` | `Toolchain.generate(_ generator:)` |
| `xcodebuild -workspace/-project ... build` | `Toolchain.build(...)` |
| `xcodebuild ... test` | `Toolchain.test(...)` |
| `xcodebuild ... build-for-testing` | `Toolchain.buildForTesting(...)` |
| `xcodebuild ... analyze` | `Toolchain.analyze(...)` |
| `xcodebuild -version` | `Toolchain.version()` |
| `xcodebuild -downloadComponent` | `Toolchain.downloadComponent(_:)` |
| `xcodebuild -showBuildSettings` | `Toolchain.showBuildSettings(...)` |

`build`/`test`/`buildForTesting`/`analyze` take: generator (tuist or xcodegen), workspace or project path, scheme, configuration, destination, derivedDataPath, passthrough build settings. They always pass `-workspace <name>.xcworkspace` or `-project <name>.xcodeproj` explicitly. That is the root-cause fix for the Automerge break.

`Toolchain` applies the signing override before any build (composes with the `build-signing-sot` branch's `SigningBuildConfig.applyEnvironmentOverride`), so signing flows on every path. `showBuildSettings` is what the signing verify reads, so the verify becomes a `Toolchain` consumer too.

Built on the existing `Shell` helper. Covered by SwiftMkCore unit tests (argument shape per generator and action, workspace-not-project assertion, signing applied).

Expose one CLI namespace in SwiftMkCLI: `swift-mk toolchain <op>` (`toolchain build`, `toolchain test`, `toolchain generate`, `toolchain install`, ...). Add the new source and test files to `SWIFT_MK_SCRIPT_FILES` in `swift.mk` (the fetch manifest), or consumer CIs break.

### 2. Make integration: consumers declare, not command

In `swift-build.mk`, swift-mk sets the commands from declared `SWIFT_XCODE_*` inputs. They are no longer consumer hooks:

```
SWIFT_GENERATE_CMD = $(SWIFT_MK_BIN) toolchain generate --generator $(SWIFT_XCODE_GENERATOR)
SWIFT_BUILD_CMD    = $(SWIFT_MK_BIN) toolchain build --workspace $(SWIFT_XCODE_WORKSPACE) --scheme $(SWIFT_XCODE_SCHEME) --configuration $(CONFIGURATION)
SWIFT_TEST_CMD     = $(SWIFT_MK_BIN) toolchain test  --workspace $(SWIFT_XCODE_WORKSPACE) --scheme $(SWIFT_XCODE_SCHEME) --configuration Debug
```

A consumer Makefile declares only: generator type, workspace-or-project name, scheme, config. It writes no build command, no generate command, no install command. `swift-app.mk` coverage build routes through `toolchain build-for-testing` the same way.

### 3. Swift dev tools call Toolchain through a typed import

Consumer dev tools `import SwiftMkCore` and call `Toolchain.*` directly. No subprocess, fully typed.

- iphone-cell-tunnel: `CellTunnelDev` keeps its multi-scheme dispatch (it builds several schemes and destinations), but each call is `Toolchain.build(...)` instead of its own `buildScheme`. Its relay, logging, install, and clean-reinstall logic stays. It already depends on SwiftMkCore.
- lmd: `lmd-dev.swift` routes every `tuist`/`xcodebuild` call through `Toolchain`, including the Metal `xcodebuild` and the `-downloadComponent MetalToolchain` preflight. It gains a SwiftMkCore dependency. Its plain `swift build` of SPM products is not a tuist/xcodebuild call, so it stays as is; its shader staging and model serving stay bespoke.

### 4. Block all native build tooling (the gate, no opt-out)

The contract is absolute: there is no opt-out of anything. No marker comment, no opt-out variable, no per-call escape, no analyze exception, no read-only exception. The only place in the fleet that may name `tuist`, `xcodegen`, or `xcodebuild` is swift-mk's own `Toolchain` source.

Two halves, because swiftcheck only sees Swift.

Half A, swiftcheck-extra rule `unrouted_build_tooling`: flag any non-test Swift file that names `xcodebuild`, `xcodegen`, or `tuist` at a call site or in a process-argument string. No opt-out marker. The single non-violation site is swift-mk's own `Toolchain` source, which swift-mk excludes through its own lint config (`SWIFTCHECK_EXTRA_EXCLUDE_PATHS` in swift-mk's Makefile); that is swift-mk configuring its own lint, not a consumer-reachable escape, and a consumer repo has no such file. So any consumer Swift tool that shells these tools always fails. Default-enabled, so it runs in every consumer's `make lint`. The `build-signing-sot` branch plans an `unrouted_xcodebuild` rule for the signing case; merge both into this one rule meaning "a Swift tool runs the build toolchain without going through swift-mk." The merged rule has no opt-out.

Half B, make audit `build-tooling-audit`: fail if any swift-mk-consumed command variable (`SWIFT_BUILD_CMD`, `SWIFT_TEST_CMD`, `SWIFT_GENERATE_CMD`, `SWIFT_DEADCODE_BUILD_CMD`, the coverage build command) contains a raw `xcodebuild`, `xcodegen`, `tuist build`, or `tuist xcodebuild`/`tuist generate` token. No opt-out variable. The only sanctioned forms are `$(SWIFT_MK_BIN) toolchain ...`, or a Swift dev-tool entrypoint that contains no such token (and which Half A then forces through `Toolchain`). stickies' old `tuist xcodebuild build` fails this audit. iphone-cell-tunnel's `$(CELL_TUNNEL_DEV) build` passes because the string holds no toolchain token, and Half A guarantees `CellTunnelDev` routes through `Toolchain`.

Together the two halves leave exactly one place in the whole fleet where the build toolchain is named: swift-mk's `Toolchain` source. Nothing else can invoke it, and nothing can opt out.

### 5. Consumer-facing reusable CI

Add real `workflow_call` workflows to swift-makefile that build a consumer app, not swift-makefile itself: an app-CI workflow (setup, lint, build, test) and an app-release workflow (build, sign via import-signing-cert, notarize via notarize-staple, dmg, appcast). Each consumer replaces its hand-written jobs with one `uses:` line plus inputs (app name, scheme, whether it ships Sparkle, etc.).

## What each repo collapses to

- stickies-improved: delete the `tuist xcodebuild` lines, declare `SWIFT_XCODE_*`. Automerge break disappears. CI becomes one `uses:`.
- macos-fan-curve: `project-build`, `test-local`, `generate-project`, and `helper-artifacts`' inner `xcodebuild` all route through `Toolchain`. It is the reference, so mostly deletion. Keep icons, audits, the sibling-helper orchestration (just its xcodebuild call moves to `Toolchain`).
- macos-smc-fan: `swift.yml` raw `swift build` becomes the shared workflow; gains lint and the xcodegen `-project` build path through `Toolchain.generate(.xcodegen)` + `Toolchain.build`.
- iphone-cell-tunnel: `CellTunnelDev.buildScheme` becomes `Toolchain.build`; the `tuist generate` and `tuist install` in `BuildActions` become `Toolchain`. Gains CI (none today). Keep relay, logging, install tooling.
- lmd: every `tuist`/`xcodebuild` call in `lmd-dev.swift` (build, test, Metal xcodebuild, preflight downloadComponent, toolchain version) routes through `Toolchain`. Plain `swift build` of SPM products, shader staging, and serving stay.

## Phasing

1. SwiftMkCore `Toolchain` (generate/install/build/test/buildForTesting/analyze/version/downloadComponent/showBuildSettings) + `swift-mk toolchain` CLI + tests + manifest entries. Prove on stickies (fixes Automerge for build, test, coverage).
2. `swift-build.mk` sets the commands from `SWIFT_XCODE_*`. Migrate stickies, fan-curve, macos-smc-fan Makefiles to declarations only.
3. iphone-cell-tunnel `CellTunnelDev` and lmd `lmd-dev.swift` call `Toolchain` through typed `import SwiftMkCore` for every tuist/xcodebuild call.
4. swiftcheck-extra `unrouted_build_tooling` rule + `build-tooling-audit` make guard, no opt-out. Scan consumers first, route every native call, then enable.
5. Consumer-facing reusable CI workflows. Migrate each consumer's CI. Add CI to iphone-cell-tunnel.
6. Fold lmd sign / notarize / dist / release into shared targets (later, larger).

## Verification

- swift-mk: new XcodeBuild and CLI unit tests; `make lint` stays green (new rule does not flag swift-mk itself).
- stickies: `make app`, `make test`, `make build` all pass with declarations only. Negative test: a hand-rolled `tuist xcodebuild` line trips `build-tooling-audit`.
- Each migrated repo: build, test, sign, package pass through swift-mk; `codesign -dvvv` shows the expected TeamIdentifier.
- Gate: a temp Swift file that shells xcodebuild fails `make lint`; routing it through the primitive clears it.

## Caveats and overlaps

- The `build-signing-sot` branch (other session) edits `swift-build.mk` and adds an `unrouted_xcodebuild` rule and `verify-signing`. This plan edits the same two files. They compose but must be reconciled at merge. Best path: one `unrouted_xcodebuild` rule covering both signing-not-applied and build-not-routed, and one shared `XcodeBuild` that calls `applyEnvironmentOverride` so signing and build routing land together.
- The two repos share one git worktree per session, so this branch (`canonical-tuist-build`) stays isolated from `build-signing-sot`. No cross-branch edits.
- A runtime override race (a command-line `KEY=value` beating the override) remains the documented signing follow-up from the other branch, not in scope here.
