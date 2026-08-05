# End the fetch cache moratorium: rollout state

Both engine repositories take the same change, and their consumer fleets are
rolled out together. This page is the one place that says where that rollout
stands. The per-repo design specs own the behavior and the constraints; the SDD
ledgers own the task-by-task history. Neither of those answers "what has actually
shipped", which is what this page is for.

Last updated 2026-07-29.

- go design: [specs/2026-07-26-end-fetch-cache-moratorium-design.md](specs/2026-07-26-end-fetch-cache-moratorium-design.md)
- go ledger: `.superpowers/sdd/2026-07-26-end-fetch-cache-moratorium/progress.md`
- swift design and ledger live at the same paths in `agoodkind/swift-makefile`.

## Phase state

| phase | what it delivers | go | swift |
| --- | --- | --- | --- |
| 0. Branch merge-ready | every review finding closed, gates green | in progress | in progress |
| 1. Merge the engines | validated reuse, one download per parse, non-destructive provisioning | not started | not started |
| 2. Consumer bootstrap round | offline parse, end of the destructive parse | not started, 16 repos | not started, 7 repos |
| 3. Remove superseded machinery | delete the old per-file fetch paths | not started | not started |

Phase 1 reaches every consumer on its next run with no consumer pull request,
because the helper, the engine makefile, and the scripts are all fetched. Phase 2
is the only phase that needs reviewed pull requests, 23 of them.

## What blocks phase 0

Nothing merges without a GPT subagent approval, and both repositories were
reviewed on 2026-07-29 with a NOT-READY verdict. Every finding below was
reproduced by execution rather than inferred, unless marked otherwise.

### go

| severity | finding | state |
| --- | --- | --- |
| Critical | a destination symlink under `.make` was followed, so provisioning wrote outside `.make` | fixed |
| Critical | a stored ETag proves upstream is unchanged but never verifies local bytes, so a locally modified asset survives a 304 | open |
| Important | the lock path depends on `TMPDIR`, so two parses can take different locks and interleave installs (inferred) | open |
| Important | every warm parse runs `chmod +x` on the cached helper, changing mode and ctime on a 304 | open |
| Minor | errexit suppression hides a failing `date`, giving an exit-0 provision with an empty timestamp | open |
| Minor | forwarding tests cover 2 of the 6 variables, so removing the other 4 stays green (inferred) | open |

### swift

| severity | finding | state |
| --- | --- | --- |
| Critical | an unchecked `find` could drop preserved runtime files, deleting a live `build.lock` while exiting 0 | fixed |
| Important | a 304 rewrites the renamed configs under `.make`, violating the writes-nothing rule | open |
| Important | the Make call sites still lose `GITHUB_ACTIONS`, `GITHUB_RUN_ID`, and `SWIFT_MK_CODELOAD_BASE` | open |
| Important | an unchecked ETag pipeline turns a command failure into a provision with no marker | open |
| Minor | the OSV mapping copies a file onto itself and warns falsely on every run | open |

Docs are also unwritten in both repositories: go Task 8 (`docs/fetch.md`) and
swift Task 7 (`docs/fetch/overview.md`, which still describes the old per-file
fetch).

## Gate state

Recorded from the most recent local run, not from CI.

| gate | go | swift |
| --- | --- | --- |
| build | not re-run since the symlink fix | exit 0 |
| lint | not applicable | exit 0 |
| tests | `ok cmd/go-mk` in 90.5s, per the reviewer | 597 of 597, plus swiftcheck's 14, green twice |

## The phase 1 risk worth naming

Landing phase 1 in swift forces exactly one re-extract per consumer, because
every consumer's marker still holds a bare ref name that the new engine treats as
absent. That is the intended unfreeze and moves all seven consumers to current
`main` at once. The design says to land it when the engine is known good rather
than beside other risky changes, which argues for closing every finding before
merging rather than merging on a partial fix.

## Standing rules this rollout runs under

- Nothing merges without a GPT subagent approval.
- Every pull request passes `make build` and `make test` locally first.
- Live validation against the real endpoint after any change to fetch behavior,
  and only after pushing, because a consumer fetches from the branch ref.
- Findings get fixed, not baselined or silenced.
