# Generic preflight rail

Date: 2026-06-10
Status: approved

## Problem

The engine briefly carried a metal-specific preflight (`Preflight.ensureMetal`, gated on `SWIFT_MK_PREFLIGHT_METAL=1`). That put one consumer's policy (lmd's Metal toolchain need) inside the shared engine, and the owner reverted it. The need is real: lmd's metallib build fails on a fresh machine because Apple ships the Metal toolchain as an on-demand Xcode component, and nothing ensures it anywhere today.

## Principle

Fleet-wide provisioning belongs in the engine; single-consumer needs belong to that consumer, composed from generic engine primitives. The engine owns the pattern and the secured execution rail; the consumer injects only data. No metal identifier, string, or flag may exist in the engine.

## Design

### Two consumer-injected commands

Named like the existing `SWIFT_BUILD_CMD` family, defaulting empty in `swift.mk`, exported to the engine process:

```make
SWIFT_PREFLIGHT_CHECK_CMD   # e.g. xcrun --find metal
SWIFT_PREFLIGHT_ENSURE_CMD  # e.g. "$(SWIFT_MK_BIN)" toolchain download-component MetalToolchain
```

### Rail semantics (engine-owned, generic)

- Both empty: the rail is inert, zero output, zero cost.
- Check set and passing: continue silently.
- Check fails and ensure is set: log that the check failed and the ensure is running, run ensure with output forwarded live, re-run check. Passing now: continue. Still failing: fail the chain loud with the check's verbatim output inline.
- Check fails and ensure is empty: fail loud immediately, verbatim check output inline (a pure requirement assertion).
- Check empty and ensure set: run ensure on every invocation (the consumer command must be idempotent); a failure fails the run loud.

### Placement

`Lint.runLint`'s prologue, after `Preflight.trustMise`, before `ensureGenerated`: the slot the reverted `ensureMetal` occupied. The chain is in-process, so the rail runs once per make run, and `runBuildCheck` wraps `runLint`, so both `make lint` and `make build` are covered. A rail failure is a preflight failure: identical reporting and identical interaction with the release-runner non-blocking behavior. No new bypass knob, no named flag.

### download-component primitive

`toolchain download-metal` is renamed to `toolchain download-component <name>`: the engine keeps the generic verb wrapping `xcodebuild -downloadComponent <name>` (consumers never name xcodebuild), and the component name becomes caller-supplied data. Nothing calls `download-metal` (lmd-dev's caller was deleted in lmd `bed2d35`), so there is no alias.

### lmd composition

lmd's Makefile deletes the inert `SWIFT_MK_PREFLIGHT_METAL := 1` and declares the two commands shown above. `xcrun` is not on the build-tooling ban list and the download routes through the engine binary, so the `build-tooling-audit` gate stays green.

## Out of scope

- Multi-requirement lists (one pair serves the one consumer that needs it; extend if a second need appears).
- Any engine knowledge of specific components.

## Verification

- Engine unit tests cover the full decision matrix (inert, pass, miss-ensure-pass, miss-ensure-still-miss, check-only fail, ensure-only).
- Engine `make build` exit 0 and `make test` green.
- lmd `make lint` passes through the rail live on a machine with the toolchain present.
- The other four consumers see zero behavior change (variables default empty).
- No new source file, so `SWIFT_MK_SCRIPT_FILES` is unchanged and the fetched tree still self-builds.
