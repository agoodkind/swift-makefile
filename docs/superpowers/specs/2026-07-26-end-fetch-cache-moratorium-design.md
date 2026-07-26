# swift-mk: validated snapshot reuse behind a delegating bootstrap

Date: 2026-07-26
Status: awaiting review
Target: `agoodkind/swift-makefile`
Peer: go-makefile takes the same treatment. See its own spec.

## Problem

Three defects sit in the fetch path.

**The engine snapshot never refreshes.** `swift.mk:217` treats the snapshot as
current when `.make/.swift-mk-snapshot-ref` equals `SWIFT_MK_API_REF`, and
`swift.mk:182` writes the ref name into that marker. With the default pin of
`main` the comparison is `main` against `main`, true on every parse forever, so
a consumer stays on whatever commit it first extracted until someone runs
`swift-mk-sync`, `smoke-fetch`, or the fleet update.

The comment at `swift.mk:210` gives the intent: skip the re-extract so file
mtimes stay stable and the tool-binary staleness guard does not force a rebuild.
That goal is sound. Ref-name equality was standing in for "content unchanged",
which it cannot disprove for a moving branch.

**A warm parse refetches files it already has.** `swift.mk:290-311` fetches
`.swiftlint.yml`, `.swift-format`, `.periphery.yml`, `osv-scanner.toml`, and
`mise.toml` over the network on every parse, under renamed targets, even though
the snapshot already extracted all five into `.make`. `bootstrap.mk:155` fetches
`swift.mk` unconditionally as well, and each `SWIFT_MK_MODULES` entry costs its
own request. A warm parse spends six to eight sequential round trips retrieving
content already on disk.

**Nothing is reused when the network fails.** Every fetch is fail-loud, so an
unreachable GitHub means a consumer cannot parse its Makefile even with a
complete and recent `.make`. The failure is at least clean: `_swift_mk_fetch`
writes to a temp file and moves it into place only on success, so `.make` is
never damaged. go-makefile's equivalent is destructive; swift-makefile's is not.

## What makes reuse safe

`codeload.github.com` returns an `ETag` on the tarball, and a request carrying
`If-None-Match` returns `304` with an empty body. The `ETag` is a content hash,
so it answers "is the extracted tree still byte-identical to upstream" directly,
which is the question both the freeze and the reuse need answered.

Measured on 2026-07-26 over a link with 201ms average round trip time to
`codeload.github.com`:

| request | result | time | bytes |
| --- | --- | --- | --- |
| `tar.gz/main` with `If-None-Match` | `304` | 0.76-1.18s, median 0.88s | 0 |
| `tar.gz/main` cold | `200` | 2.06s | 320,665 |
| `git ls-remote` as a separate probe | sha | 1.63-1.77s | n/a |

The cost is round trip bound at roughly 4.3 RTT plus DNS, so the same `304`
should land near 0.1-0.2s on a 20ms link. A separate probe costs about as much
and still needs the download afterward, so one conditional request is both the
question and the fetch.

The `ETag` preserves the mtime-stability goal exactly. A `304` performs no
extract, so nothing under `.make` is touched. A `200` means content genuinely
moved, where a rebuild is correct.

## Consumer cost

Fetched files reach consumers on their next run at no cost. `bootstrap.mk` does
not: consumers commit it, `swift-mk-fleet-update.sh` copies the canonical file
into each consumer and validates with `make help`, and each consumer still needs
a reviewed and merged PR. The fleet is seven repositories.

Most of this design would land free, since `bootstrap.mk` fetches only
`swift.mk`. The `bootstrap.mk` change is taken deliberately anyway, to make this
the last such PR round for fetch behavior and to let a consumer parse offline.

## Goals

- A consumer tracking `main` picks up an engine change on its next parse,
  without a maintainer-run sync.
- A parse whose upstream has not moved transfers zero asset bytes and touches no
  file under `.make`.
- A warm consumer parses with no network at all.
- Serving disk after a failed validation is bounded, loud, and never in CI.
- After this change, a fetch-policy change requires no consumer PR.
- No new user-facing variable. `SWIFT_MK_SKIP_FETCH` stays the only knob.

## Non-goals

- Changing dev-dir mode. With `SWIFT_MK_DEV_DIR` set the build reads the
  checkout directly and never downloads, and the `dev-<sha>` marker keeps its
  meaning.
- Changing what `snapshot_clear_engine` preserves, or the flat `.make` layout.
- A shared cross-worktree cache. Each worktree's `.make` is its own store.
- Deleting `swift.mk`'s current fetch machinery in this change. It stays for
  mixed-version parses and is removed in a later cleanup.

## Design

### The delegating bootstrap

`bootstrap.mk` keeps its variables and its trace header, obtains one helper
script, runs it, and includes `swift.mk`. It holds no fetch policy beyond
obtaining the helper:

```
SWIFT_MK_BOOTSTRAP := .make/scripts/swift-mk-bootstrap.sh
```

Obtaining the helper is the only fetch rule left in consumer-committed code: a
dev override, then an existing copy, then one fetch, and a loud failure only when
the helper is absent and unreachable. It never deletes an existing helper, so a
cold offline start is the single unavoidable hard failure, and that case cannot
work under any design.

The helper URL derives from `SWIFT_MK_API_REPO` and `SWIFT_MK_API_REF` rather
than from `SWIFT_MK_BASE_URL`, whose value ends in `/main` and would pin a
ref-pinned consumer's helper to `main`. `SWIFT_MK_BASE_URL` remains honored as an
override.

The trace header in `swift_mk_trace_min` (`bootstrap.mk:70`) stays inline. It is
self-contained by design, needs no fetch, and must print before any other work.

### The helper must not delete itself mid-run

The helper lives at `.make/scripts/swift-mk-bootstrap.sh`, inside the tree that
`snapshot_clear_engine` clears and the extract replaces. A running bash script
whose file is replaced under it can misread its own remaining bytes.

The helper therefore copies itself to a temporary path and re-executes from
there before touching `.make`, so the file it is reading is never the file it is
replacing. The extract itself also stages first, so `.make` is only modified once
a complete tree exists.

### One extraction provisions everything

The helper extracts one tarball into a staging directory, verifies the required
assets are present there, and only then replaces the tree under `.make`. From
that one extraction it provisions `swift.mk`, the engine sources, the scripts,
the modules, and the renamed configs:

| source in the snapshot | target |
| --- | --- |
| `.swiftlint.yml` | `.make/swiftlint.yml` |
| `.swift-format` | `.make/swift-format.json` |
| `.periphery.yml` | `.make/periphery.yml` |
| `osv-scanner.toml` | `.make/osv-scanner.toml` |
| `mise.toml` | `.config/mise/conf.d/swift-mk.toml` |

Each `SWIFT_MK_MODULES` entry arrives in the same snapshot and is placed the same
way. Every per-file network fetch on the warm path disappears.

`swift-mk-fetch-path` stays for dev-dir mode, where no snapshot extract runs and
the checkout is the source, and as the fallback when a snapshot lacks a file.

### Snapshot state

`.make/.swift-mk-snapshot-ref` keeps its filename, so `snapshot_clear_engine`
(`scripts/swift-mk-sync.sh:24`) preserves it unchanged, and grows from a bare ref
name to three fields: the resolved ref, the codeload `ETag`, and the Unix
timestamp of the last successful validation or extract.

A marker holding only a ref name is what the current engine writes. The new
engine reads it, finds no `ETag`, treats the state as absent, provisions
unconditionally, and rewrites the marker in the new format. Every frozen consumer
therefore unfreezes on its first parse after this lands, exactly once.

A `dev-<sha>` marker keeps its meaning and is never validated against upstream.

### The decision table

"Assets" means `.make/Package.swift` plus every required file, present and
non-empty.

| state | assets | conditional GET | action |
| --- | --- | --- | --- |
| `SWIFT_MK_SKIP_FETCH=1` | present | not attempted | serve disk, unchanged from today |
| missing or no `ETag` | any | unconditional | full provision, fail loud on failure |
| present | incomplete | unconditional | full provision, fail loud on failure |
| present | present | `304` | serve disk, refresh the timestamp, no extract |
| present | present | `200` | stage, verify, replace, record the new `ETag` |
| present | present | timeout or error, state at most 1 hour old | serve disk, print one warning |
| present | present | timeout or error, state over 1 hour old | force the full provision, fail loud on failure |

The validation request carries `--connect-timeout 2 --max-time 3`. The measured
`304` uses 0.88s of that on a 201ms link and roughly 0.2s on a fast one, so
ordinary latency never reaches the cap and only genuine breakage lands in the
timeout rows.

One hour bounds how far a serve can drift from upstream. A developer whose
network drops mid-session keeps working; a checkout that has not validated since
before a break forces a real fetch and fails loud rather than compiling against
old engine sources.

The warning names what is served and how old it is, on one line:

```
swift-mk: upstream unreachable; serving the .make snapshot validated 12m ago (etag 4aeaf3db). Set SWIFT_MK_SKIP_FETCH=1 to silence, or check network access to codeload.github.com
```

`gh api tarball` stays the first tier for the unconditional provision, since it
works for a private fork. The conditional validation request uses `curl` against
codeload directly, because the reuse decision needs the `ETag` and both engine
repos are public.

### CI never serves disk

A real GitHub Actions run is `GITHUB_ACTIONS=true` with a non-empty
`GITHUB_RUN_ID`, the test `Build.runsInlineGates`
(`Sources/SwiftMkCore/Build.swift:29`) already uses and documents.

Under that condition the helper neither reads nor writes state, makes no
conditional request, and provisions unconditionally with fail-loud. CI adds no
latency and no new failure mode.

### swift.mk during and after migration

A consumer with an old `bootstrap.mk` and a new `swift.mk` must still parse, so
`swift.mk` keeps its snapshot and per-file fetch paths. It skips them when the
helper already provisioned this run, which it detects from the state the helper
wrote, and otherwise behaves as it does today with the freeze fixed.

`make help` keeps its current fast path and performs no validation request.

Once the fleet has migrated, the superseded machinery in `swift.mk` is removed.
That cleanup is deliberately not part of this change.

## Error handling

- A marker that is unparseable or lacks an `ETag` is treated as absent, so the
  run takes the cold path rather than trusting a value it cannot read.
- A `304` whose assets are incomplete is treated as a miss and forces the
  unconditional provision, so validation can never bless a partial `.make`.
- The marker is written only after the tree is in place, so an interrupted
  provision cannot leave a recent timestamp over a broken tree.
- A future timestamp, which a backwards clock produces, is treated as stale and
  forces the provision.
- The helper re-executes from a temporary copy before modifying `.make`, so
  replacing it mid-run cannot corrupt the running process.

## Testing

The decision logic runs at parse time before the `swift-mk` binary exists, so it
is shell, and the tests exercise it the way `SnapshotClearEngineTests` already
exercises `snapshot_clear_engine`: source the script, call the function against a
temp directory, assert the observable result.

A local HTTP server serves a real tarball, returns a genuine `ETag`, and honors
`If-None-Match`. A temp consumer repo with a committed `bootstrap.mk` runs `make`
against it with `SWIFT_MK_API_REPO` and `SWIFT_MK_BASE_URL` pointed at the
server. Each case asserts what an operator would see: request count and response
codes, bytes transferred, which files under `.make` changed content or mtime,
exit status, and warning text.

- Cold: no `.make`, one `200`, snapshot extracted, marker written with an `ETag`.
- Warm unchanged: one `304`, zero bytes, and no mtime change anywhere under
  `.make`, which is the rebuild-churn guarantee.
- Warm moved: the server advances the tarball, one `200`, the tree updates, the
  new `ETag` recorded.
- Unfreeze migration: a marker holding the bare string `main` with a complete
  `.make` still issues an unconditional request and rewrites the marker. This is
  the regression test for the freeze and must fail against today's `swift.mk`.
- Offline warm parse: server unreachable, marker stamped 10 minutes ago, the
  parse succeeds, one warning names the age, and `.make` is unchanged.
- Timeout stale: marker stamped 2 hours ago, the forced provision also fails,
  exit non-zero, no warning claiming a serve.
- CI: `GITHUB_ACTIONS=true` and `GITHUB_RUN_ID=1` with fresh state and complete
  assets still issues an unconditional request.
- Skip fetch: `SWIFT_MK_SKIP_FETCH=1` issues no request at all.
- Config provenance: a warm parse produces `.make/swiftlint.yml`,
  `.make/swift-format.json`, `.make/periphery.yml`, `.make/osv-scanner.toml`, and
  `.config/mise/conf.d/swift-mk.toml` with zero network requests, and their
  content matches the snapshot sources.
- Helper self-replacement: a `200` that ships a changed helper completes without
  error and leaves a valid helper on disk.
- Mixed version: an old `bootstrap.mk` with the new `swift.mk` still parses and
  provisions correctly.

`make smoke-fetch` keeps its meaning as the cold-path completeness proof and
gains no new responsibility.

## Rollout

1. Land the helper, `swift.mk`, and `scripts/swift-mk-sync.sh`. All are fetched,
   so every consumer gets the freeze fix, the validated reuse, and the config
   copies on its next parse, with no PR.
2. Land `bootstrap.mk`, run `update-consumers`, and merge the resulting PRs. This
   is the round that lets a warm consumer parse offline.
3. Later, once every consumer has migrated, remove the superseded fetch
   machinery from `swift.mk`.

Step 1 causes every consumer to re-extract once, since their markers hold a bare
ref name. That is the intended unfreeze and moves each consumer to current
`main`, so it should land when the engine is known good rather than alongside
other risky changes.

## Files touched

- `scripts/swift-mk-bootstrap.sh` (new; the helper, owning the decision table,
  staged provisioning, the marker, and the CI rule)
- `bootstrap.mk` (delegate to the helper; keep variables, the trace header,
  helper acquisition, and the include)
- `swift.mk` (marker format and the freeze fix; skip provisioning when the helper
  already ran; configs and modules from the snapshot)
- `scripts/swift-mk-sync.sh` (write the marker's new format in `snapshot_extract`)
- `docs/fetch/overview.md` (the reuse rule and the validation contract, as
  current-state behavior)
- tests for the decision table
