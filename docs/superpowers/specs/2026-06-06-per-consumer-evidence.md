# Per-consumer build reality (captured evidence)

Each consumer inspected individually from its real files. Quotes are `file:line` from the actual repo. Git tracking confirmed with `git ls-files --error-unmatch` and `.gitignore`. Captured 2026-06-06.

## Root cause (proven, stickies)

- Tuist generates two separate projects: app `StickiesImproved.xcodeproj` and dependency `Tuist/.build/tuist-derived/Projects/Automerge/Automerge.xcodeproj`.
- They are joined only by the workspace. `StickiesImproved.xcworkspace/contents.xcworkspacedata`:
  ```
  <FileRef location="group:StickiesImproved.xcodeproj">
  <Group location="container:" name="Dependencies">
    <FileRef location="group:Tuist/.build/tuist-derived/Projects/Automerge/Automerge.xcodeproj">
  ```
- `tuist xcodebuild test` forwards a bare command with NO `-workspace`. From the v1 failure log (`/tmp/sticky_repro.v1.log:212`):
  ```
  The command `xcodebuild test -scheme StickiesImproved -configuration Debug -derivedDataPath build-v1 ...` exited with error code 65
  ```
  and the error (`v1.log:217`): `NoteCRDT.swift:9:8: error: unable to resolve module dependency: 'Automerge'`.
- Captured runs (same code, branch `crdt-note-text`):
  - `make app` gives rc=2 with the Automerge error (`/tmp/sticky_app_repro.makeapp.log:11-14`).
  - `make test` gives rc=1 with the Automerge error (`/tmp/sticky_repro.output`, v1 rc=1).
  - native `tuist build` gives rc=0 (`/tmp/sticky_app_repro.output`, B rc=0).
  - `xcodebuild -workspace StickiesImproved.xcworkspace -scheme StickiesImproved ... build` gives rc=0 (`/tmp/sticky_app_repro.output`, C rc=0).
  - `xcodebuild -workspace ... test` gives rc=0 (`/tmp/sticky_repro.output`, v2 rc=0).

Conclusion: `-workspace` is load-bearing because the external SPM dependency is a sibling project joined only at the workspace level. It is not about a hand-written project sitting on disk.

## stickies-improved

- Generator: Tuist. Evidence: `Tuist/Package.swift`, `Project.swift`.
- Artifact: `StickiesImproved.xcworkspace` (app proj + Automerge sibling proj).
- Tracked vs ignored: `StickiesImproved.xcodeproj` and `StickiesImproved.xcworkspace` are **TRACKED** (`git ls-files --error-unmatch` returns TRACKED). `.gitignore` only has `Derived/`, `Tuist/.build/`. DEVIATION: commits generated projects; they drift (showed as `M` in `git status`).
- swift-mk consumer: yes. `SWIFT_MK_MODULES := swift-build.mk swift-app.mk` (`Makefile:16`).
- Commands today:
  - generate: `$(TUIST) generate --no-open` (`Makefile:28`)
  - build: `$(TUIST) xcodebuild build -scheme $(SWIFT_APP_NAME) ...` with NO `-workspace` (`Makefile:29`)
  - test: `$(TUIST) xcodebuild test -scheme $(SWIFT_APP_NAME) ...` with NO `-workspace` (`Makefile:30`)
  - coverage: `$(TUIST) xcodebuild build-for-testing -scheme ...` with NO `-workspace` (`Makefile:34`)
- Migration: switch the three commands to the workspace form; untrack and gitignore the generated `.xcodeproj`/`.xcworkspace`.

## macos-fan-curve

- Generator: Tuist. Evidence: `Project.swift`, `Workspace.swift`, `Tuist/Package.swift`.
- Artifact: `FanCurveApp.xcworkspace`. External SPM: Sparkle. Also builds a sibling helper from `../macos-smc-fan`.
- Tracked vs ignored: gitignored. `.gitignore:9 *.xcodeproj`, `:10 *.xcworkspace`.
- swift-mk consumer: yes. `SWIFT_MK_MODULES := swift-build.mk` (`Makefile:56`).
- Commands today:
  - build: `$(MAKE) SWIFT_MK_SKIP_FETCH=1 app-local` (`Makefile:61`), whose `project-build` runs `xcodebuild -workspace FanCurveApp.xcworkspace -scheme FanCurve ...` (`Makefile:120-128`)
  - test: `$(MAKE) ... test-local` (`Makefile:67`), which runs `xcodebuild -workspace FanCurveApp.xcworkspace -scheme FanCurve ... test` (`Makefile:201-208`)
  - coverage: `rm -rf build && $(MAKE) ... app-local` (`Makefile:66`)
- Already uses the canonical `-workspace` form. This is the reference. Migration: replace the raw xcodebuild recipes with the chokepoint; keep helper-artifacts, icons, audits.

## iphone-cell-tunnel

- Generator: Tuist. Evidence: `Project.swift`, `Tuist/Package.swift`. External SPM: WireGuardKit.
- Artifact: `CellTunnel.xcworkspace`.
- Tracked vs ignored: gitignored. `.gitignore:13 *.xcodeproj/`, `:14 *.xcworkspace/`.
- swift-mk consumer: yes. `SWIFT_MK_MODULES := swift-build.mk xcconfig.mk` (`Makefile:15`).
- Commands today (the Makefile delegates to the dev tool):
  - build: `$(CELL_TUNNEL_DEV) build $(TARGET) $(CONFIG)` (`Makefile:37`), with `CELL_TUNNEL_DEV := swift Tools/cell-tunnel-dev.swift` (`Makefile:11`)
  - test: `$(CELL_TUNNEL_DEV) test` (`Makefile:38`)
  - coverage: builds mac, mac-catalyst, iphone-simulator through the dev tool (`Makefile:49`)
  - the dev tool runs `xcodebuild -workspace CellTunnel.xcworkspace -scheme <scheme>` per scheme (`Tools/CellTunnelDev/BuildActions.swift:119-148`)
- DOMAIN-SPECIFIC (KEEP, untouched): relay control, log streaming, install/activate, `LoggingAudit`, `CellTunnelCtl`. Migration: `buildScheme` calls the chokepoint; the rest stays.

## macos-smc-fan (main branch checkout)

- Generator: xcodegen. Evidence: `project.yml`; `generate-project: xcodegen generate` (`Makefile:13-14`).
- Artifact: `SMCFanApp.xcodeproj`, with NO workspace (`Makefile:17,24`). It also has an SPM `Package.swift` for tests.
- Tracked vs ignored: gitignored. `.gitignore:7 *.xcodeproj`.
- swift-mk consumer: **NO**. No `SWIFT_MK_MODULES` and no `include bootstrap.mk` in the main Makefile. The swift-mk adoption exists only on the other session's `build-signing-sot` branch, unmerged.
- Commands today:
  - generate: `xcodegen generate` (`Makefile:14`)
  - build: `xcodebuild -project SMCFanApp.xcodeproj -scheme SMCFanHelper ... build` then `-scheme smcfan ... build` (`Makefile:17-30`). It builds two schemes.
  - test: `swift test` (`Makefile:74`). This is SPM.
  - integration test: `swift build --build-tests; sudo xctest ...` (`Makefile:79-81`)
- Migration: generate through the chokepoint `generate(.xcodegen)`; build both schemes through the chokepoint `-project`. The SPM `swift test` is not a tuist/xcodebuild call and stays.

## lmd

- Generator: Tuist + SPM dual. Evidence: `Project.swift` + root `Package.swift` + `Tuist/`.
- Artifact: `LMD.xcworkspace` + SPM. External SPM: MLX and others. It compiles Metal shaders via xcodebuild against the Tuist-generated mlx project.
- Tracked vs ignored: gitignored. `.gitignore:8-12 LMD.xcodeproj/, LMD.xcworkspace/, lmd.xcodeproj/, lmd.xcworkspace/, Tuist/.build/`.
- swift-mk consumer: **NO** build modules. The Makefile is thin aliases over `swift Tools/lmd-dev.swift` (`Makefile:11,28-35`). Verified by direct read of `lmd-dev.swift` this session.
- Commands today (all verified by direct read):
  - build: `swift build -c <config>` for SPM products (`lmd-dev.swift:498-514`), then `xcodebuild` of scheme `mlx-swift_Cmlx` against `Tuist/.build/tuist-derived/Projects/mlx-swift/mlx-swift.xcodeproj` with `-project` (`lmd-dev.swift:522-534`), then stage. lmd does NOT build an app via `xcodebuild -workspace -scheme`; its binaries come from `swift build`.
  - generate/install: `tuist install` + `tuist generate --no-open --cache-profile none` (`lmd-dev.swift:1238-1241`)
  - test: native `tuist test LMDTests --configuration Debug --platform macos --no-selective-testing --inspect-mode off` (`lmd-dev.swift:621-640`). Not xcodebuild.
  - toolchain/preflight: `xcodebuild -version` (`:441`), `tuist version` (`:442,570`), `xcodebuild -downloadComponent MetalToolchain` (`:546`)
  - lint: hand-rolled `swift-format lint` + `swiftlint --quiet`, errors swallowed (`lmd-dev.swift:1216-1227`). Does NOT use swift-mk lint gates.
  - sign: identity resolved through `swift-mk signing-identity` (`lmd-dev.swift:969-1024`), then hand-rolled `codesign` in `signTargets`.
  - notarize: hand-rolled `xcrun notarytool submit` (`lmd-dev.swift:1060-1113`)
  - ci cert import: hand-rolled `security` keychain dance (`lmd-dev.swift:1115-1168`)
  - release: `releaseTag`/`pushTag`/`githubRelease`/`cleanupKeychain` (`lmd-dev.swift:1171-1214`)
- DOMAIN-SPECIFIC (KEEP): Metal toolchain/shaders, model serving, smoke/video, metrics/log audits, LaunchAgent serving.
- Migration to a full swift-mk consumer is the largest of the five: generate/install, the Metal `-project` xcodebuild, `downloadComponent`, `version`, lint, sign, notarize, and release all move to swift-mk shared layers. `swift build` of SPM products stays. `tuist test` stays as a test mode the chokepoint must support.

## Cross-cutting findings (these shape the design)

1. There is no single build shape. Four consumers build an app through `xcodebuild -workspace|-project -scheme` (stickies, fan-curve, iphone-cell-tunnel, and macos-smc-fan's helper). lmd does not: its binaries come from `swift build`, and its only xcodebuild call is a `-project` build of the Metal bundle. So the chokepoint must model several operations, not one canonical command.

2. The test command is not uniform, but native Tuist unifies the Tuist consumers. VERIFIED: `tuist test StickiesImproved --no-selective-testing` resolves Automerge and runs the full suite, rc=0 (`/tmp/sticky_tuist_test_probe.log`: line 7 "Generating project Automerge", lines 36-39 `StickiesCRDTTests` compiling against it, line 8 all four test targets, line 182 "Test Succeeded"). The earlier zero-test run was Tuist selective testing skipping everything, not a real pass; bare `tuist test` lacked `--no-selective-testing`. lmd already uses native `tuist test --no-selective-testing`. macos-smc-fan tests with `swift test` (SPM). So Tuist consumers can standardize on native `tuist test --no-selective-testing`, which resolves external SPM because Tuist drives its own workspace; xcodegen and SPM consumers keep `xcodebuild -project` / `swift test`.

Branch note discovered during this probe: `crdt-note-text` was fast-forward merged into `main` (stickies reflog HEAD@{0} "merge crdt-note-text: Fast-forward"). `main` now contains StickiesCRDT/Automerge, and the working tree has further uncommitted WIP. The probe therefore ran against an Automerge-containing tree, which is why it is valid.

3. Lint is not uniform. Only the three swift-build.mk consumers (stickies, fan-curve, iphone-cell-tunnel) use swift-mk lint gates. lmd hand-rolls swift-format + swiftlint with errors swallowed. macos-smc-fan (main) hand-rolls a grep-based log-audit and `swift-format`. Making all five full consumers means moving lint onto swift-mk too, not only build.

4. Generators: four Tuist (stickies, fan-curve, iphone-cell-tunnel, lmd), one xcodegen (macos-smc-fan). lmd is additionally SPM-primary.

## Status of the canonical-path proof per consumer

Verified to resolve external SPM (Automerge) on stickies, by captured run:
- `xcodebuild -workspace ... build` rc=0 (`/tmp/sticky_app_repro.output`, C).
- `xcodebuild -workspace ... test` rc=0 (`/tmp/sticky_repro.output`, v2).
- native `tuist build` rc=0 (`/tmp/sticky_app_repro.output`, B).
- native `tuist test --no-selective-testing` rc=0, full suite (`/tmp/sticky_tuist_test_probe.log`).

DEMONSTRATED through the swift-mk `Toolchain` chokepoint (`.make/swift-mk toolchain ...`), captured runs:
- stickies: `toolchain generate` rc=0, `toolchain build --workspace StickiesImproved.xcworkspace --derived-data-path build` rc=0 (`/tmp/demo_revised.sticky.build.log:2924` `** BUILD SUCCEEDED **`, no Automerge error), `toolchain test` rc=0 (`/tmp/demo_stickies_chokepoint.test.log`: NoteCRDTTests passed, Test Succeeded). Task output `bkk3jlwg5.output`.
- macos-fan-curve: with the swift-mk signing override exporting Developer ID, `toolchain build --workspace FanCurveApp.xcworkspace --derived-data-path build SMC_FAN_HELPER_APP=...` rc=0; every framework signed `Developer ID Application: Alex Goodkind (H3BMXM4W7H)` (`/tmp/demo_revised.fan.build.log:715,1001,...`); final app `codesign -dvvv` shows `Authority=Developer ID Application: ... (H3BMXM4W7H)`, `TeamIdentifier=H3BMXM4W7H`, not ad-hoc (`/tmp/demo_revised.fan.codesign.log`).
- ToolchainTests unit suite: 6/6 passed, rc=0 (`/tmp/toolchain_unit.log`).

GATE (Gate 3, swiftcheck half) DEMONSTRATED:
- New swiftcheck-extra rule `unrouted_build_tooling`, on by default. Flags a Swift literal that names `tuist`/`xcodegen`/`xcodebuild` in an invocation context (a function-call argument or an array passed to a call), exact-match so prose is not flagged. No opt-out.
- Negative test (`/tmp/gatefix/`): `Offender.swift` (shells xcodebuild + tuist) rc=1 with 2 violations; `Clean.swift` rc=0.
- swift-mk's own gate green with the rule on: `make swiftcheck-extra` rc=0, 0 findings in both the root and swiftcheck packages (`/tmp/swiftmk_gate5.log`). The only flagged file is the chokepoint `Sources/SwiftMkCore/Toolchain.swift`, excluded via swift-mk's own `SWIFTCHECK_EXTRA_EXCLUDE_PATHS` (swift-mk configuring its own analyzer source, not a consumer-reachable opt-out). swift-mk's own `xcodebuild -list` in DeadcodeScan was dogfood-routed through `Toolchain.listSchemes`.
- ToolchainTests unit suite 6/6 rc=0 (`/tmp/toolchain_unit.log`).

CHOKEPOINT RUNS against the other three real layouts (`bh7k9hssb.output`, `/tmp/demo_three.*`):
- iphone-cell-tunnel: `toolchain generate` rc=0, `toolchain build --scheme CellTunnelAgent --workspace CellTunnel.xcworkspace` with the Developer ID override exported → rc=0, `** BUILD SUCCEEDED **`, no SPM error. This is the NetworkExtension agent, the exact target that fails ad-hoc in `clean-reinstall`; through the chokepoint with the signing override it builds.
- lmd: `toolchain install` rc=0, `toolchain generate` rc=0, `toolchain build --generator xcodegen --project Tuist/.build/tuist-derived/Projects/mlx-swift/mlx-swift.xcodeproj --scheme mlx-swift_Cmlx` (the Metal bundle) rc=0, success marker. lmd's `swift build` of products stays outside the ban.
- macos-smc-fan: first run rc=65, but NOT a chokepoint defect: smc-fan on main is not yet a swift-mk signing consumer, so its own `project.yml` (Manual) + `local.xcconfig` (`Developer ID Application` + Automatic) conflict ("conflicting provisioning settings", `/tmp/demo_three.smc.build.log:82`). The chokepoint drove the xcodegen `-project` build correctly (generate rc=0, xcodebuild invoked, no SPM error). Re-run with the swift-mk ad-hoc signing override resolves the conflict: `toolchain generate` rc=0, `toolchain build --generator xcodegen --project SMCFanApp.xcodeproj --scheme SMCFanHelper` rc=0, `** BUILD SUCCEEDED **`, no conflict (`/tmp/demo_smc2.build.log`, `b8p9lbbf8.output`). DEVIATION named and resolved: smc-fan must adopt the swift-mk signing override (become a signing consumer) for a clean build; with it, the chokepoint builds it green.

ALL FIVE consumers now have a recorded chokepoint run against their real layout with full command and exit status: stickies (build+test), macos-fan-curve (build, Developer ID verified), iphone-cell-tunnel (NE agent build, Developer ID override), lmd (Metal -project build), macos-smc-fan (xcodegen -project build, ad-hoc override).

GATE 4 (fix at swift-mk layer, build + test + coverage) DEMONSTRATED for stickies:
- coverage build through the chokepoint: `toolchain build-for-testing --workspace StickiesImproved.xcworkspace --derived-data-path build COMPILER_INDEX_STORE_ENABLE=YES` rc=0, `** TEST BUILD SUCCEEDED **` (`/tmp/demo_sticky_coverage.coverage.log:3797`), `NoteCRDT.swift`/`NoteCRDTTests.swift` compiled (Automerge resolved), no resolution error, `build/Index.noindex` produced (`buw2gpkzp.output`).
- So the Automerge fix holds for build, test, and the coverage build, all via swift-mk's `Toolchain`. No consumer carries a private patch.

GATE 3 ban (no opt-out) DEMONSTRATED by negative test in a real consumer worktree (a throwaway `git worktree` of stickies, created and removed cleanly):
- Makefile half: an offending `xcodebuild -workspace ...` recipe line makes `swift-mk build-tooling-audit` exit rc=1 with a path:line finding; the sanctioned `$(SWIFT_MK_BIN) toolchain build ...` line exits rc=0.
- Swift half: a `Shell.run("tuist", ...)` / `Shell.run("xcodebuild", ...)` dev file makes `swiftcheck-extra -unrouted_build_tooling` exit rc=1 (2 violations); a clean file exits rc=0.
- Both halves have no marker, no opt-out variable, no exception; the only non-violating site is swift-mk's own `Toolchain`. 14 SwiftMkCore unit tests (Toolchain + BuildToolingAudit) pass (`/tmp/unit3.log`).

MAKE INTEGRATION + DECLARATIONS-ONLY DEMONSTRATED (stickies, throwaway worktree `/tmp/sticky-migrate-wt`):
- `swift-build.mk` derives generate/build/test/coverage from `SWIFT_XCODE_*` (generator, workspace-or-project, scheme, config, settings) through `$(SWIFT_MK_BIN) toolchain`. swift.mk lines 237-261.
- stickies Makefile reduced to `SWIFT_XCODE_*` declarations, with its own `TUIST :=` and `install-dependencies: $(TUIST) install` removed. Names no tuist/xcodegen/xcodebuild.
- `build-tooling-audit Makefile` rc=0; `make generate` rc=0 (deps resolved); `make build` rc=0 `** BUILD SUCCEEDED **` `lint-deadcode: OK`; `make test` rc=0 (`/tmp/migrate_rerun2.*`, `b6p6t5eex.output`).
- Dead-code coverage build is Debug + `ONLY_ACTIVE_ARCH=YES`; single-arch resolves the local `StickiesDomain` module that a universal Release `build-for-testing` raced on.

Still NOT VERIFIED (remaining):
- macos-smc-fan chokepoint run with its real Developer ID signing (the earlier ad-hoc run is retracted; ad-hoc cannot launch its privileged helper).
- `CellTunnelDev` (iphone) and `lmd-dev.swift` (lmd) calling `Toolchain` via typed `import SwiftMkCore`, and the chokepoint applying the signing override itself so a dev-tool build (clean-reinstall) signs without the make prelude.
- The one-trace in-process orchestration phase (deferred after the chokepoint).
