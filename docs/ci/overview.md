# CI

The engine owns the reusable CI workflows, so a consumer declares only its setup inputs and gets the full gate set. A consumer cannot drop a required gate.

## Reusable workflows

A consumer calls [`_ci.yml`](../../.github/workflows/_ci.yml), which runs the required set: Build, Test, and the Quality gates (SwiftLint, Format, Complexity, Deadcode, Swiftcheck Extra, Audit), plus optional Extra Targets. The gate jobs run through the [ci-gate composite action](../../.github/actions/ci-gate/action.yml). A consumer declares setup inputs and an optional extra-targets list, nothing more.

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
