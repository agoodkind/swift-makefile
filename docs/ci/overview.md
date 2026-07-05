# CI

The engine owns the reusable CI workflows, so a consumer declares only its setup inputs and gets the full gate set. A consumer cannot drop a required gate.

## Reusable workflows

A consumer calls [`_ci.yml`](../../.github/workflows/_ci.yml), which runs the required set: Build, Test, and the Quality gates (SwiftLint, Format, Complexity, Deadcode, Swiftcheck Extra, Audit), plus optional Extra Targets. The gate jobs run through [`_ci-gate.yml`](../../.github/workflows/_ci-gate.yml). A consumer declares setup inputs and an optional extra-targets list, nothing more.

## Skip detector

CI skips build-family and lint-family work independently on a push or pull request that changes nothing a gate family depends on, and every required check still reports green. The decision is engine-owned and automatic, so a consumer sets nothing.

The detector, `swift-mk ci-changed`, emits `run_build` for Build, Test, Deadcode, and Audit, and emits `run_lint` for SwiftLint, Format, Complexity, and Swiftcheck Extra. It also keeps the aggregate `run`, which is true when either family runs. Extra Targets use `run` because consumer-defined targets have unknown dependencies. A lint-only change runs the lint gates and skips build, test, dead-code, and audit. A build-only change runs build, test, dead-code, and audit and skips the lint gates. A compiled `.swift` file feeds both families, so all gates run.

The detector classifies the changed files with [`CiChanged.classify`](../../Sources/SwiftMkCore/CiChanged.swift) against two authoritative sets: the build graph, which is what the build compiles, and the lint source set, which is what the lint gate lints. Build configuration that is not lint-only (`Package.swift`, `Package.resolved`, `Makefile`, any `*.mk`, `*.xcconfig`, `*.entitlements`, a path under `.github/workflows/` or `Tuist/`, a committed `*.xcodeproj` or `*.xcworkspace`, a baseline file, and similar) feeds both families. Lint-only configuration (`.swiftlint.yml` and `.swift-format`) feeds only lint. A directory the consumer names in the `extra-dirs` input, a declared resource matched as a prefix, or a compiled source in the build graph feeds build. A linted source in [`LintSourceSet`](../../Sources/SwiftMkCore/LintPolicy.swift) feeds lint independently, so a source one gate covers is never pruned because another gate skips. Configuration classification takes precedence over the deletion rule: a build or lint config keeps its family whether it is added, modified, or deleted, so a deleted `.swiftlint.yml` still feeds only lint. For a path that is neither build nor lint configuration, a deletion that is not documentation, and a path-fallback path that is not documentation, both feed both families. A file matching none, such as a `*.md` or an image, feeds neither family and is skippable.

The graph is read fresh at head, not from a restored index, because a stale index would skip a change that should build. [`readGraph`](../../Sources/SwiftMkCore/CiChanged+Graph.swift) resolves it per build system: a SwiftPM package with `swift package describe` (reusing [`SwiftPM.describePackageJSON`](../../Sources/SwiftMkCore/SwiftPM.swift)), and a committed Xcode project or workspace with XcodeProj, reading every native target's source and resource build phases with the same path resolution as [`IndexCompleteness`](../../Sources/SwiftMkCore/IndexCompleteness.swift), and including test targets since a test change must run the test gate. A Tuist or XcodeGen project is generated rather than committed, so the detector does not generate it; that consumer falls back to path rules where any change that is not documentation runs, and `extra-dirs` covers a doc that code reads or embeds. The detector operates from the git toplevel, so the graph read shares the repo-root base with the git diff and the lint set even when it is invoked from a subdirectory.

The detector selects the diff base by event. A push to the default branch diffs `before..sha`. A pull request, or a push to any branch other than the default, diffs the merge-base of its base branch and its head against its head, so the diff is the branch's own change. Any other event runs everything. It lists changed files with `git diff --name-status --diff-filter=ACMRTD`, so a deleted or renamed path is known, and normalizes each with [`IndexCompleteness.standardize`](../../Sources/SwiftMkCore/IndexCompleteness.swift) so they match the graph paths. A deleted path is absent from the head sets, so a deletion that is not documentation runs, which keeps a removed source, resource, or config from being pruned into a false skip.

The detector runs both families whenever it cannot be certain: an event that is neither a push nor a pull request, a missing or zero or non-ancestor base, an unresolvable merge-base, any git failure, or a build-graph read that fails.

Skipping is step-level, so the required checks stay green. The `changes` job in [`_ci.yml`](../../.github/workflows/_ci.yml) publishes `run_build`, `run_lint`, and `run`. Build and Test pass `run_build` into [`_ci-gate.yml`](../../.github/workflows/_ci-gate.yml). Each Quality matrix row declares either the build or lint signal and guards its expensive steps on that per-gate value. Extra Targets pass the aggregate `run`. Work skips only when the selected signal is exactly `false`, so a failed `changes` job with empty output runs the full work. The gate job still finishes with success, so the required Build, Test, and Quality checks report green.

On a skip, each gate job routes to an `ubuntu-latest` runner instead of the macOS pool, through a conditional `runs-on` in [`_ci.yml`](../../.github/workflows/_ci.yml). The job runs, its guarded steps skip, and its named check reports green from the cheap runner, so skipped gate jobs occupy no macOS pool slot. The `changes` job itself reads the graph on the runner `plan-runners` selects, which is the self-hosted pool label when the pool has free capacity and a hosted runner when it does not, so the detector uses at most one macOS runner per push or pull request. It restores the swift-mk binary and the dependency cache so `swift package describe` resolves without a cold fetch.

## Runners with a hosted floor

CI prefers a self-hosted pool and falls back to GitHub-hosted runners, so a pool outage never blocks a run. The pool routing is best-effort with a hosted floor that always exists.

## Build on the default branch to warm pull requests

A consumer builds on its default branch so pull requests inherit a warm compile cache. The consumer workflow keeps its pull-request trigger and adds a push trigger scoped to the default branch:

```yaml
on:
  pull_request:
    branches: [main]
  push:
    branches: [main]
```

The push trigger is filtered to the default branch, so a push to a pull request's own branch does not match it and adds no run. Pull-request runs are unchanged. The first build on the default branch compiles cold and fills the cache; later pull requests restore it. The [caching overview](../caching/overview.md) explains why the default branch must build.

## OSV policy is non-overridable

The dependency audit uses the engine's OSV config through an `override` in [`swift.mk`](../../swift.mk), so a consumer cannot weaken the policy or its exception list. The single source of exceptions is the engine.

## Bootstrap is a thin stub

`bootstrap.mk` fetches only `swift.mk`, and `swift.mk` fetches everything else (configs, helper scripts, modules), so a consumer self-heals on the next build. The fetched file set is `SWIFT_MK_SCRIPT_FILES`, and [ManifestCompletenessTests](../../Tests/SwiftMkCoreTests/ManifestCompletenessTests.swift) fails the build when an engine file is missing from it.
