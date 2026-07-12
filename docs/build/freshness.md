# Build freshness

`make build` does no work when the tracked inputs and the built product are unchanged since the last successful build. A repeated `make build`, or a `make run` that depends on it, prints an up to date line and returns at once. The engine owns the freshness decision and ships it to every consumer with no consumer edit.

## What counts as unchanged

The last successful build writes a record at `.make/.build/last-success`, and the next build is fresh only when all of these still hold. [`BuildFreshness`](../../Sources/SwiftMkCore/BuildFreshness.swift) owns the record and the decision, and [`BuildFreshnessTests`](../../Tests/SwiftMkCoreTests/BuildFreshnessTests.swift) locks each case below.

The source set is compared with a two-tier digest. The fast path hashes each tracked file's path, size, and modification time, so an untouched tree is judged fresh without reading any file body. When mtimes have changed but the bytes have not, a second digest reads the contents and still reports fresh, so a checkout or a no-op formatter pass that only flips mtimes does not force a rebuild.

A config key folds in the build command, the generate command, the configuration, and every signing knob, so changing one through a tracked file such as a local xcconfig or the Makefile rebuilds even when no other source changed. The make recipe passes the key through an exported environment variable, so a value with an apostrophe cannot break the build command's shell parse.

Every declared product path must still exist on disk, so a deleted app bundle rebuilds. [`swift-app.mk`](../../swift-app.mk) declares the built `.app`. A plain SwiftPM consumer declares no product and relies on the source digest alone.

## How the make guard works

`build` depends on the record file, so make re-runs the recipe only when an input is newer than the record. The input list is defined in [`swift-build.mk`](../../swift-build.mk).

The input list names source files and every non-pruned directory. A directory is a prerequisite because adding, deleting, or renaming a child bumps that directory's mtime, so a pure deletion still re-runs the recipe even though the deleted file simply vanishes from a file-only list. The pruned directories match the engine's own digest exclusions, so make and the binary agree on the file set and a large build output tree is never walked.

`swift-mk-bin` is an order-only prerequisite, so the always-out-of-date binary target still runs before the recipe but does not force the record stale on every invocation. A real rebuild of the engine binary changes its file mtime, which is a normal input, so a binary upgrade still invalidates.

When the recipe runs, it consults `swift-mk build-fresh check`. On a fresh verdict it prints the up to date line and touches the record, so a content-identical mtime churn resets the stamp and the next run is a pure make no-op with no recipe at all. On a stale verdict it runs the full build chain, then `swift-mk build-fresh record` writes the new record.

## Forcing a build or turning the no-op off

`make build FORCE=1` always runs the full build. `make build SWIFT_MK_BUILD_FRESH=0` disables the no-op for that run. `make clean` removes the record, so the next build always runs.

## Known limits

A config value passed only on the make command line, such as `make build CODE_SIGN_IDENTITY=...` with no file edited, is not detected on its own. The record is compared only when a tracked file or directory changes, and a command-line variable changes nothing on disk. The same value set in a tracked xcconfig or Makefile, or a following `make clean`, rebuilds. Continuous integration is unaffected, since a fresh checkout has no record.

A tracked source path that contains a space is not supported by the freshness input list, because make separates prerequisites on spaces. A repo with such a path sets `SWIFT_MK_BUILD_FRESH=0`.

A content change that preserves both a file's size and its modification time is judged fresh, because the content digest runs only when the mtime digest differs. This is the standard make freshness model.

A plain SwiftPM consumer that removes `.build` by hand without `make clean` can no-op while the product is gone, because it declares no product path and the source digest still matches. Running `make clean`, or changing any tracked input, rebuilds.

A fresh no-op skips the whole build chain, including the optional signature verification that an unchanged `make build` ran every time before. A tampered signature on an otherwise unchanged product is re-checked on the next real rebuild, not on a fresh no-op.
