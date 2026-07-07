# swift-makefile

`swift-makefile` provides shared Make targets, shared lint policy, shared baseline policy, a shared SwiftSyntax analyzer, and shared update scripts for Swift repos.

Provided AS IS under the MIT License with no warranty. See [LICENSE](LICENSE).

## Architecture

Each subsystem has a present-tense overview under `docs/<area>/overview.md` that links to the source and test holding each detail, so the docs track the code.

- [Build](docs/build/overview.md) covers the two chokepoints, the CLI-not-library rationale, the per-worktree build lock, and the routing enforcement.
- [Build gate](docs/gate/overview.md) covers the gate proof, the in-process receipt, and the direct-toolchain audit.
- [Dead-code gate](docs/deadcode/overview.md) covers the two scans, the engine-derived coverage build and its owned settings, the shared prebuild seam, the index-completeness check, and the coverage-completeness check.
- [Signing](docs/signing/overview.md) covers the single-source-of-truth xcconfig override, inferred style, and post-build signing and notarization.
- [Caching](docs/caching/overview.md) covers the engine-owned cache plan and the compile-cache stores.
- [Consumer fetch](docs/fetch/overview.md) covers the fetched `.make` package, the `SWIFT_MK_SCRIPT_FILES` manifest, and the completeness invariant every consumer's `swift-mk` build depends on.
- [CI](docs/ci/overview.md) covers the reusable workflows, the required gate set, the skip detector, runner fallback, and the non-overridable OSV policy.

## Files

- `swift-mk` is a Swift command-line program that carries the shared lint, baseline, gate, and notice logic. It builds from the root SwiftPM package: the `SwiftMkCore` library holds the logic, the `SwiftMkCLI` executable wraps it, and the package produces the `swift-mk` product using `apple/swift-argument-parser`. `scripts/swift-mk-build.sh` builds and caches the binary at `.make/swift-mk`, and `swift.mk` invokes it.
- `Sources/SwiftMkCore/` holds the shared lint, baseline, gate, and notice logic.
- `bootstrap.mk` fetches `swift.mk`, shared configs, shared helper scripts, and shared modules into `.make/`.
- `swift.mk` defines the shared public targets.
- `swift-build.mk` defines shared build, run, generate, clean, deploy, and install targets from consumer-provided commands.
- `swift-release.mk` defines shared release wrapper targets from consumer-provided commands.
- `xcconfig.mk` renders `*.template` files into `Derived/Generated/$(TARGET_NAME)/` for Tuist projects that treat one or more xcconfig files as the source of truth. The consumer Makefile `-include`s its xcconfig files, lists the keys it wants exposed (`XCCONFIG_EXPORTED_VARS`), points at its templates dir (`XCCONFIG_TEMPLATES_DIR`), and lists target names (`XCCONFIG_GENERATOR_TARGETS`). The `xcconfig-generate-config` target renders once per target; `xcconfig-generate-project` chains that into `tuist generate --no-open` so the glob inside `Project.swift` finds the generated files. Templates use `[[KEY]]` substitutions. See `swift-mk render-batch --help` for the underlying renderer.
- `swift-app.mk` defines shared macOS app packaging for an app that ships as a signed `.app` inside a `.dmg` and updates through Sparkle. A consumer loads it with `SWIFT_MK_MODULES := swift-build.mk swift-app.mk`, sets `SWIFT_APP_NAME` plus a few `SWIFT_APP_*` overrides, and gets `app`, `dmg`, `release-assets`, `prepare-sparkle-updates`, and `sparkle-appcast`. `swift-build.mk` still owns `build`; `swift-app.mk` owns everything after the build. The build line stays the consumer's `SWIFT_BUILD_CMD`. See the header of `swift-app.mk` for the full variable surface.
- `scripts/` holds only the bash bootstrap, fetch, build, and distribution layer that runs before the binary exists: `swift-mk-fetch-one.sh`, `swift-mk-build.sh`, `swift-mk-sync.sh`, `swift-mk-fleet-update.sh`, `install-hooks.sh`, and `release-build.sh` (the release dmg build hook).
- `swiftcheck/` contains the shared SwiftSyntax analyzer package.

## Install

`swift-mk` builds from source by default at `.make/swift-mk`, which is how you run the lint, build, and dead-code gates. A host that only needs to self-update and prune caches (for example a CI pool runner) can install the prebuilt maintenance binary instead: a lean, index-free build that provides `version`, `update`, and `cache prune`. Install the signed, notarized build on an Apple Silicon Mac with:

```sh
curl -fsSL https://raw.githubusercontent.com/agoodkind/swift-makefile/main/install.sh | bash
```

To pin a release tag or change the install directory without a local checkout, pass flags through `bash -s --`:

```sh
curl -fsSL https://raw.githubusercontent.com/agoodkind/swift-makefile/main/install.sh | bash -s -- --version <TAG> --bin-dir <DIR>
```

`swift-mk version` reports the installed release tag. `swift-mk update check` reports whether a newer release exists; `swift-mk update apply` verifies the new release's Developer ID signature and staple, then replaces the running binary in place. `swift-mk cache prune --path <dir> --max-bytes <n>` evicts least-recently-used entries from a cache directory to keep it under a byte cap. The `update` command is generic: point it at any consumer's dmg release with `--repo`, `--asset`, and `--target`.

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

The dead-code gate scans the Swift package and, when the repository declares an Xcode build, every Xcode target. It builds a fresh coverage index through `Toolchain.buildCoverage`, then passes no scan configuration and no build settings to Periphery. A consumer with an Xcode project wires these values:

- Include `bootstrap.mk` and the `swift-build.mk` module.
- Set `SWIFT_XCODE_GENERATOR` to `tuist` or `xcodegen`, set `SWIFT_XCODE_SCHEME`, and set either `SWIFT_XCODE_WORKSPACE` or `SWIFT_XCODE_PROJECT`.
- Set `SWIFT_XCODE_COVERAGE_CONFIGURATION` when coverage should build a configuration other than Debug, and set `SWIFT_XCODE_BUILD_SETTINGS` for extra `KEY=value` build settings.
- Set `SWIFT_GENERATE_CMD` when the project needs a custom generation command. When `SWIFT_GENERATE_CMD` is unset, the gate runs `xcodegen generate` for a `project.yml` or `tuist generate` for a `Project.swift` or `Workspace.swift`.
- Set `SWIFT_XCODE_PREBUILD_CMD` when the build needs a step before xcodebuild, such as building a native library the project links. The engine runs it before every xcodebuild it drives, so the coverage build and the normal build share one prep step.

The coverage build writes a compiler index store under `SWIFT_MK_DERIVED_DATA`, and swift-mk disables signing and the local Xcode compilation cache for that coverage build. `SWIFT_MK_DERIVED_DATA` defaults to `$(CURDIR)/.derived-data`; add it to `.gitignore`. Schemes and supported platforms come from the generated Xcode container, and schemes whose name is a Swift package target are excluded from the Xcode scan because the package scan already covers them.

The gate fails with a message naming the cause when a repository declares an Xcode project it cannot scan:

- A `Project.swift`, `Workspace.swift`, or `project.yml` is present but no project was generated.
- An Xcode project is present but the coverage build fails.
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

## Build architecture

The engine runs every build through one of two chokepoints, so the gate, the build lock, and the shared cache flags apply in one place. `Toolchain` is the one site that runs `xcodebuild`. `SwiftPM` is the one site that runs `swift build`, `swift test`, and `swift run`. [docs/build/overview.md](docs/build/overview.md) covers the chokepoints, the CLI-not-library rationale, the per-worktree build lock, and the routing enforcement.

## Build caching

- `SWIFT_MK_SWIFT_CACHE` defaults to `auto` and is the shared local Swift cache policy for SwiftPM and Xcode builds.
- A standard SwiftPM consumer gets zero-shot cache adoption because the default `SWIFT_BUILD_CMD` and `SWIFT_TEST_CMD` include `SWIFT_MK_SWIFTPM_CACHE_ARGS`.
- A standard Xcode consumer gets zero-shot cache adoption because the canonical `SWIFT_XCODE_SCHEME` path adds `SWIFT_MK_XCODEBUILD_ARGS` to build and test commands.
- A custom SwiftPM consumer gets one-shot adoption by appending `$(SWIFT_MK_SWIFTPM_CACHE_ARGS)` to its `swift build` and `swift test` commands.
- A custom Xcode consumer gets one-shot adoption by appending `$(SWIFT_MK_XCODEBUILD_ARGS)` to normal `swift-mk toolchain build` or `toolchain test` calls, and `$(SWIFT_MK_XCODEBUILD_NO_CACHE_ARGS)` to dead-code, analyzer, or compiler-log builds that need fresh index/log output.
- `SWIFT_MK_SWIFTPM_CACHE` and `SWIFT_MK_XCODE_CACHE` override the SwiftPM-specific and Xcode-specific cache policies when one build surface needs different behavior.
- `SWIFT_MK_XCODE_CACHE_DIAGNOSTICS=1` enables compilation-cache diagnostic remarks for `xcodebuild` paths.
- `SWIFT_MK_SWIFTPM_CACHE_ARGS` defaults to the supported shared SwiftPM cache flags exposed by the local toolchain.
- `swift build` LLVM compilation caching is on by default, the SwiftPM peer of the Xcode compilation cache: the engine enables it on any toolchain that supports the flag (Swift 6.3+), so a consumer sets nothing and the engine owns it with no opt-out. [docs/caching.md](docs/caching.md) covers the two cache stores and the cross-runner behavior.
- `ccache` and `sccache` are C-family compiler-wrapper tools. They are not Swift compilation caches in `swift-makefile`.
- Shared GitHub Actions CI and release jobs default to `cache-profile: safe`. The safe profile restores dependency caches and build intermediates, including SwiftPM, Tuist, mise, ccache/sccache, `.build`, and Xcode intermediate paths under `build`, `.derived-data`, `DerivedData`, or `Derived`. It does not cache `Products`, `dist`, keychains, provisioning profiles, notarization files, or signed final artifacts.
- `cache-profile: dependencies` restores only dependency caches. `cache-profile: off` disables the shared cache setup.
- `cache-version` defaults to `v1` and is the manual namespace for invalidating all canonical caches. Build-intermediate caches also include the selected Xcode version, Swift version, runner OS/arch, build configuration hash, and a weekly epoch.
- `extra-cache-paths` is additive and should contain only non-secret, non-final-artifact paths that are safe to restore into later CI jobs.
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
permissions:
  contents: read
  # actions: read lets the shared Quality aggregator read this run's jobs to
  # resolve each lint's pool-or-hosted result. A reusable job cannot exceed the
  # caller's grant, so this must be granted here or the Quality gate fails startup.
  actions: read
jobs:
  ci:
    uses: agoodkind/swift-makefile/.github/workflows/_ci.yml@main
    secrets: inherit
```

`Build`, `Test`, and the shared `Quality / ...` gates run automatically. Consumers only pass repo-specific setup plus optional `extra-targets` when they need bespoke checks such as `smoke-fetch`.

Key `_ci.yml` inputs: `extra-targets` (JSON array of optional bespoke make targets run after the shared required jobs), `targets` (legacy alias for `extra-targets`; built-in `build`, `test`, `lint`, `audit`, `build-check`, `quality-guard`, and quality subtargets are filtered out), `setup-target` (make target run before each required job and once before the extra-target batch), `make-args`, `brew-packages`, `runner`, `cache-profile`, `cache-version`, `import-signing-cert` + `signing-identity-name` + `apple-team-id` (real Developer ID builds), `extra-cache-paths`.

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

Verifying release attestations: provenance signed inside a reusable workflow records the CALLED workflow's repository as the signer, so a plain `gh attestation verify <artifact> -R <consumer>` fails with `Error: verifying with issuer "sigstore.dev"`. Pass the signer repo explicitly:

```sh
gh attestation verify <artifact> -R <owner>/<consumer> --signer-repo agoodkind/swift-makefile
```

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
