# One runner per pull request: Verify and the release dry run share a Mac

A pull request today occupies two macOS runners at once: CI's Verify job and the
Release workflow's signed dry run start in parallel on the same push. The
account has four runners total, so one pull request can consume half the fleet,
and the two jobs cannot share compiled work because each runs on its own
machine and reads the cross-run cache before the other has saved.

This design merges the two into one macOS job per pull request. The job runs
its compiles first on one shared local cache, then runs tests and lint gates on
the CPU while the release lane signs, waits on notarization, and packages. The pull request still shows
separate named checks per stage. Merges to main are untouched.

## Decision drivers

- Four runners account-wide. De-parallelizing across machines is the goal; a
  pull request should occupy one macOS slot.
- Measured on macos-fan-curve (runs 31358784645 and 31358784510, one commit):
  Verify ran 13m20s and the release build ran 3m15s in parallel on separate
  machines. The release build restored a previous release run's compile pile,
  not the same commit's Verify pile, because Verify had not saved when the
  release started reading. Same-machine execution removes the handoff entirely.
- Notarization is mostly idle network wait, and tests are pure CPU, so the two
  overlap on one machine without contending.
- The owner accepts that a test failure no longer prevents the release lane
  from having run; both must pass for the pull request to go green.

## The one job, stage by stage

1. **Build.** The verify build runs first (product plus test targets), then
   the release build immediately after on the same machine. Both go through
   the engine's build chokepoints, so the second compile replays the local
   compilation cache the first just filled. The two CPU-heavy compiles stay
   serialized; nothing else runs yet.
2. **Fork into two lanes.**
   - **Test lane (CPU):** the verify test command against the built tree, then
     the source-only lint gates (SwiftLint, Format, Complexity, Swiftcheck
     Extra, Audit).
   - **Release lane (mostly idle):** sign the release build, submit for
     notarization and wait, staple, package, and run the appcast dry run.
     Publish and smoke never run on a pull request, exactly as the `ephemeral`
     input holds them back today.
3. **Join.** The job succeeds only when both lanes succeed. When one lane
   fails, the orchestrator terminates the other lane's processes, reports
   which stage failed, and fails the job.

The orchestrator is engine-owned Swift in swift-mk, not shell in a workflow:
it spawns the lanes, tracks their processes, kills the survivor on failure,
and traps termination so a cancelled job leaves no orphans.

## Named checks per stage

The job publishes one GitHub check run per stage on the head commit: **Build**,
**Tests**, **Quality**, **Release dry run**. Each reports pass or fail
independently in the pull request view, and branch rulesets can require any of
them by name. The job itself remains a check as well; requiring the published
stage checks replaces requiring today's `swift / Verify` and `Release (dry
run)` checks. Publishing needs `checks: write` on the job.

The docs-only skip is unchanged in effect: when the change detector reports
nothing to build or lint, the Linux no-op path reports every required stage
check green and no macOS runner is occupied.

## Cache

The cross-run cache remains the cold-start path and keeps its mechanism: the
compile bucket rolls per writer with sibling fallback. The combined job is one
writer, so each pull request saves one richer pile containing everything both
lanes compiled, instead of two overlapping piles from two machines. Within the
job no cache transfer happens at all; the lanes share the machine's own
compilation cache store on disk.

## What does not change

- **Push to main.** CI runs nothing there today and continues to run nothing.
  The release workflow keeps its `push` and `workflow_dispatch` triggers and
  its own single machine, publishing per `release-on-merge`.
- **Fork and Dependabot pull requests.** They cannot read signing secrets, so
  the release lane does not run for them; the job runs the build and test
  lanes only, and the Release dry run check reports skipped-for-fork exactly
  as the dry run gate reports today.
- **Pool routing.** The combined job routes through the same plan-runner
  action with the same hosted floor and retry pair. Pool runners keep their
  host-mount caching and skip the actions/cache steps as they do now.

## Runner budget: one macOS job per pull request, Linux is free

The whole pull request lifecycle uses exactly one macOS job. Extra Targets
does not keep a separate macOS job: a consumer's configured extra targets run
as additional stages inside the combined job's test lane, after the verify
tests, publishing their own named check. Everything that does not need Xcode
stays on `ubuntu-latest`, which does not count against the four-runner cap:
the change detector, the no-op skip aggregators, and the check-run
publishing. The lifecycle is: Linux change detection, then either the Linux
no-op (docs-only change) or the single macOS job, with Linux aggregators
reporting the named checks.

## What changes where

- **Engine.** The release stages (build, sign, notarize, package, appcast dry
  run) become a step sequence callable from the combined job and from the
  main-push release path, one home for the list so the two cannot drift.
  `_ci.yml` gains the combined job with the release inputs it must forward
  (signing identity and team variables, notarize pattern, provisioning,
  brew packages). swift-mk gains the lane orchestrator and the check-run
  publisher. The engine's own `release.yml` drops its `pull_request` trigger.
- **Consumers** (macos-fan-curve, stickies-improved, macos-smc-fan, lmd,
  iphone-cell-tunnel). Each `release.yml` drops its `pull_request` trigger;
  each `ci.yml` passes the release inputs it currently passes to
  `_release.yml`. One probe pull request per consumer verifies before merge.
- **Rulesets.** Each repository's required checks move from the old check
  names to the published stage names at the same time its workflows switch.
- **Timeout.** The combined job's ceiling is an input sized to build plus the
  longer lane. lmd's Verify alone measured 55m50s against the current
  60-minute default, so lmd sets a higher value; the others fit under the
  default with room.

## Failure semantics

- Test lane fails: release lane is killed mid-flight; Tests (and Quality if it
  failed) report the failure; Release dry run reports cancelled.
- Release lane fails: test lane is killed; Release dry run reports the failing
  stage; a missing lint binary in the release lane still means a gate ran
  where none should.
- Cancellation or timeout: the orchestrator's termination handling kills both
  lanes; no partial state is saved to the cross-run cache because the save
  step runs only on job completion.

## Invariants preserved, and the log line that proves each

The combined job changes topology, not the build path. Every compile still
enters through the engine's chokepoints, so the gate, cache, and module-mode
invariants ride along unchanged. The implementation must show each of these in
the probe run's job log before any consumer switches:

- **One compile tree; tests skip-build.** The verify build and test commands
  are unchanged; the test lane runs the configured skip-build test command
  against the tree the build stage made. Proof: the job log shows one verify
  build invocation and a test invocation carrying `--skip-build`.
- **Release reuse is local.** The release build runs on the machine whose
  compilation cache the verify build just filled. Proof: cache replay remarks
  in the release build's section of the log, with the `ci-diagnostics` label
  turning on `SWIFT_MK_SWIFTPM_CACHE_DIAGNOSTICS` as it does today; hit rate
  is read per package, cold then warm, from that log.
- **CAS fills and rolls.** The combined job is a compile-bucket writer under
  its own gate name in `CachePlan`'s writer list; the rolling per-attempt key
  and sibling-fallback restore keys are untouched. Proof: `Cache saved with
  key` carrying the new writer name at job end, and the next run's `Cache
  restored from key` naming it.
- **Gate proof, not values.** Both compiles run through `swift-mk build`
  exactly as the current Verify and release-build recipes do; the orchestrator
  invokes those existing make targets rather than new command strings, so
  GateProof ancestry and the inline-gate skip are inherited, and no new knob
  is introduced. Proof: the log shows the same `swift-mk build --command`
  entries the two jobs show today.
- **One module mode.** Both compiles are engine-mediated, so both are
  explicit-module-build against the same stores; no plain build touches the
  tree. Proof: absence of any non-chokepoint compile invocation in the log.
- **Release lane never lints.** The lint gates live only in the test lane's
  step list; the release lane's steps are the release stages verbatim. A lint
  binary missing in the release lane still fails loudly as a
  gate-ran-where-none-should defect.

## Rollout and verification

1. Land the engine change behind its own pull request, whose combined job is
   itself the first live verification.
2. Open one probe pull request per consumer pinning the engine ref, as the
   \#218 rollout did. Verify per consumer: one macOS job total, all stage
   checks published, release lane held back from publish, and the job's saved
   pile restored by the next run.
3. Switch each consumer's workflows and ruleset together, then close the
   probes unmerged.

Success is measured, not asserted: a pull request's run list shows one macOS
job; the stage checks appear by name; wall clock stays within a few minutes of
today's parallel time on fan-curve; the compile bucket saves once per pull
request and restores on the next.

## Out of scope

- The Developer ID provisioning replacement for iphone-cell-tunnel (ICT-20)
  stays an account action independent of this design. Until its
  `APPLE_DEVELOPER_ID_PROFILE_BASE64` secret carries Developer ID profiles
  instead of App Store profiles, that repository's release lane fails at
  signing for the already-diagnosed reason; the combined job changes where the
  failure appears, not what fixes it.
