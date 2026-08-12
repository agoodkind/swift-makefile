# One-Runner Verify-Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One macOS job per pull request runs the verify build, the release build, then tests plus lints in parallel with sign/notarize/package, publishing one named check per stage.

**Architecture:** A new `swift-mk verify-release` orchestrator owns the stage graph in-process; `_ci.yml` gains a combined-job mode that replaces the separate Release dry-run workflow on pull requests; the compile store never leaves the machine, and the cross-run cache keeps its rolling-writer mechanism with a new `verify-release` writer. Merges to main are untouched.

**Tech Stack:** Swift (SwiftMkCore/SwiftMkCLI, swift-argument-parser, Swift Testing), GitHub Actions reusable workflows, make.

## Global Constraints

- Every compile goes through the existing `swift-mk build` chokepoint (GateProof mark, inline-gate skip); the orchestrator invokes existing make recipes, never new raw command strings.
- The release lane never runs a lint gate; a missing lint binary in the release lane is a defect to surface, not to route around.
- No new settable bypass value; the orchestrator adds no knob that changes the hard gate.
- One macOS job per pull request; anything that does not need Xcode runs on `ubuntu-latest`.
- Cache keys and writer mechanics stay in `CachePlan.compute` (`Sources/SwiftMkCore/CachePlan.swift:124-183`); the combined job is one writer named `verify-release`.
- `respond` style rules for all prose; engine file headers and comment conventions per existing files.
- Spec: `docs/superpowers/specs/2026-08-12-one-runner-verify-release-design.md`. Its "Invariants preserved" section lists the log line each probe run must show.

---

### Task 1: Check-run publisher (`swift-mk check-run`)

**Files:**
- Create: `Sources/SwiftMkCore/CheckRun.swift`
- Create: `Sources/SwiftMkCLI/CheckRunCommand.swift`
- Modify: `Sources/SwiftMkCLI/SwiftMk.swift:23-39` (add `CheckRunCommand.self` to `subcommands`)
- Test: `Tests/SwiftMkCoreTests/CheckRunTests.swift`

**Interfaces:**
- Consumes: `Output` (logging), `Env` (environment reads), Foundation `URLSession`.
- Produces: `CheckRun.publish(name:status:conclusion:summary:) throws`, CLI `swift-mk check-run --name <n> --status <queued|in_progress|completed> [--conclusion <success|failure|cancelled|skipped>] [--summary <text>]`. Task 3's orchestrator calls the CLI form; the workflow may call it directly for the skip path.

Environment contract (all standard GitHub Actions variables): `GITHUB_API_URL`, `GITHUB_REPOSITORY`, `GITHUB_TOKEN`, and the head commit from `SWIFT_MK_CHECK_SHA` falling back to `GITHUB_SHA`. `SWIFT_MK_CHECK_SHA` exists because on a `pull_request` event `GITHUB_SHA` is the merge commit; the workflow passes `github.event.pull_request.head.sha` explicitly so the check lands on the head the pull request view shows. Missing token or repository logs one line and exits 0: check publishing is reporting, never a gate, so it must not fail a build that otherwise passed.

- [ ] **Step 1: Write the failing test.** Typed request model, no `Any`. The test boots a local `HTTPServer` on `[::1]` (follow the listener pattern in `Tests/SwiftMkCoreTests/` used by existing network tests; if none exists, use a minimal `NWListener` echo that records the request body), points `GITHUB_API_URL` at it, and asserts the POST path is `/repos/agoodkind/example/check-runs` and the JSON body decodes to `name == "Tests"`, `head_sha == "abc123"`, `status == "completed"`, `conclusion == "failure"`.

```swift
@Test
func publishPostsATypedCheckRun() throws {
  let server = try RecordingHTTPServer.start()
  defer { server.stop() }
  setenv("GITHUB_API_URL", server.baseURL, 1)
  setenv("GITHUB_REPOSITORY", "agoodkind/example", 1)
  setenv("GITHUB_TOKEN", "test-token", 1)
  setenv("SWIFT_MK_CHECK_SHA", "abc123", 1)

  try CheckRun.publish(
    name: "Tests", status: .completed, conclusion: .failure, summary: "2 tests failed")

  let request = try #require(server.lastRequest)
  #expect(request.path == "/repos/agoodkind/example/check-runs")
  let body = try JSONDecoder().decode(CheckRun.Payload.self, from: request.body)
  #expect(body.name == "Tests")
  #expect(body.headSha == "abc123")
  #expect(body.conclusion == "failure")
}

@Test
func publishWithoutATokenIsANoOp() throws {
  unsetenv("GITHUB_TOKEN")
  try CheckRun.publish(name: "Tests", status: .queued, conclusion: nil, summary: nil)
}
```

- [ ] **Step 2: Run the tests, expect FAIL** (`CheckRun` undefined): `make test SWIFT_TEST_CMD='swift test --filter CheckRunTests'`
- [ ] **Step 3: Implement `CheckRun`** with `Payload: Codable` (snake_case keys via `CodingKeys`: `name`, `head_sha`, `status`, `conclusion`, `output {title, summary}`), synchronous `URLSession` POST with `Authorization: Bearer`, and the no-token early return. Then `CheckRunCommand` mapping options to the enum cases.
- [ ] **Step 4: Run the tests, expect PASS.** Same command.
- [ ] **Step 5: Commit** `Add check-run publisher for per-stage pull request checks` with the Claude trailer.

---

### Task 2: `verify-release` is a compile-bucket writer

**Files:**
- Modify: the compiling-gate set that feeds `CachePlan.Inputs.isCompileWriter`. Locate it with `swift-mk`'s cache command: read `Sources/SwiftMkCLI/CacheCommand.swift` and `Sources/SwiftMkCore/CacheService.swift`; the set currently contains `verify`, `build`, `test`, `lint-deadcode`, `deadcode`, `swiftcheck-extra`, `release-build` (per `docs/caching/overview.md`). Add `verify-release`.
- Test: the sibling of the existing writer-set test in `Tests/SwiftMkCoreTests/` (find it by filtering tests for `compile` writer names; extend in place, same fixture style).

**Interfaces:**
- Consumes: `CachePlan.compute` (unchanged).
- Produces: `gate: verify-release` on the setup-build-env action enables the compile bucket, key family `...-compile-<epoch>-deps-<hash>-verify-release-<runUnique>`.

- [ ] **Step 1: Extend the existing writer-set test** with `verify-release` expecting `compile-cache-enabled=true`; run, expect FAIL.
- [ ] **Step 2: Add the gate name to the set; run, expect PASS.**
- [ ] **Step 3: Update `docs/caching/overview.md`** writer list sentence to include `verify-release`.
- [ ] **Step 4: Commit** `Add verify-release to the compile-bucket writer gates`.

---

### Task 3: `swift-mk verify-release` lane orchestrator

**Files:**
- Create: `Sources/SwiftMkCore/VerifyRelease.swift`
- Create: `Sources/SwiftMkCLI/VerifyReleaseRunCommand.swift` (command name `verify-release`; the existing `VerifyReleaseCommand` in SwiftMkUpdate territory is `verify-release`? Check `SwiftMk.swift:24` lists `VerifyReleaseCommand.self` already. Read its `commandName` first; if it is `verify-release`, name the new command `orchestrate` under it or name this one `ci-verify-release`. Resolve the collision by reading, then keep ONE user-facing name and record it in the make target of Task 4.)
- Modify: `Sources/SwiftMkCLI/SwiftMk.swift` (register)
- Test: `Tests/SwiftMkCoreTests/VerifyReleaseOrchestratorTests.swift`

**Interfaces:**
- Consumes: `Shell` process-group spawning (`Sources/SwiftMkCore/Shell+ProcessGroup.swift`), `CheckRun.publish` (Task 1), `Output`.
- Produces: `VerifyRelease.run(config:) -> Int32` where

```swift
public struct LaneConfig {
  /// Serial stage: the verify build, then the release build, both make recipes.
  public var buildCommands: [String]
  /// CPU lane after the build stage: verify tests, then the lint gates.
  public var testLaneCommands: [String]
  /// Release lane after the build stage: sign/package/notarize steps.
  public var releaseLaneCommands: [String]
  /// Stage names for check publishing: build, tests, quality, release-dry-run.
  public var publishChecks: Bool
}
```

Behavior contract, each clause tested:
1. `buildCommands` run serially; a failure stops everything, publishes Build=failure, exits non-zero.
2. After the build stage, the two lanes run concurrently, each command list serial within its lane, every command spawned in its own process group.
3. A lane failure terminates the other lane's process group (SIGTERM, then SIGKILL after a grace period), publishes that lane's check as failure and the survivor's as cancelled, exits non-zero.
4. Both lanes green publishes Tests/Quality/Release dry run success and exits 0.
5. SIGINT/SIGTERM to the orchestrator kills both process groups, exit 130.
6. `publishChecks == false` (no token, forks) changes nothing but the publishing.

- [ ] **Step 1: Write the failing tests** with stub shell commands writing order markers to a temp file, mirroring the harness style of `Tests/SwiftMkCoreTests/ReleaseBuildGenerateOrderTests.swift` (temp dir, marker files, real processes). Cover: ordering (build before lanes), overlap (lane A `sleep 2; marker`, lane B marker immediately, assert B's marker exists before A finishes), kill-on-failure (lane A fails fast, lane B is a `sleep 30` whose process must be gone within the grace period), and exit codes.
- [ ] **Step 2: Run, expect FAIL.** `make test SWIFT_TEST_CMD='swift test --filter VerifyReleaseOrchestrator'`
- [ ] **Step 3: Implement** `VerifyRelease` on `Shell` process groups; no `DispatchQueue` sleeps in tests, poll with deadlines.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Falsify** by inverting the kill call behind a local edit, confirm the kill test fails, revert.
- [ ] **Step 6: Commit** `Add verify-release lane orchestrator`.

---

### Task 4: `swift.mk` combined target

**Files:**
- Modify: `swift.mk` (new target near `verify`), `swift-build.mk` reference only.

**Interfaces:**
- Consumes: the orchestrator CLI (Task 3 name), existing variables `SWIFT_VERIFY_BUILD_CMD`, `SWIFT_VERIFY_TEST_CMD`, `SWIFT_MK_RELEASE_BUILD_CMD`, `SWIFT_GENERATE_CMD`, `SWIFT_MK_SIGNING_PRELUDE`.
- Produces: `make verify-release` used by the workflow in Task 5.

- [ ] **Step 1:** Add the target: generation guard identical to `verify` (`swift-build.mk:149`) and `release-build` (`swift-release.mk`), then one orchestrator invocation receiving the lane commands via environment. The build stage is the verify build recipe then the release-build recipe, both through their existing `swift-mk build --command` forms so GateProof and the inline-gate skip are inherited verbatim; the test lane is the verify test command plus the lint gate chain `verify` runs today; the release lane is the release packaging/notarize steps `_release.yml`'s Build/Notarize jobs run, exposed as make variables so the workflow keeps owning secrets.
- [ ] **Step 2:** Behavior test in the `ReleaseBuildGenerateOrderTests` style: temp consumer includes the mk files with a fake engine binary; assert order file shows `generate`, `verify-build`, `release-build` before any lane marker.
- [ ] **Step 3: Run, expect PASS** after implementation; commit `Add verify-release make target wiring the lane orchestrator`.

---

### Task 5: `_ci.yml` combined-job mode

**Files:**
- Modify: `.github/workflows/_ci.yml` (new inputs; Verify job gains release steps), `.github/actions/ci-gate/action.yml` (forward inputs).

**Interfaces:**
- Consumes: existing inputs plus new `release-dry-run: boolean` (default false), `release-timeout-minutes: number` (default 60), and the release forwards `_release.yml` already names: `signing-identity-name`, `apple-team-id`, `notarize-pattern`, `install-provisioning-profile`, `dist-dir`, `build-target`.
- Produces: on `release-dry-run: true` and a non-fork pull request, the Verify macOS job additionally imports the Developer ID certificate (`import-signing-cert` action with `APPLE_DEVELOPER_ID_P12_*`), installs profiles (`install-provisioning-profile` with `APPLE_DEVELOPER_ID_PROFILE_BASE64`), exports the notary secrets, sets `gate: verify-release`, grants `checks: write`, passes `SWIFT_MK_CHECK_SHA: ${{ github.event.pull_request.head.sha }}`, and runs `make verify-release` instead of `make verify`. Fork or Dependabot: `release-dry-run` is forced false and the job runs plain `verify`; the workflow publishes `Release dry run` as skipped via `swift-mk check-run`.
- The docs-only skip path (Linux no-op) publishes all four stage checks green.

- [ ] **Step 1:** Add inputs and the conditional step changes; keep the two-step local/remote action split the file already uses.
- [ ] **Step 2:** Validate with `actionlint` if present, else `swift-mk`'s workflow checks; run `make check`.
- [ ] **Step 3: Commit** `Add release dry run mode to the reusable CI verify job`.

---

### Task 6: Engine adopts the combined job

**Files:**
- Modify: `.github/workflows/ci.yml` (enable `release-dry-run: true`, forward its release inputs), `.github/workflows/release.yml` (delete the `pull_request` trigger, the pull-request concurrency cancel expression collapses to `false`, delete the `release-dry-run` gate job).

- [ ] **Step 1:** Make both edits; the engine's ruleset switch (required checks to the four stage names) happens with the merge, recorded in the PR description.
- [ ] **Step 2:** `make check`; commit `Run the release dry run inside CI's verify job on pull requests`.
- [ ] **Step 3:** Open the engine PR. Its own run is live proof one: verify in the log every line the spec's "Invariants preserved" section names (one verify build; `--skip-build` test; `swift-mk build --command` entries; `Cache saved with key ...verify-release-`; no lint tool in the release lane; check runs visible on the PR). Paste each as evidence in the PR before merge.

---

### Task 7: Docs

**Files:**
- Modify: `docs/ci/overview.md` (combined job, named checks, one macOS job per pull request), `docs/caching/overview.md` (done in Task 2), `AGENTS.md` only if a durable agent rule changes (none expected).

- [ ] **Step 1:** Rewrite the affected sections as current state per the writing rules; commit `Document the one-runner verify-release job`.

---

### Task 8: Consumer rollout, one probe each

Order: macos-fan-curve, stickies-improved, macos-smc-fan, lmd, iphone-cell-tunnel. For each:

- [ ] **Step 1:** Probe PR pinning the engine ref (the #218 pattern), switching `ci.yml` to `release-dry-run: true` with that repo's release inputs and deleting `release.yml`'s `pull_request` trigger.
- [ ] **Step 2:** Verify from the probe's logs: exactly one macOS job in the run list; four named checks; release lane held before publish; cache save under `verify-release`; wall clock within a few minutes of the repo's previous parallel time. lmd additionally sets `release-timeout-minutes` above its measured 56-minute verify.
- [ ] **Step 3:** Switch the repo's ruleset required checks to the stage names, merge the workflow change, close the probe unmerged, remove the worktree.
- iphone-cell-tunnel rides on #113 landing first (Developer ID signing fix in flight).

---

## Self-review notes

- Task 3 carries a known open point: the `VerifyReleaseCommand` name collision must be resolved by reading `SwiftMkCLI` before picking the CLI name; the make target name `verify-release` is fixed regardless.
- Spec coverage: stage graph (T3/T4), named checks (T1/T5), cache writer (T2), fork/skip behavior (T5), main-push untouched (T6 deletes only the pull_request trigger), timeout (T5/T8), rollout with probes (T6/T8). GOALS.md line 3's wording change (release reuse becomes same-machine) is the owner's file; flag at rollout, do not edit it.
