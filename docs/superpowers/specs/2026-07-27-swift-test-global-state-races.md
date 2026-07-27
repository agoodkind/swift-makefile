# Test global-state races in SwiftMkCoreTests

Date: 2026-07-27
Status: partially fixed by the commit this document accompanies

## What was wrong

Tests in this target failed intermittently, roughly 29 percent of full-suite
runs, with symptoms that looked unrelated to each other: spawns dying with
`getcwd: cannot access parent directories`, `launch /bin/sh: No such file or
directory`, a logging test reading another suite's root, and
`OutputCaptureTests` finding another suite's output in its capture buffer.

They share one cause. The target had **two disjoint serialization domains over
the same process-wide globals**, and neither knew the other existed.

Domain A, serialized by nesting under `EnvironmentSerialized`, a
`@Suite(.serialized)`:

- `CiChangedMergeBaseTests`, `CorrelationTests`, `LoggingTests`, `ShellTests`,
  `VersionMetaTests`

Domain B, serialized by `TestGlobalLock`:

- `GatedBuildHarness` and its users, `DeadcodeCoverage*`, `LintSourceSet`,
  `StructuredGate`, `OutputCapture`, `Toolchain*`, `CacheService`,
  `GitIgnoreBatch`, `ReleaseWorkflowContract`, `Swiftcheck`,
  `ShellForwardingCapture`

The two sets do not overlap. Each domain is internally exclusive, so a test from
Domain A and a test from Domain B run at the same time, and both write the
working directory and the environment.

## Evidence

A process sample is the wrong instrument for a race, because the race has
already completed by the time a failure is visible. The diagnosis instead came
from tracing every `chdir` and environment mutation with timestamps, then
hunting until a failure was captured live.

Working directory, recorded during a failing run: `CiChangedMergeBase` changed
directory while `GatedBuildHarness` was already inside its own root, then
"restored" the working directory to `GatedBuildHarness`'s temporary root rather
than the repository, because that is what it had saved on entry.

Environment, which is what actually failed the run:
`logDirectoryJoinsSwiftMkRootAcrossPackageSubdir` expected its own temporary
root and read `GatedBuildHarness`'s instead. `GatedBuildHarness` sets
`SWIFT_MK_ROOT` under `TestGlobalLock`; `Logging` reads it without that lock,
because it is in the other domain.

## What this commit does

Domain A takes `TestGlobalLock`, the same lock Domain B already uses, in the
bodies that mutate process-wide state. Only those bodies: `VersionMetaTests` has
26 tests and one of them touches the environment.

Verification used a structural invariant rather than a pass rate, since a pass
rate cannot distinguish a fixed race from a lucky run. The invariant is that no
Domain A working-directory change occurs inside a Domain B window, which is only
possible when the domains overlap. Traces before the change contained 1 and 2
violations; across 8 traced runs after it, 0.

Pass rate moved from 5 of 7 to 6 of 6. Wall clock is unchanged at about one
percent, mean 70s against a 69s baseline.

An earlier measurement of this change reported a 1.8x slowdown and a new
timeout. Both were artifacts of the tracing instrumentation writing a file on
every `chdir`, not of the lock, and neither survives with the instrument
removed.

## Still open

**The stdout capture race.** `Output.beginCapture` and `endCapture` in
`Sources/SwiftMkCore/Output.swift` hold a process-wide buffer and flag, so any
concurrent test calling `Output.log` lands in whatever capture is open. This
commit does not close it and cannot: the polluters take no lock and belong to
neither domain. Expect `OutputCaptureTests` to fail occasionally with another
suite's output in its buffer.

Do not delete that suite to make the failure go away. `Output.beginCapture` is
production API, called from `GateDisplay.runCaptured` at
`Sources/SwiftMkCore/GateDisplay.swift:129-131`, where the captured text becomes
the finding lines in every gate's report. Deleting the suite would drop real
coverage. Closing this properly means making the capture task-scoped rather than
global.

**Lock contention in `CiChangedMergeBaseTests`.** It now holds the global lock
across roughly a dozen git subprocesses. That is correct but lengthens the
critical section, and it is the first place to look if contention ever bites.
Note that contention surfaces as an unrelated-looking timeout, because a test
declaring `.timeLimit` measures wall clock from test start, which includes time
spent waiting for the lock.

## The durable fix

Locking is a workaround for a property of the production code: `Logging`
resolves its directory from `SWIFT_MK_ROOT`, `CiChanged` reads the working
directory, and the gate code reads both. While that holds, a test can only get
determinism by owning the whole process, so every such test serializes against
every other, and time-limited tests spend their budget waiting.

The durable fix is to let that code take the root and the working directory as
parameters rather than reading process-wide state, so tests can run in parallel
with per-test values and no lock at all. That is a production change and was
deliberately left out of scope here. The `Output` capture singleton points at
the same root cause.
