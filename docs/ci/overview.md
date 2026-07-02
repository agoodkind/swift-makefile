# CI

The engine owns the reusable CI workflows, so a consumer declares only its setup inputs and gets the full gate set. A consumer cannot drop a required gate.

## Reusable workflows

A consumer calls [`_ci.yml`](../../.github/workflows/_ci.yml), which runs the required set: Build, Test, and the Quality gates (SwiftLint, Format, Complexity, Deadcode, Swiftcheck Extra, Audit), plus optional Extra Targets. The gate jobs run through [`_ci-gate.yml`](../../.github/workflows/_ci-gate.yml). A consumer declares setup inputs and an optional extra-targets list, nothing more.

## Skip detector

CI skips the build, test, and lint work on a push that changes nothing those gates depend on, and every required check still reports green. The decision is engine-owned and automatic, so a consumer sets nothing.

The detector, `swift-mk ci-changed`, classifies the changed files with [`CiChanged.classify`](../../Sources/SwiftMkCore/CiChanged.swift) against two authoritative sets: the build graph, which is what the build compiles, and the lint source set, which is what the lint gate lints. A changed file is relevant when it is a build configuration (`Package.swift`, `Package.resolved`, `Makefile`, any `*.mk`, `*.xcconfig`, `*.entitlements`, a path under `.github/workflows/` or `Tuist/`, a committed `*.xcodeproj` or `*.xcworkspace`, a baseline file, and similar), or under a directory the consumer names in the `extra-dirs` input (a whitespace-separated list of repo-root-relative paths), or a declared resource matched as a prefix so a directory resource catches a change inside it, or a compiled source in the build graph, or a linted source in [`LintSourceSet`](../../Sources/SwiftMkCore/LintPolicy.swift). The lint gate lints every tracked and untracked-but-not-ignored `.swift`, so a `.swift` the build does not compile still runs; a source-shaped file that neither the build compiles nor the lint gate scans, such as a git-ignored generated source, is skippable. A file matching none, such as a `*.md` or an image, is skippable, and when every changed file is skippable CI skips.

The graph is read fresh at head, not from a restored index, because a stale index would skip a change that should build. [`readGraph`](../../Sources/SwiftMkCore/CiChanged+Graph.swift) resolves it per build system: a SwiftPM package with `swift package describe` (reusing [`SwiftPM.describePackageJSON`](../../Sources/SwiftMkCore/SwiftPM.swift)), and a committed Xcode project or workspace with XcodeProj, reading every native target's source and resource build phases with the same path resolution as [`IndexCompleteness`](../../Sources/SwiftMkCore/IndexCompleteness.swift), and including test targets since a test change must run the test gate. A Tuist or XcodeGen project is generated rather than committed, so the detector does not generate it; that consumer falls back to path rules where any change that is not documentation runs, and `extra-dirs` covers a doc that code reads or embeds. The detector operates from the git toplevel, so the graph read shares the repo-root base with the git diff and the lint set even when it is invoked from a subdirectory.

The detector selects the diff base by event: a non-push event runs everything, a push to the default branch diffs `before..sha`, and a push to any other branch diffs the merge-base of the default branch and head against head. It lists changed files with `git diff --name-status --diff-filter=ACMRTD`, so a deleted or renamed path is known, and normalizes each with [`IndexCompleteness.standardize`](../../Sources/SwiftMkCore/IndexCompleteness.swift) so they match the graph paths. A deleted path is absent from the head sets, so a deletion that is not documentation runs, which keeps a removed source, resource, or config from being pruned into a false skip.

The detector runs everything whenever it cannot be certain: a non-push event, a missing or zero or non-ancestor base, an unresolvable merge-base, any git failure, or a build-graph read that fails.

Skipping is step-level, so the required checks stay green. The `changes` output feeds a `run` input on [`_ci-gate.yml`](../../.github/workflows/_ci-gate.yml), and each expensive step is guarded on `inputs.run != 'false'`. Work skips only when the signal is exactly `false`, so a failed `changes` job with empty output runs the full work. The gate job still finishes with success, so the required Build, Test, and Quality checks report green. The `changes` job and its `run` passthrough live in [`_ci.yml`](../../.github/workflows/_ci.yml).

On a skip, each gate job routes to an `ubuntu-latest` runner instead of the macOS pool, through a conditional `runs-on` in [`_ci.yml`](../../.github/workflows/_ci.yml). The job runs, its guarded steps skip, and its named check reports green from the cheap runner, so the gate jobs occupy no macOS pool slot on a skip. The `changes` job itself reads the graph on the runner `plan-runners` selects, which is the self-hosted pool label when the pool has free capacity and a hosted runner when it does not, so the detector uses at most one macOS runner per push. It restores the swift-mk binary and the dependency cache so `swift package describe` resolves without a cold fetch.

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
