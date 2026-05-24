# swift-makefile

`swift-makefile` provides shared Make targets, shared lint policy, shared baseline policy, a shared SwiftSyntax analyzer, and shared update scripts for Swift repos.

## Files

- `bootstrap.mk` fetches `swift.mk`, shared configs, shared helper scripts, and shared modules into `.make/`.
- `swift.mk` defines the shared public targets.
- `swift-build.mk` defines shared build, run, generate, clean, and deploy targets from consumer-provided commands.
- `swift-release.mk` defines shared release wrapper targets from consumer-provided commands.
- `scripts/` contains the shared shell and awk helpers.
- `swiftcheck/` contains the shared SwiftSyntax analyzer package.

## Public targets

- `make build`
- `make check`
- `make build-check`
- `make lint`
- `make fmt`
- `make test`
- `make analyze`
- `make audit`
- `make lint-diff`
- `make lint-files LINT_FILES=...`
- `make baseline`
- `make baseline-prune-fixed`
- `make baseline-accept-new`
- `make lint-complexity-baseline-accept-new`
- `make update-swift-mk`
- `make update-consumers`
- `make update-consumers-dry-run`
- `make smoke-fetch`

## Shared policy

- SwiftLint configuration lives in `.swiftlint.yml`.
- swift-format configuration lives in `.swift-format`.
- Periphery configuration lives in `.periphery.yml`.
- Shared baseline files record `first_added` and `last_seen` for SwiftLint, SwiftLint complexity, Periphery, and `swiftcheck-extra` findings.
- `swiftcheck-extra` reports logging, type, lifecycle, cleanup, sleep, task, and fatal-exit violations.

## Bootstrap

`bootstrap.sh` writes a small SwiftPM consumer `Makefile` and `bootstrap.mk`.

## Local override

Set `SWIFT_MK_DEV_DIR=/Users/agoodkind/Sites/swift-makefile` to force a consumer repo to fetch shared files from the local checkout.

## Fleet update

- `make update-consumers-dry-run` prints the selected repos and planned actions.
- `make update-consumers` copies `bootstrap.mk`, runs `make update-swift-mk`, runs `make help`, and optionally runs the validation target in each selected repo.
