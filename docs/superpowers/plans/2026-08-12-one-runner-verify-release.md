# One-Runner Verify-Release Implementation Plan (workflow-only)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One macOS job per pull request runs the verify stages then the release dry-run stages serially, publishing one named check per stage; the separate Release workflow stops running on pull requests.

**Architecture:** Pure workflow and make changes, no Swift. The reusable CI's Verify job gains a release-dry-run mode: after the verify stages it imports the Developer ID certificate, installs profiles, runs the release build, notarizes, and packages, all on the same machine, so the release compiles replay the local compilation cache the verify build just filled. Named check rows come from `gh api` check-run steps. The in-job overlap orchestrator (tests parallel with notarization) is explicitly out of scope, a later decision.

**Tech Stack:** GitHub Actions reusable workflows, make, gh CLI, Swift only for existing tests.

## Global Constraints

- Every compile goes through the existing `swift-mk build` chokepoints; this plan adds no new compile entry and no new knob; the hard gate is unchanged.
- The release stages never run a lint gate and never install lint tools.
- One macOS job per pull request; `ubuntu-latest` is unlimited and carries change detection, aggregation, and any check bookkeeping that needs no Xcode.
- The combined job keeps `gate: verify` for the compile bucket: `verify` is already a compile-bucket writer, and the one pile now carries both compiles. No cache code changes.
- Merges to main are untouched: CI still runs nothing there; `release.yml` keeps `push` and `workflow_dispatch`.
- Fork and Dependabot pull requests run the verify stages only; the `Release dry run` check reports skipped for them.
- Spec: `docs/superpowers/specs/2026-08-12-one-runner-verify-release-design.md`; its "Invariants preserved" section lists the log line each proof run must show.
- Commit style per the repo: imperative subject, Claude trailer, `git commit -S`.

---

### Task 1: Split the verify recipe into stage targets

**Files:**
- Modify: `swift.mk` and/or `swift-build.mk` (wherever the `verify` recipe lives; read it first)
- Test: extend the existing verify-recipe behavior test in `Tests/SwiftMkCoreTests/` (the temp-consumer + fake-engine harness style of `ReleaseBuildGenerateOrderTests.swift`); create `Tests/SwiftMkCoreTests/VerifyStageTargetsTests.swift` if none covers verify ordering today.

**Interfaces:**
- Consumes: existing variables `SWIFT_GENERATE_CMD`, `SWIFT_VERIFY_BUILD_CMD`, `SWIFT_VERIFY_TEST_CMD`, the lint gate chain the current `verify` recipe runs.
- Produces: three make targets the workflow calls as separate steps, `verify-build` (generation guard plus the verify build through `swift-mk build`), `verify-test` (the verify test command against the built tree), `verify-quality` (the source-only lint gates). `verify` becomes exactly the chain of the three, so every existing caller sees identical behavior.

- [ ] **Step 1:** Read the current `verify` recipe; write the failing behavior test asserting (a) `make verify` order is unchanged (generate, build, test, lints against the fake engine's order file) and (b) each stage target runs only its own slice (`make verify-build` emits no test or lint marker).
- [ ] **Step 2:** Run, expect FAIL: `make test SWIFT_TEST_CMD='swift test --filter VerifyStageTargets'`.
- [ ] **Step 3:** Split the recipe; `verify` depends on nothing new, it invokes the three in order within the same guard structure it has today (preserve `SWIFT_MK_GENERATED=1` handling so generation runs once, not three times: `verify-test` and `verify-quality` must not re-generate).
- [ ] **Step 4:** Run, expect PASS; then the full engine suite: `make test`.
- [ ] **Step 5:** Commit `Split verify into verify-build, verify-test, and verify-quality targets`.

---

### Task 2: Release-dry-run mode in the reusable CI, engine adoption

**Files:**
- Modify: `.github/workflows/_ci.yml` (Verify macOS job), `.github/actions/ci-gate/action.yml` only if the gate steps must split (prefer workflow-level steps after the gate action)
- Modify: `.github/workflows/ci.yml` (engine enables the mode), `.github/workflows/release.yml` (drop `pull_request` trigger, drop the `release-dry-run` gate job, collapse the concurrency cancel expression)
- Modify: `docs/ci/overview.md` (current-state rewrite of the affected sections)

**Interfaces:**
- Consumes: Task 1's `verify-build` / `verify-test` / `verify-quality` targets; the existing `import-signing-cert`, `install-provisioning-profile`, `notarize-staple` composite actions; `_release.yml`'s "Build release artifacts" env/run block (`.github/workflows/_release.yml:618-652`) as the template for the release-build step.
- Produces: new `_ci.yml` inputs `release-dry-run` (boolean, default false), `release-timeout-minutes` (number, default 60), plus forwards for `notarize-pattern`, `dist-dir`, `build-target` release inputs; the Verify job in dry-run mode runs steps in order: verify-build, verify-test, verify-quality, install Developer ID cert and profiles, release build (the `_release.yml` env/run block verbatim, `BUILD_TARGET=release-build`), notarize-staple, package presence check. After each stage a `gh api repos/${GITHUB_REPOSITORY}/check-runs` step publishes the named check (`Build`, `Tests`, `Quality`, `Release dry run`) against `github.event.pull_request.head.sha`, with `checks: write` on the job and `GH_TOKEN: ${{ github.token }}`. Failure of stage N publishes N as failure and the later names as cancelled via an `if: always()` bookkeeping step. Fork or Dependabot forces the mode off and publishes `Release dry run` skipped. The Linux docs-only skip path publishes all four green. The job's `timeout-minutes` becomes `release-timeout-minutes` when the mode is on.

- [ ] **Step 1:** Implement the `_ci.yml` changes; keep the local/remote two-step action split the file uses throughout.
- [ ] **Step 2:** Engine `ci.yml` sets `release-dry-run: true` with `signing-identity-name: ${{ vars.APPLE_DEVELOPER_ID_IDENTITY }}`, `apple-team-id: ${{ vars.APPLE_TEAM_ID }}`, `notarize-pattern: "*.dmg"`; `release.yml` drops its `pull_request` trigger and gate job.
- [ ] **Step 3:** `make check`; commit `Run the release dry run inside CI's verify job on pull requests`.
- [ ] **Step 4:** Push the engine PR. Its own run is the proof; collect from the job log into the PR description: one macOS job in the run list; the four named checks on the PR; one verify build then `--skip-build` tests; `swift-mk build --command` entries for both compiles; `Cache saved with key` under the `verify` writer; `install-lint-tools: true` only in the verify half and zero lint invocations after the quality stage; Notarize reached; Publish and Smoke absent. Update the engine ruleset required checks to the four names at merge.

---

### Task 3: Consumer rollout

Order: macos-fan-curve, stickies-improved, macos-smc-fan, lmd, iphone-cell-tunnel (after #113 lands). Per consumer:

- [ ] **Step 1:** One PR switching `ci.yml` to `release-dry-run: true` with that repo's release inputs (identity and team variables, notarize pattern, `install-provisioning-profile` where used, `brew-packages: go` for ict) and deleting `release.yml`'s `pull_request` trigger. First open it as a probe pinning the engine ref if the engine change is not yet on `@main`.
- [ ] **Step 2:** Verify from the run's logs: one macOS job total; four named checks; release stages held before publish; cache save present; wall clock recorded against the repo's previous parallel time. lmd sets `release-timeout-minutes: 90` (its verify alone measured 55m50s).
- [ ] **Step 3:** Switch the repo's ruleset required checks to the stage names in the same merge; clean up branches and worktrees.

---

## Out of scope

- The in-job overlap orchestrator (tests parallel with notarization) and per-stage Swift check publisher: deferred; reconsider only if the serial wall clock measured in Task 3 hurts.
- GOALS.md line 3 rewording (release reuse becomes same-machine) is the owner's file; flag at rollout, do not edit.

## Self-review notes

- Task 1 risk: the verify recipe may already be step-shaped inside `ci-gate/action.yml` rather than one make recipe; if the gate action already runs build/test/lints as separate steps, Task 1 shrinks to exposing make entry points the action already uses, and the test still pins the ordering contract.
- Spec coverage: one runner (T2), named checks (T2), local reuse (T2, same machine), fork/skip (T2), main untouched (T2 trigger deletion only), timeout (T2/T3 lmd), rollout probes (T3). Overlap intentionally dropped per owner scope decision 2026-08-12.
