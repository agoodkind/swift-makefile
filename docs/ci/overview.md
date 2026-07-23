# CI

The engine owns the reusable CI workflow. A pull request receives one required Verify gate plus optional Extra Targets. A push to the default branch skips both, so the release workflow owns the only compile there.

## Reusable workflows

A consumer calls [_ci.yml](../../.github/workflows/_ci.yml), which runs Verify and optional Extra Targets. Verify runs the configured verify build and test commands, defaulting to the repo's normal build and test when they are unset. When a repo sets them to a combined build-with-tests plus a test-without-building pair, the product and test targets compile once and the tests reuse that build; when they are unset, Verify runs the normal build and then the normal test, so the product compiles for the build and again for the test. Either way Verify then runs SwiftLint, Format, Complexity, Swiftcheck Extra, and Audit against the built tree with no further product compile. Dead-code analysis remains a local gate because it requires its own compile. The jobs use the shared [ci-gate action](../../.github/actions/ci-gate/action.yml), so a consumer declares setup inputs and an optional extra-targets list.

## Skip detector

CI skips Verify when a pull request changes nothing the build or lint family depends on. The required Verify check still reports green, and the decision requires no consumer configuration.

The detector, `swift-mk ci-changed`, classifies each changed path into the build family and the lint family and emits the aggregate `run`, which is true when either family changed. Verify uses `run` because it owns both the compile and the lints, so a lint-only change such as `.swiftlint.yml` still runs it. Extra Targets also use `run` because consumer-defined targets have unknown dependencies. A change that touches neither family, such as a `*.md` file, leaves `run` false and skips both.

The detector classifies the changed files with [CiChanged.classify](../../Sources/SwiftMkCore/CiChanged.swift) against two authoritative sets: the build graph, which is what the build compiles, and the lint source set, which is what the lint gate lints. Build configuration that is not lint-only (`Package.swift`, `Package.resolved`, `Makefile`, any `*.mk`, `*.xcconfig`, `*.entitlements`, a path under `.github/workflows/` or `Tuist/`, a committed `*.xcodeproj` or `*.xcworkspace`, a baseline file, and similar) feeds both families. Lint-only configuration (`.swiftlint.yml` and `.swift-format`) feeds only lint. A directory the consumer names in the `extra-dirs` input, a declared resource matched as a prefix, or a compiled source in the build graph feeds build. A linted source in [LintSourceSet](../../Sources/SwiftMkCore/LintPolicy.swift) feeds lint independently, so a source one gate covers is never pruned because another gate skips. Configuration classification takes precedence over the deletion rule: a build or lint config keeps its family whether it is added, modified, or deleted, so a deleted `.swiftlint.yml` still feeds only lint. For a path that is neither build nor lint configuration, a deletion that is not documentation, and a path-fallback path that is not documentation, both feed both families. A file matching none, such as a `*.md` or an image, feeds neither family and is skippable.

The graph is read fresh at head, not from a restored index, because a stale index would skip a change that should build. [readGraph](../../Sources/SwiftMkCore/CiChanged+Graph.swift) resolves it per build system: a SwiftPM package with `swift package describe` (reusing [SwiftPM.describePackageJSON](../../Sources/SwiftMkCore/SwiftPM.swift)), and a committed Xcode project or workspace with XcodeProj, reading every native target's source and resource build phases with the same path resolution as [IndexCompleteness](../../Sources/SwiftMkCore/IndexCompleteness.swift), and including test targets since a test change must run Verify. A Tuist or XcodeGen project is generated rather than committed, so the detector does not generate it; that consumer falls back to path rules where any change that is not documentation runs, and `extra-dirs` covers a doc that code reads or embeds. The detector operates from the git toplevel, so the graph read shares the repo-root base with the git diff and the lint set even when it is invoked from a subdirectory.

The detector selects the diff base by event. A push to the default branch diffs `before..sha`. A pull request, or a push to any branch other than the default, diffs the merge-base of its base branch and its head against its head, so the diff is the branch's own change. Any other event runs everything. It lists changed files with `git diff --name-status --diff-filter=ACMRTD`, so a deleted or renamed path is known, and normalizes each with [IndexCompleteness.standardize](../../Sources/SwiftMkCore/IndexCompleteness.swift) so they match the graph paths. A deleted path is absent from the head sets, so a deletion that is not documentation runs, which keeps a removed source, resource, or config from being pruned into a false skip.

The detector runs both families whenever it cannot be certain: an event that is neither a push nor a pull request, a missing or zero or non-ancestor base, an unresolvable merge-base, any git failure, or a build-graph read that fails.

The `changes` job in [_ci.yml](../../.github/workflows/_ci.yml) publishes `run`. Verify and Extra Targets both pass `run` to the [ci-gate action](../../.github/actions/ci-gate/action.yml). Work skips only when `run` is exactly `false`, so a failed detector with empty output runs the full work. A change-based skip uses an `ubuntu-latest` no-op job, so the required Verify check reports green without occupying a macOS slot.

The `changes` job runs on `ubuntu-latest` in the official Swift container because change detection needs only git and, for the SwiftPM engine repo, `swift package describe`. It builds and caches a Linux `swift-mk` through the [setup-linux-swift-mk](../../.github/actions/setup-linux-swift-mk/action.yml) action, so change detection uses no macOS pool slot.

## Change detection runs on Linux

`swift-mk` builds and runs on Linux as well as macOS, so the change detector runs on a free `ubuntu-latest` runner rather than a scarce macOS slot. Platform-specific code selects a Linux branch with `#if canImport(Darwin)` and `#elseif canImport(Glibc)` guards. On Linux the process-group spawn in [Shell+ProcessGroup](../../Sources/SwiftMkCore/Shell+ProcessGroup.swift) marks the pipe descriptors close-on-exec instead of relying on the Darwin-only spawn flag, and the settle watcher in [IndexStoreSettle](../../Sources/SwiftMkCore/IndexStoreSettle.swift) polls the tree for quiescence instead of using FSEvents.

Only change detection and no-op aggregators use Linux. Verify and configured Extra Targets use macOS when they execute because their build, test, toolchain, generation, or signing work may need Xcode.

The detector produces the same gate-family decision on Linux as on macOS for every repo shape. A generated-project consumer takes the path-classification branch and needs only git. The SwiftPM engine repo also runs `swift package describe`, which the Linux Swift toolchain in the container provides. The [ShellStreamingTests](../../Tests/SwiftMkCoreTests/ShellStreamingTests.swift) process-group reap test and the [IndexStoreSettleTests](../../Tests/SwiftMkCoreTests/IndexStoreSettleTests.swift) watcher tests run on both platforms, so the Linux branches stay verified.

## Pool routing with a hosted floor

CI prefers a self-hosted pool and falls back to GitHub-hosted runners, so a pool outage never blocks a run. The pool routing is best-effort with a hosted floor that always exists.

Each route job uses the shared [plan-runner action](../../.github/actions/plan-runner/action.yml) before its macOS job starts. The action runs on `ubuntu-latest`, calls the broker's `/capacity` endpoint, and emits a label for Verify or Extra Targets. A true capacity response selects the self-hosted pool. An empty capacity URL, a fork pull request, a failed request, a malformed response, or a false capacity response selects the hosted runner input.

The first attempt and the retry are a pair, not two required checks. Verify and Extra Targets run once on the planned label. The first job names itself after where it ran, `self-hosted` or `github-hosted`. When a self-hosted attempt does not succeed, a `github-hosted retry` job runs on the hosted runner. The aggregators keep the visible checks stable as Verify and Extra Targets.

Two pull-request labels override the route for that run and skip the capacity check. `ci-force-hosted` pins Verify and Extra Targets to the hosted runner. `ci-force-pool` pins them to the self-hosted pool. `ci-force-hosted` wins when both are set. `ci-force-pool` never applies to a fork pull request, since the fork guard routes untrusted code to hosted before the pool override is read.

The caller workflow keeps one live CI run per ref with `cancel-in-progress: true`. A newer push cancels the older run, and the infra retry workflow treats that as a superseding run rather than a pool outage.

## Pool outage backstops

The broker handles normal overflow by reporting truthful capacity before a job routes to the pool. The scheduled pool watchdog covers the case where the broker is down or unreachable after a run already queued a pool-labelled job. It scans queued and in-progress runs for jobs stuck on the pool label past the threshold, then cancels the whole run.

The cancelled run stays cancelled and does not auto-recover. A new push re-triggers CI once the pool is healthy, and the route jobs select the pool or hosted runner from current capacity.

The automatic rerun in `ci-infra-retry.yml` is disabled. A cancelled run carries no signal for who cancelled it, so the auto-rerun could not tell a human GitHub-UI cancel from a pool-watchdog infra cancel and reran manual cancels. The workflow keeps only a `workflow_dispatch` trigger, so it never auto-reruns; re-enable the `workflow_run` trigger once an infra-vs-manual cancel signal exists.

## Opt-in CI diagnostics

A pull request labeled `ci-diagnostics` captures macOS system diagnostics around Verify and Extra Targets and uploads them as an artifact, so a build or resolve that hangs on a runner leaves evidence to read. Every consumer inherits this through the [ci-gate action](../../.github/actions/ci-gate/action.yml); a consumer labels its own pull request and needs no configuration.

The feature is pure observability. It only adds capture and upload on top of the existing gate steps. It never kills a process, changes an exit code, or alters timing, so a labeled run behaves the same as an unlabeled run and a hang still hangs to the job's own `timeout-minutes`. Without the label, no instrumentation step runs and nothing is added.

A labeled run sets `SWIFT_MK_LOG_LEVEL=debug` wherever swift-mk runs, including the ubuntu `changes` job, so swift-mk emits its own debug diagnostics. On the macOS gate job it additionally enables Security and network debug logging, records a baseline of the login keychain, and starts a background watcher. The watcher polls for a build child (`swift-package`, `xcodebuild`, or `swift-frontend`) that outlives a threshold, and on one it captures a whole-system `spindump`, a `sample` of the stalled process and every daemon in the keychain-authorization chain (`securityd`, `trustd`, `securityd_system`, `applekeystored`, `endpointsecurityd`, `secd`, and the `SecurityAgent`/`authorizationhost` prompt), `securityd`'s live XPC endpoints and the service-to-pid map (`launchctl procinfo` and `dumpstate`), open handles, wait-channel process table, network state, a keychain snapshot, and reachability probes. The keychain dump redacts account values, and the collectors self-terminate after a backstop lifetime so nothing lingers on a persistent runner. The scripts live under [.github/actions/ci-diagnostics](../../.github/actions/ci-diagnostics).

Delivery uses the cancellation grace window. When a job hits its `timeout-minutes`, GitHub still runs `if: always()` steps for a few minutes before force-terminating, and the watcher captures well before that, so the upload ships the evidence even when the run is cancelled by timeout. The upload is the artifact `ci-diagnostics-<gate>-<runner>`. It holds system diagnostic metadata, including process samples, network state, and login-keychain item metadata with account values redacted, so treat it as internal to people with repository access and rely on the repository's default artifact retention to age it out. Privileged captures need passwordless `sudo`; a runner without it records less rather than failing the job. To read a stall, start with `spindump-*.txt` for the cross-process blocking chain.

## Compile once when configured

Verify runs the configured verify build and test commands. When a repo sets them to a combined build-with-tests plus a test-without-building pair, the product and test targets compile once and the tests reuse that build. When a repo leaves them unset, Verify runs the normal build and then the normal test, so the product compiles for the build and again for the test. Either path runs the source-only lint gates against the built tree with no further product compile.

A pull request runs Verify. A push to the default branch skips the Verify and Extra Targets jobs, so the separate Release workflow owns the only compile on that push. GitHub records the conditionally skipped aggregator jobs as successful checks, so required Verify and Extra Targets checks do not remain pending.

## OSV policy is non-overridable

The dependency audit uses the engine's OSV config through an `override` in [swift.mk](../../swift.mk), so a consumer cannot weaken the policy or its exception list. The single source of exceptions is the engine.

## Bootstrap is a thin stub

`bootstrap.mk` fetches only `swift.mk`, and `swift.mk` extracts one engine snapshot into `.make` plus the shared configs, so a consumer self-heals on the next build. The snapshot carries the whole engine tree, so a source added to the engine is present with no per-file manifest to maintain. [Consumer fetch](../fetch/overview.md) describes the snapshot and its smoke test.
