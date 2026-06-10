# swift-makefile

`swift-makefile` provides shared Make targets, shared lint policy, shared baseline policy, a shared SwiftSyntax analyzer, and shared update scripts for Swift repos.

Provided AS IS under the MIT License with no warranty. See [LICENSE](LICENSE).

## Files

- `swift-mk` is a Swift command-line program that carries the shared lint, baseline, gate, and notice logic. It builds from the root SwiftPM package: the `SwiftMkCore` library holds the logic, the `SwiftMkCLI` executable wraps it, and the package produces the `swift-mk` product using `apple/swift-argument-parser`. `scripts/swift-mk-build.sh` builds and caches the binary at `.make/swift-mk`, and `swift.mk` invokes it.
- `Sources/SwiftMkCore/` holds the shared lint, baseline, gate, and notice logic.
- `bootstrap.mk` fetches `swift.mk`, shared configs, shared helper scripts, and shared modules into `.make/`.
- `swift.mk` defines the shared public targets.
- `swift-build.mk` defines shared build, run, generate, clean, deploy, and install targets from consumer-provided commands.
- `swift-release.mk` defines shared release wrapper targets from consumer-provided commands.
- `xcconfig.mk` renders `*.template` files into `Derived/Generated/$(TARGET_NAME)/` for Tuist projects that treat one or more xcconfig files as the source of truth. The consumer Makefile `-include`s its xcconfig files, lists the keys it wants exposed (`XCCONFIG_EXPORTED_VARS`), points at its templates dir (`XCCONFIG_TEMPLATES_DIR`), and lists target names (`XCCONFIG_GENERATOR_TARGETS`). The `xcconfig-generate-config` target renders once per target; `xcconfig-generate-project` chains that into `tuist generate --no-open` so the glob inside `Project.swift` finds the generated files. Templates use `[[KEY]]` substitutions. See `swift-mk render-batch --help` for the underlying renderer.
- `swift-app.mk` defines shared macOS app packaging for an app that ships as a signed `.app` inside a `.dmg` and updates through Sparkle. A consumer loads it with `SWIFT_MK_MODULES := swift-build.mk swift-app.mk`, sets `SWIFT_APP_NAME` plus a few `SWIFT_APP_*` overrides, and gets `app`, `dmg`, `release-assets`, `prepare-sparkle-updates`, `sparkle-appcast`, and `app-coverage-build`. `swift-build.mk` still owns `build`; `swift-app.mk` owns everything after the build. The build line stays the consumer's `SWIFT_BUILD_CMD`. See the header of `swift-app.mk` for the full variable surface.
- `scripts/` holds only the bash bootstrap, fetch, build, and distribution layer that runs before the binary exists: `swift-mk-fetch-one.sh`, `swift-mk-build.sh`, `swift-mk-sync.sh`, `swift-mk-fleet-update.sh`, and `install-hooks.sh`.
- `swiftcheck/` contains the shared SwiftSyntax analyzer package.

## Public targets

Build and lifecycle:

- `make build`
- `make generate`
- `make clean`
- `make run`
- `make deploy`
- `make install`
- `make check`
- `make build-check`
- `make test`
- `make analyze`
- `make audit`

Lint:

- `make lint`
- `make fmt`
- `make lint-tools`
- `make lint-swiftlint`
- `make lint-format`
- `make lint-complexity`
- `make lint-deadcode`
- `make swiftcheck-extra`
- `make lint-files LINT_FILES=...`
- `make lint-diff`

Baselines, one file per gate:

- `make baseline`, `make baseline-prune-fixed`, `make baseline-accept-new`
- `make lint-swiftlint-baseline`, `make lint-swiftlint-baseline-prune-fixed`, `make lint-swiftlint-baseline-accept-new`
- `make lint-complexity-baseline`, `make lint-complexity-baseline-prune-fixed`, `make lint-complexity-baseline-accept-new`
- `make lint-deadcode-baseline`, `make lint-deadcode-baseline-prune-fixed`, `make lint-deadcode-baseline-accept-new`
- `make swiftcheck-extra-baseline`, `make swiftcheck-extra-baseline-prune-fixed`, `make swiftcheck-extra-baseline-accept-new`

Per-rule scoped SwiftLint baselining:

- `make lint-swiftlint-scope RULE=<rule_id>` runs and gates one SwiftLint rule.
- `make lint-swiftlint-baseline-scope RULE=<rule_id>` writes a token-gated scoped baseline and refuses to run unscoped.
- `make lint-swiftlint-baseline-scope-accept-new RULE=<rule_id>` accepts new findings for the scoped rule.

Distribution and fleet:

- `make update-swift-mk`
- `make update-consumers`
- `make update-consumers-dry-run`
- `make smoke-fetch`

## Shared policy

- SwiftLint configuration lives in `.swiftlint.yml`. It enables the `no_magic_numbers` rule.
- swift-format configuration lives in `.swift-format`.
- Periphery configuration lives in `.periphery.yml`.
- `swiftcheck-extra` reports logging, type, lifecycle, cleanup, sleep, task, and fatal-exit violations.

### Dead-code coverage of Xcode targets

The dead-code gate scans the Swift package and, when the repository has an Xcode project, every Xcode target. It reuses the index store from the project's own build, so it passes no scan configuration and no build settings to Periphery. A consumer with an Xcode project wires three things:

- Include `bootstrap.mk` and the `swift-build.mk` module.
- Set `SWIFT_BUILD_CMD` to the command that builds the Xcode targets, and route that build through `-derivedDataPath $(SWIFT_MK_DERIVED_DATA)`. The gate runs this build before every scan so the index reflects the current sources; an incremental build keeps it fast. When `SWIFT_BUILD_CMD` needs a target argument or builds a single platform, set `SWIFT_DEADCODE_BUILD_CMD` to a target-free build that compiles every platform to cover, and the gate uses it instead. Coverage follows what compiled, so build each platform whose `#if` branches you want analyzed.
- Set `SWIFT_GENERATE_CMD` to the command that generates the project when the project is a generated artifact. When `SWIFT_GENERATE_CMD` is unset, the gate runs `xcodegen generate` for a `project.yml` or `tuist generate` for a `Project.swift` or `Workspace.swift`.

The coverage build must produce a compiler index store, so build a configuration with indexing enabled. Debug enables it by default; a Release build usually disables it, so build Debug or pass `COMPILER_INDEX_STORE_ENABLE=YES`. `SWIFT_MK_DERIVED_DATA` is the canonical DerivedData path the build writes to and the gate reads the index store from. It defaults to `$(CURDIR)/.derived-data`; add it to `.gitignore`. Schemes come from `xcodebuild -list -json`, and schemes whose name is a Swift package target are excluded from the Xcode scan because the package scan already covers them. Coverage follows what the build compiled, so building each platform a target supports covers each `#if` branch.

The gate fails with a message naming the cause when a repository declares an Xcode project it cannot scan:

- A `Project.swift`, `Workspace.swift`, or `project.yml` is present but no project was generated.
- An Xcode project is present but `SWIFT_BUILD_CMD` is unset.
- No index store exists under `SWIFT_MK_DERIVED_DATA` after the build.
- No Xcode schemes resolve to scan.

A repository with only a `Package.swift` is scanned as a Swift package and needs none of this.

### Baselines

Each of the four lint gates keeps its own baseline file:

- `.swiftlint-baseline.txt` for the `swiftlint` gate.
- `.swiftlint-complexity-baseline.txt` for the complexity gate.
- `.periphery-baseline.txt` for the dead-code gate.
- `.swiftcheck-extra-baseline.txt` for the `swiftcheck-extra` gate.

The baseline diff gate fails only on findings that are absent from the baseline. Baseline mutation is guarded by `BASELINE_CONFIRM=1` together with `BASELINE_TOKEN` matching the slugified output of `BASELINE_TOKEN_CMD`.

### Per-rule scoped baselining

The multi-rule `swiftlint` gate supports scoping to one rule. Set `RULE=<rule_id>` or `SWIFTLINT_BASELINE_SCOPE_PATTERN=<regex>` to select a single SwiftLint rule by its trailing `(rule_id)` tag. A scoped baseline write preserves every out-of-scope row unchanged. The scoped baseline write target refuses to run when no scope is given.

### Update notices and auto-baseline

`notices.txt` holds append-only records as `id<TAB>directive<TAB>summary`. A directive is either `-` for an announcement or `GATE=swiftlint RULE=<id>` for an auto-baseline scope. `swift-mk notice` runs as an order-only prerequisite of `lint`. For a notice whose directive is not yet applied, it auto-baselines only that rule's existing findings and asks the reader to review and commit the result. Applied notice ids are recorded in the committed `.swift-mk-applied-notices`, one id per line; commit it so a fresh checkout does not re-grandfather later violations. The last printed notice id is recorded in the gitignored `.make/.swift-mk-notice-seen`.

## Build caching

- `SWIFT_MK_XCODE_CACHE` defaults to `auto` and enables local Xcode compilation caching on Xcode 26 or newer.
- `SWIFT_MK_XCODE_CACHE_DIAGNOSTICS=1` enables compilation-cache diagnostic remarks for `xcodebuild` paths.
- `SWIFT_MK_SWIFTPM_CACHE_ARGS` defaults to the supported shared SwiftPM cache flags exposed by the local toolchain.
- `ccache` and `sccache` are not treated as Swift compilation caches in `swift-makefile`.
- Tuist remote cache is opt-in for Tuist consumers. It is not enabled by default here. Projects that want it should configure their Tuist `fullHandle`, enable Xcode caching in `Tuist.swift`, and run `tuist setup cache`.

## Bootstrap

`bootstrap.sh` writes a small SwiftPM consumer `Makefile` and `bootstrap.mk`.
Consumers that want shared build-style targets must load `swift-build.mk`.
A macOS app consumer that ships a signed `.app` in a `.dmg` with Sparkle updates
loads `swift-build.mk swift-app.mk`, sets `SWIFT_APP_*` config, and does not
hand-roll its own `app`, `dmg`, or sparkle recipes.

## CI for consumers

All generic CI lives here as reusable workflows; a consumer's workflow files are thin callers that own only the triggers, a few inputs, and `secrets: inherit`.

CI (`.github/workflows/ci.yml` in the consumer, name it `CI`):

```yaml
name: CI
on:
  push: { branches: [main] }
  pull_request:
jobs:
  ci:
    uses: agoodkind/swift-makefile/.github/workflows/_ci.yml@main
    with:
      targets: '["lint","build","test"]'
    secrets: inherit
```

Key `_ci.yml` inputs: `targets` (JSON array of make targets, one matrix job each), `setup-target` (make target run before each), `make-args`, `brew-packages`, `runner`, `import-signing-cert` + `signing-identity-name` + `apple-team-id` (real Developer ID builds), `extra-cache-paths`.

Release (`.github/workflows/release.yml` in the consumer):

```yaml
name: Release
on:
  push: { branches: [main] }
  workflow_dispatch:
permissions:
  contents: write
  id-token: write
  attestations: write
  artifact-metadata: write
jobs:
  release:
    uses: agoodkind/swift-makefile/.github/workflows/_release.yml@main
    with:
      signing-identity-name: "Developer ID Application: ... (TEAMID)"
      apple-team-id: TEAMID
      notarize-pattern: "*.dmg"
      sbom-subject-path: "Products/My.app"
    secrets: inherit
```

`_release.yml` runs meta, build, notarize, publish. The make layer owns the logic through `swift-release.mk`: set `SWIFT_MK_MODULES := swift-build.mk swift-release.mk` and define `SWIFT_MK_RELEASE_BUILD_CMD` to populate `dist/` (the workflow provides `RELEASE_TAG`, `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`, and signing variables). Signing, notarization, SBOM, and attestations all no-op silently when their secrets or inputs are absent.

Secrets (set per repo; all optional): `APPLE_DEVELOPER_ID_P12_BASE64`, `APPLE_DEVELOPER_ID_P12_PASSWORD`, `APPLE_NOTARY_KEY_BASE64`, `APPLE_NOTARY_KEY_ID`, `APPLE_NOTARY_ISSUER_ID`.

Dependabot automerge (gated on CI success):

```yaml
name: Dependabot Auto Merge
on:
  workflow_run:
    workflows: [CI]
    types: [completed]
jobs:
  automerge:
    uses: agoodkind/swift-makefile/.github/workflows/_dependabot-automerge.yml@main
    permissions:
      contents: write
      pull-requests: write
    secrets: inherit
```

## Local override

Set `SWIFT_MK_DEV_DIR=$HOME/Sites/swift-makefile` (or your own checkout path) to force a consumer repo to fetch shared files from the local checkout.

## Fleet update

- `make update-consumers-dry-run` prints the selected repos and planned actions.
- `make update-consumers` copies `bootstrap.mk`, runs `make update-swift-mk`, runs `make help`, and optionally runs the validation target in each selected repo.
