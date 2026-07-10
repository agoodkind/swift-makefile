#!/usr/bin/env bash
#
# clean-fast-path-smoke.sh
#
# Asserts the clean-only fast path in bootstrap.mk: a `make clean` whose only goal
# is `clean` prints the trace header, skips fetching and including swift.mk (no
# network, no swift-mk build), and removes the engine-owned build dirs, while a
# goal list that names a build goal still loads the full engine.
#
# Runs against the engine checkout in dev mode (SWIFT_MK_DEV_DIR), so no network
# is touched. Exits non-zero on the first failed assertion.

set -euo pipefail

ENGINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR=""
OUTSIDE_DIR=""

cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
    if [[ -n "$OUTSIDE_DIR" && -d "$OUTSIDE_DIR" ]]; then
        rm -rf "$OUTSIDE_DIR"
    fi
}
trap cleanup EXIT INT TERM

fail() {
    printf 'clean-fast-path-smoke: FAIL: %s\n' "$1" >&2
    exit 1
}

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/swift-mk-clean-smoke.XXXXXX")" || exit 1

# A minimal consumer that includes the engine bootstrap in dev mode.
cat > "$WORK_DIR/Makefile" <<EOF
SWIFT_MK_DEV_DIR := $ENGINE_DIR
include $ENGINE_DIR/bootstrap.mk
EOF

# Pre-create the dirs the trivial clean should remove, so we can assert removal.
mkdir -p "$WORK_DIR/.build" "$WORK_DIR/.derived-data"

# 1. Clean-only run: header prints, swift.mk is never fetched, dirs are removed.
clean_log="$WORK_DIR/clean.log"
if ! make -C "$WORK_DIR" clean > "$clean_log" 2>&1; then
    cat "$clean_log" >&2
    fail "make clean exited non-zero"
fi

if ! grep -q '🔎 logs=.make/logs trace_id=' "$clean_log"; then
    cat "$clean_log" >&2
    fail "trace header did not print on clean"
fi

if [[ -e "$WORK_DIR/.make/swift.mk" ]]; then
    fail "clean-only fetched swift.mk (fast path did not skip the engine)"
fi

if [[ -d "$WORK_DIR/.build" ]]; then
    fail "clean did not remove .build"
fi

if [[ -d "$WORK_DIR/.derived-data" ]]; then
    fail "clean did not remove .derived-data"
fi

# 2. Guard: an out-of-checkout SWIFT_MK_DERIVED_DATA override is refused, not
#    deleted, so a stray `make clean SWIFT_MK_DERIVED_DATA=/some/path` cannot
#    `rm -rf` an arbitrary path.
OUTSIDE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/swift-mk-clean-outside.XXXXXX")" || exit 1
touch "$OUTSIDE_DIR/sentinel"
guard_log="$WORK_DIR/guard.log"
if ! make -C "$WORK_DIR" clean SWIFT_MK_DERIVED_DATA="$OUTSIDE_DIR" > "$guard_log" 2>&1; then
    cat "$guard_log" >&2
    fail "guarded clean exited non-zero"
fi

if [[ ! -e "$OUTSIDE_DIR/sentinel" ]]; then
    fail "clean removed an out-of-checkout SWIFT_MK_DERIVED_DATA (guard failed)"
fi

if ! grep -q 'refusing to remove SWIFT_MK_DERIVED_DATA' "$guard_log"; then
    cat "$guard_log" >&2
    fail "clean did not print the refusal for an out-of-checkout override"
fi

# 3. Guard: a build goal must NOT take the fast path, so parsing fetches swift.mk.
#    A dry run (-n) still evaluates the parse-time fetch without running recipes.
build_log="$WORK_DIR/build.log"
if ! make -C "$WORK_DIR" -n build > "$build_log" 2>&1; then
    cat "$build_log" >&2
    fail "make -n build exited non-zero"
fi

if [[ ! -e "$WORK_DIR/.make/swift.mk" ]]; then
    fail "build goal did not load the full engine (swift.mk not fetched)"
fi

printf 'clean-fast-path-smoke: PASS\n'
