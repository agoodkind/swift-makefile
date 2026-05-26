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

## Local override

Set `SWIFT_MK_DEV_DIR=$HOME/Sites/swift-makefile` (or your own checkout path) to force a consumer repo to fetch shared files from the local checkout.

## Fleet update

- `make update-consumers-dry-run` prints the selected repos and planned actions.
- `make update-consumers` copies `bootstrap.mk`, runs `make update-swift-mk`, runs `make help`, and optionally runs the validation target in each selected repo.
