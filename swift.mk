.PHONY: build deploy install clean help run generate lint lint-tools lint-swiftlint \
	lint-swiftlint-baseline lint-swiftlint-baseline-prune-fixed lint-swiftlint-baseline-remove-fixed lint-swiftlint-baseline-accept-new \
	lint-files lint-diff lint-format lint-complexity lint-complexity-baseline lint-complexity-baseline-prune-fixed lint-complexity-baseline-remove-fixed lint-complexity-baseline-accept-new fmt test analyze audit build-check check \
	lint-deadcode lint-deadcode-baseline lint-deadcode-baseline-prune-fixed lint-deadcode-baseline-remove-fixed lint-deadcode-baseline-accept-new \
	swiftcheck-extra swiftcheck-extra-baseline swiftcheck-extra-baseline-prune-fixed swiftcheck-extra-baseline-remove-fixed swiftcheck-extra-baseline-accept-new swiftcheck-extra-bin \
	baseline baseline-prune-fixed baseline-remove-fixed baseline-accept-new baseline-add-new \
	swift-mk-bin swift-mk-notice quality-guard lint-swiftlint-scope lint-swiftlint-baseline-scope lint-swiftlint-baseline-scope-accept-new \
	swift-mk-sync update-swift-mk smoke-fetch update-consumers update-consumers-dry-run log-audit install-hooks xcode-file-header

help:
	@printf '%s\n' 'Canonical entry points:'
	@printf '  %-40s %s\n' 'build' 'run build-check, then execute SWIFT_BUILD_CMD'
	@printf '  %-40s %s\n' 'build FORCE=1' 'force a full build, skipping the freshness no-op'
	@printf '  %-40s %s\n' 'build SWIFT_MK_BUILD_FRESH=0' 'disable the freshness no-op for this run'
	@printf '  %-40s %s\n' 'run' 'run build, then execute SWIFT_RUN_CMD'
	@printf '  %-40s %s\n' 'deploy' 'run build, then execute SWIFT_DEPLOY_CMD'
	@printf '  %-40s %s\n' 'install' 'alias for deploy'
	@printf '  %-40s %s\n' 'generate' 'execute SWIFT_GENERATE_CMD when configured'
	@printf '  %-40s %s\n' 'clean' 'remove .build and the engine DerivedData'
	@printf '  %-40s %s\n' 'check' 'alias for lint'
	@printf '  %-40s %s\n' 'lint' 'run every lint gate'
	@printf '  %-40s %s\n' 'build-check' 'run lint and audit'
	@printf '  %-40s %s\n' 'fmt' 'apply swift-format in place'
	@printf '  %-40s %s\n' 'test' 'execute SWIFT_TEST_CMD'
	@printf '  %-40s %s\n' 'analyze' 'run deadcode analysis and SWIFT_ANALYZE_CMD'
	@printf '  %-40s %s\n' 'audit' 'run dependency audit and SWIFT_AUDIT_EXTRA_CMD'
	@printf '\n%s\n' 'Consumer preflight rail:'
	@printf '  %-40s %s\n' 'SWIFT_PREFLIGHT_CHECK_CMD=...' 'assert a build requirement before the gate chain'
	@printf '  %-40s %s\n' 'SWIFT_PREFLIGHT_ENSURE_CMD=...' 'establish the requirement when the check misses'
	@printf '\n%s\n' 'Build caching:'
	@printf '  %-40s %s\n' 'SWIFT_MK_SWIFT_CACHE=auto|1|0' 'default local SwiftPM and Xcode cache policy'
	@printf '  %-40s %s\n' 'SWIFT_MK_SWIFTPM_CACHE=auto|1|0' 'override SwiftPM cache policy'
	@printf '  %-40s %s\n' 'SWIFT_MK_XCODE_CACHE=auto|1|0' 'override local Xcode compilation cache policy'
	@printf '  %-40s %s\n' 'SWIFT_MK_XCODE_CACHE_PREFIX_MAP=auto|1|0' 'remap absolute paths for cross-runner cache hits'
	@printf '  %-40s %s\n' 'SWIFT_MK_XCODE_CACHE_PATH=...|off' 'shared CAS store path, kept outside DerivedData'
	@printf '  %-40s %s\n' 'SWIFT_MK_XCODE_CACHE_DIAGNOSTICS=1' 'emit Xcode compilation cache diagnostic remarks'
	@printf '  %-40s %s\n' 'SWIFT_MK_SWIFTPM_CACHE_PATH=...' 'relocate the swift build compilation cache store (on by default, no opt-out)'
	@printf '  %-40s %s\n' 'SWIFT_MK_SWIFTPM_CACHE_DIAGNOSTICS=1' 'emit swift build compilation cache diagnostic remarks'
	@printf '  %-40s %s\n' 'SWIFT_MK_SWIFTPM_CACHE_ARGS=...' 'override shared SwiftPM cache flags'
	@printf '  %-40s %s\n' 'ccache/sccache' 'C-family cache tools; not Swift compilation caches'
	@printf '\n%s\n' 'Scoped iteration:'
	@printf '  %-40s %s\n' 'lint-diff' 'run scoped lint against staged Swift files'
	@printf '  %-40s %s\n' 'lint-files LINT_FILES=...' 'run scoped lint against listed files'
	@printf '\n%s\n' 'Lint sub-targets:'
	@printf '  %-40s %s\n' 'lint-tools' 'install or verify swift-format, SwiftLint, Periphery, and osv-scanner'
	@printf '  %-40s %s\n' 'lint-swiftlint' 'SwiftLint with baseline gate'
	@printf '  %-40s %s\n' 'lint-format' 'swift-format diff gate'
	@printf '  %-40s %s\n' 'lint-complexity' 'SwiftLint metrics with baseline gate'
	@printf '  %-40s %s\n' 'lint-deadcode' 'Periphery with baseline gate'
	@printf '  %-40s %s\n' 'swiftcheck-extra' 'custom SwiftSyntax analyzers with baseline gate'
	@printf '\n%s\n' 'Baseline maintenance (maintainer use, guarded by BASELINE_CONFIRM and BASELINE_TOKEN):'
	@printf '  %-40s %s\n' 'baseline' 'refresh the recorded baselines'
	@printf '\n%s\n' 'Pipeline maintenance:'
	@printf '  %-40s %s\n' 'swift-mk-sync / update-swift-mk' 'refresh swift.mk, helper scripts, configs, modules, and swiftcheck source'
	@printf '  %-40s %s\n' 'smoke-fetch' 'force a fetch-path smoke run'
	@printf '  %-40s %s\n' 'update-consumers' 'refresh every opted-in consumer repo'
	@printf '  %-40s %s\n' 'update-consumers-dry-run' 'show fleet update work without writes'

ifneq ($(strip $(MAKECMDGOALS)),help)

SWIFT_MK_BASE_URL ?= https://raw.githubusercontent.com/agoodkind/swift-makefile/main
SWIFT_MK_API_REPO ?= agoodkind/swift-makefile
SWIFT_MK_API_REF ?= main

# Print the trace header before any other work. The full trace logic lives once in
# scripts/swift-mk-trace.sh (a consumer bootstrap.mk prints its own minimal header
# inline instead). Resolve the script from the dev checkout, from the copy sitting
# next to this makefile (a bare `make -f swift.mk` with no SWIFT_MK_DEV_DIR), or
# from a fetched copy under .make/scripts, and run it; when none is present the
# header defers to a later stage rather than failing the run. The dev-dir wildcard
# is guarded so an empty SWIFT_MK_DEV_DIR does not resolve an absolute /scripts path.
SWIFT_MK_TRACE_SCRIPT := $(firstword \
	$(if $(strip $(SWIFT_MK_DEV_DIR)),$(wildcard $(SWIFT_MK_DEV_DIR)/scripts/swift-mk-trace.sh)) \
	$(wildcard $(dir $(lastword $(MAKEFILE_LIST)))scripts/swift-mk-trace.sh) \
	$(wildcard .make/scripts/swift-mk-trace.sh))
ifneq ($(strip $(SWIFT_MK_TRACE_SCRIPT)),)
ifeq ($(strip $(TRACEPARENT)),)
# No inbound trace this run, so mint one via the script. TRACEPARENT is empty in
# this branch, so no untrusted value is interpolated into this parse-time $(shell).
SWIFT_MK_TRACE_RESULT := $(shell bash "$(SWIFT_MK_TRACE_SCRIPT)")
ifeq ($(word 1,$(SWIFT_MK_TRACE_RESULT)),ok)
TRACEPARENT := $(word 2,$(SWIFT_MK_TRACE_RESULT))
TRACE_ID := $(word 3,$(SWIFT_MK_TRACE_RESULT))
SPAN_ID := $(word 4,$(SWIFT_MK_TRACE_RESULT))
SWIFT_MK_TRACE_ID := $(TRACE_ID)
SWIFT_MK_SPAN_ID := $(SPAN_ID)
endif
else
# bootstrap.mk already minted and printed the trace and set these make variables.
# make's export does not reach a parse-time $(shell), so bootstrap's value cannot
# arrive by env here; the make variable does. Adopt it directly, without re-running
# the script, so no second header prints and no untrusted value is ever passed to a
# shell (which would be a command-injection surface). Derive the ids from
# TRACEPARENT only if a caller set TRACEPARENT on its own.
TRACE_ID := $(if $(strip $(TRACE_ID)),$(TRACE_ID),$(word 2,$(subst -, ,$(TRACEPARENT))))
SPAN_ID := $(if $(strip $(SPAN_ID)),$(SPAN_ID),$(word 3,$(subst -, ,$(TRACEPARENT))))
SWIFT_MK_TRACE_ID := $(TRACE_ID)
SWIFT_MK_SPAN_ID := $(SPAN_ID)
endif
export TRACEPARENT TRACE_ID SPAN_ID SWIFT_MK_TRACE_ID SWIFT_MK_SPAN_ID
endif

SWIFT_MK_ENTRY_MAKEFILE := $(firstword $(MAKEFILE_LIST))
SWIFT_MK_ENTRY_BASENAME := $(notdir $(SWIFT_MK_ENTRY_MAKEFILE))
SWIFT_MK_RECURSIVE_MAKE := $(MAKE)
SWIFT_MK_RECURSIVE_MAKE_ARGS :=
ifeq ($(filter Makefile makefile GNUmakefile,$(SWIFT_MK_ENTRY_BASENAME)),)
SWIFT_MK_RECURSIVE_MAKE_ARGS := -f $(SWIFT_MK_ENTRY_MAKEFILE)
endif

SWIFT_MK_SELF := $(lastword $(MAKEFILE_LIST))
SWIFT_MK_SELF_DIR := $(patsubst %/,%,$(dir $(abspath $(SWIFT_MK_SELF))))

# A local swift-makefile checkout is consumed through SWIFT_MK_DEV_DIR. SwiftPM
# derives a path dependency's identity from its directory basename, and a consumer's
# Tools manifest names `package: "swift-makefile"`, so a checkout in a worktree named
# anything else (for example canonical-tuist-build) fails to resolve. Normalize the
# override to a symlink literally named swift-makefile under .make/dev so any checkout
# resolves. Skip when the basename is already swift-makefile (the main checkout, or an
# already-normalized re-entry), which also avoids linking the symlink to itself.
ifneq ($(strip $(SWIFT_MK_DEV_DIR)),)
ifneq ($(notdir $(patsubst %/,%,$(SWIFT_MK_DEV_DIR))),swift-makefile)
override SWIFT_MK_DEV_DIR := $(shell mkdir -p "$(CURDIR)/.make/dev" && ln -sfn "$(abspath $(SWIFT_MK_DEV_DIR))" "$(CURDIR)/.make/dev/swift-makefile" && printf '%s' "$(CURDIR)/.make/dev/swift-makefile")
endif
endif

# Consumer self-reference robustness, the same basename fix as SWIFT_MK_DEV_DIR but for
# a consumer pointing at its own repo. A nested SwiftPM package (a `Tools/` dev tool)
# reaches its own root with a path dependency, whose SwiftPM identity is the directory
# basename; in a worktree not named after the repo that identity is wrong and the
# nested package fails to resolve. swift-mk derives the canonical repo name from git
# (the common dir's parent, identical from the main checkout or any linked worktree)
# and creates `.make/dev/<name>` as a symlink to the repo root. A consumer then writes
# its self-reference as `.package(path: "../.make/dev/<name>")`, which resolves from any
# worktree with no env var to set. The swiftcheck-extra `fragile_package_path` rule
# enforces consumers use that symlink rather than a bare `..`.
# Only at the repo toplevel: a recursive `make -C <subdir>` (swift-mk's own swiftcheck
# build) has CURDIR set to the subdir while git still derives the repo name, which would
# point the symlink at the subdir and clobber the SWIFT_MK_DEV_DIR symlink of the same
# name. Gating on toplevel keeps the self-symlink a repo-root concern.
SWIFT_MK_REPO_NAME := $(notdir $(patsubst %/,%,$(dir $(abspath $(shell git -C "$(CURDIR)" rev-parse --git-common-dir 2>/dev/null)))))
SWIFT_MK_GIT_TOPLEVEL := $(shell git -C "$(CURDIR)" rev-parse --show-toplevel 2>/dev/null)
ifneq ($(strip $(SWIFT_MK_REPO_NAME)),)
ifeq ($(abspath $(CURDIR)),$(abspath $(SWIFT_MK_GIT_TOPLEVEL)))
SWIFT_MK_SELF_LINK := $(shell mkdir -p "$(CURDIR)/.make/dev" && ln -sfn "$(CURDIR)" "$(CURDIR)/.make/dev/$(SWIFT_MK_REPO_NAME)" && printf '%s' "$(CURDIR)/.make/dev/$(SWIFT_MK_REPO_NAME)")
endif
endif

SWIFT_MK_LOCAL_SCRIPT_DIR := $(if $(strip $(SWIFT_MK_DEV_DIR)),$(SWIFT_MK_DEV_DIR)/scripts,$(SWIFT_MK_SELF_DIR)/scripts)
SWIFT_MK_FETCHED_SCRIPT_DIR := $(CURDIR)/.make/scripts
SWIFT_MK_HELPER_DIR := $(if $(wildcard $(SWIFT_MK_LOCAL_SCRIPT_DIR)/swift-mk-build.sh),$(SWIFT_MK_LOCAL_SCRIPT_DIR),$(SWIFT_MK_FETCHED_SCRIPT_DIR))
SWIFT_MK_FETCH_SCRIPT := $(SWIFT_MK_HELPER_DIR)/swift-mk-fetch-one.sh
SWIFT_MK_BIN ?= $(CURDIR)/.make/swift-mk
SWIFT_MK_LOCAL_NOTICES := $(if $(strip $(SWIFT_MK_DEV_DIR)),$(SWIFT_MK_DEV_DIR)/notices.txt,$(SWIFT_MK_SELF_DIR)/notices.txt)
SWIFT_MK_NOTICES_FILE := $(if $(wildcard $(SWIFT_MK_LOCAL_NOTICES)),$(SWIFT_MK_LOCAL_NOTICES),$(CURDIR)/.make/notices.txt)

# Fetch the whole engine as one snapshot. The consumer path downloads the archive
# for the pinned ref (SWIFT_MK_API_REF) from GitHub and extracts it into .make with
# tar --strip-components=1, so the archive's top-level directory is dropped and the
# engine tree lands flat under .make. gh streams the tarball first, and a plain curl
# of the public codeload archive is the fallback, so no auth is required. A marker
# records the resolved ref for the idempotency check at the call site. Before the
# extract it clears the prior snapshot's engine files (keeping the generated logs,
# build lock, dev symlinks, and built binary), so a ref change or a migration from an
# old per-file .make cannot leave an orphaned source the new snapshot no longer
# defines. This runs before the swift-mk binary or any fetched script exists, so it
# stays inline shell with no fetched-script dependency.
define _swift_mk_snapshot_commands
	tmp=$$(mktemp -d) || exit 1; \
	ok=""; \
	if command -v gh >/dev/null 2>&1 && gh api "repos/$(SWIFT_MK_API_REPO)/tarball/$(SWIFT_MK_API_REF)" > "$$tmp/snapshot.tar.gz" 2>"$$tmp/err" && [ -s "$$tmp/snapshot.tar.gz" ]; then \
		ok=1; \
	elif curl -fsSL --connect-timeout 5 --max-time 60 "https://codeload.github.com/$(SWIFT_MK_API_REPO)/tar.gz/$(SWIFT_MK_API_REF)" -o "$$tmp/snapshot.tar.gz" 2>"$$tmp/err" && [ -s "$$tmp/snapshot.tar.gz" ]; then \
		ok=1; \
	fi; \
	if [ -z "$$ok" ]; then cat "$$tmp/err" >&2 2>/dev/null || true; rm -rf "$$tmp"; exit 1; fi; \
	find .make -mindepth 1 -maxdepth 1 ! -name logs ! -name build.lock ! -name swift-mk ! -name swift-mk.key ! -name swift-mk-build ! -name dev ! -name .swift-mk-snapshot-ref ! -name swift.mk ! -name '*.log' -exec rm -rf {} + 2>>"$$tmp/err" || true; \
	if ! tar -xz --strip-components=1 -C .make -f "$$tmp/snapshot.tar.gz" 2>>"$$tmp/err"; then cat "$$tmp/err" >&2 2>/dev/null || true; rm -rf "$$tmp"; exit 1; fi; \
	printf '%s\n' "$(SWIFT_MK_API_REF)" > .make/.swift-mk-snapshot-ref; \
	rm -rf "$$tmp"
endef

define swift_mk_snapshot
$(if $(filter ok,$(shell mkdir -p .make && if $(call _swift_mk_snapshot_commands) > .make/swift-mk-snapshot.log 2>&1; then printf ok; else printf fail; fi)),,$(error swift-makefile failed to fetch the engine snapshot for $(SWIFT_MK_API_REF); see .make/swift-mk-snapshot.log))
endef

define swift-mk-fetch-path
$(if $(filter ok,$(shell mkdir -p .make && if bash "$(SWIFT_MK_FETCH_SCRIPT)" "$(1)" "$(2)" "$(SWIFT_MK_DEV_DIR)" > .make/swift-mk-fetch.log; then printf ok; else printf fail; fi)),,$(error swift-makefile failed to fetch $(1)))
endef

define swift-mk-require-one
$(if $(wildcard $(1)),,$(error swift-makefile expected $(1); rerun without SWIFT_MK_SKIP_FETCH))
endef

# One engine snapshot replaces the per-file fetch. In consumer mode the whole
# engine tree extracts into .make and becomes the flat SwiftPM package the build
# compiles (.make/Package.swift, .make/Sources, .make/scripts, .make/swiftcheck),
# so a source added to the engine is present with no manifest to maintain, and the
# selected modules (SWIFT_MK_MODULES) arrive in the same snapshot. The extract is
# idempotent: the marker records the resolved ref, and a later run whose marker
# matches the pinned ref with a present .make/Package.swift skips the re-extract, so
# file mtimes stay stable and the tool-binary staleness guard does not force a
# rebuild. When a re-extract does run, it first clears the prior snapshot's engine
# files while preserving .make/logs, .make/build.lock, and the built binary, so an
# orphaned source cannot survive a ref change. Dev-dir mode is excluded here, because
# SWIFT_MK_HELPER_DIR then resolves to the checkout rather than .make/scripts and the
# build reads the checkout directly.
SWIFT_MK_SNAPSHOT_CURRENT := $(shell if [ -f .make/Package.swift ] && [ -f .make/.swift-mk-snapshot-ref ] && [ "$$(cat .make/.swift-mk-snapshot-ref 2>/dev/null)" = "$(SWIFT_MK_API_REF)" ]; then printf 1; fi)
ifeq ($(SWIFT_MK_HELPER_DIR),$(SWIFT_MK_FETCHED_SCRIPT_DIR))
ifeq ($(strip $(SWIFT_MK_SKIP_FETCH)),1)
SWIFT_MK_SNAPSHOT := $(call swift-mk-require-one,.make/Package.swift)
else ifneq ($(strip $(SWIFT_MK_SNAPSHOT_CURRENT)),1)
SWIFT_MK_SNAPSHOT := $(call swift_mk_snapshot)
endif
endif

SWIFT_MK_MODULES ?=

# Each selected module must sit at .make/$(m) so the `-include .make/$(m)` below
# resolves it. The snapshot extracts the modules in fetched mode, but it does not run
# in dev-dir mode, so fetch each one explicitly the same way the shared configs are
# fetched: swift-mk-fetch-path copies from the checkout under SWIFT_MK_DEV_DIR and
# downloads otherwise. The module list is the consumer's own small selection, not the
# whole engine source tree, so fetching it per file is not the manifest footgun the
# snapshot removed.
ifeq ($(strip $(SWIFT_MK_SKIP_FETCH)),1)
SWIFT_MK_FETCHED_MODULES := $(foreach m,$(SWIFT_MK_MODULES),$(call swift-mk-require-one,.make/$(m)))
else
SWIFT_MK_FETCHED_MODULES := $(foreach m,$(SWIFT_MK_MODULES),$(call swift-mk-fetch-path,$(m),.make/$(m)))
endif

SWIFT_MK_SWIFTLINT_CONFIG ?= .make/swiftlint.yml
SWIFT_MK_SWIFT_FORMAT_CONFIG ?= .make/swift-format.json
SWIFT_MK_PERIPHERY_CONFIG ?= .make/periphery.yml

# A consumer's own .swiftlint.yml / .swift-format / .periphery.yml is ignored in
# favor of the shared fetched config. Warn once at the top level so the override
# is visible. Set SWIFT_MK_ALLOW_LOCAL_CONFIGS to silence it.
SWIFT_MK_ALLOW_LOCAL_CONFIGS ?=
ifeq ($(strip $(SWIFT_MK_ALLOW_LOCAL_CONFIGS)),)
ifeq ($(MAKELEVEL),0)
ifneq ($(wildcard .swiftlint.yml),)
ifneq ($(abspath $(SWIFT_MK_SWIFTLINT_CONFIG)),$(abspath .swiftlint.yml))
$(warning swift-makefile: local .swiftlint.yml is ignored; shared SwiftLint config is $(SWIFT_MK_SWIFTLINT_CONFIG))
endif
endif
ifneq ($(wildcard .swift-format),)
ifneq ($(abspath $(SWIFT_MK_SWIFT_FORMAT_CONFIG)),$(abspath .swift-format))
$(warning swift-makefile: local .swift-format is ignored; shared swift-format config is $(SWIFT_MK_SWIFT_FORMAT_CONFIG))
endif
endif
ifneq ($(wildcard .periphery.yml),)
ifneq ($(abspath $(SWIFT_MK_PERIPHERY_CONFIG)),$(abspath .periphery.yml))
$(warning swift-makefile: local .periphery.yml is ignored; shared Periphery config is $(SWIFT_MK_PERIPHERY_CONFIG))
endif
endif
endif
endif
# swift-mk owns the OSV policy outright: the audit gate reads only the fetched,
# centrally-owned .make/osv-scanner.toml. override locks the config path and the
# scanner args (below) so a consumer cannot redirect them from the command line or
# environment, the same pattern LINT_GATES uses, and there is no root-osv-scanner.toml
# fallback. Manage every exception in swift-makefile's own osv-scanner.toml.
override SWIFT_MK_OSV_CONFIG := .make/osv-scanner.toml
# mise loads every file under .config/mise/conf.d/ automatically and has no
# env var for an arbitrary config path, so the shared tool pins fetch into
# that documented additive location. Consumers gitignore the fetched file and
# delete their root mise.toml / .tool-versions pins.
SWIFT_MK_MISE_CONFIG ?= .config/mise/conf.d/swift-mk.toml

# Default Xcode location for the rendered file-header macros. Override to a
# project's xcshareddata for a per-project header. swift-mk reads the git
# identity itself.
XCODE_TEMPLATE_DIR ?= $(HOME)/Library/Developer/Xcode/UserData

ifeq ($(strip $(SWIFT_MK_SKIP_FETCH)),1)
SWIFT_MK_FETCHED_SWIFTLINT := $(call swift-mk-require-one,$(SWIFT_MK_SWIFTLINT_CONFIG))
SWIFT_MK_FETCHED_SWIFT_FORMAT := $(call swift-mk-require-one,$(SWIFT_MK_SWIFT_FORMAT_CONFIG))
SWIFT_MK_FETCHED_PERIPHERY := $(call swift-mk-require-one,$(SWIFT_MK_PERIPHERY_CONFIG))
else
SWIFT_MK_FETCHED_SWIFTLINT := $(call swift-mk-fetch-path,.swiftlint.yml,$(SWIFT_MK_SWIFTLINT_CONFIG))
SWIFT_MK_FETCHED_SWIFT_FORMAT := $(call swift-mk-fetch-path,.swift-format,$(SWIFT_MK_SWIFT_FORMAT_CONFIG))
SWIFT_MK_FETCHED_PERIPHERY := $(call swift-mk-fetch-path,.periphery.yml,$(SWIFT_MK_PERIPHERY_CONFIG))
endif
ifeq ($(strip $(SWIFT_MK_SKIP_FETCH)),1)
SWIFT_MK_FETCHED_OSV := $(call swift-mk-require-one,$(SWIFT_MK_OSV_CONFIG))
else
SWIFT_MK_FETCHED_OSV := $(call swift-mk-fetch-path,osv-scanner.toml,$(SWIFT_MK_OSV_CONFIG))
endif

# swift.mk owns the shared mise config outright: it is fetched here, not by the
# consumer's tracked bootstrap.mk, so every consumer converges on its next run
# with no consumer-repo change. The top-level run fetches it once, which is how
# the SWIFT_MK_SKIP_FETCH=1 sub-makes consumers use for their inner builds find
# it already present; a strict skip-fetch run that genuinely lacks it gets the
# standard pre-fetch error.
ifneq ($(wildcard $(SWIFT_MK_MISE_CONFIG)),)
SWIFT_MK_FETCHED_MISE := 1
else ifeq ($(strip $(SWIFT_MK_SKIP_FETCH)),1)
SWIFT_MK_FETCHED_MISE := $(call swift-mk-require-one,$(SWIFT_MK_MISE_CONFIG))
else
SWIFT_MK_FETCHED_MISE := $(call swift-mk-fetch-path,mise.toml,$(SWIFT_MK_MISE_CONFIG))
endif

SWIFTLINT ?= swiftlint
SWIFTLINT_FLAGS ?= --config $(SWIFT_MK_SWIFTLINT_CONFIG) --reporter xcode
SWIFTLINT_TARGETS ?= Sources Tests Package.swift
SWIFTLINT_BASELINE ?= .swiftlint-baseline.jsonl
# Untracked files (generated output, scratch files) are skipped by the git-ignore
# filter in the lint runner, not by a path pattern: a path pattern would let a
# tracked file in a matching directory silently escape linting. A repo can still
# add explicit path patterns through SWIFTLINT_EXCLUDE_PATHS.
SWIFTLINT_DEFAULT_EXCLUDE_PATHS ?=
SWIFTLINT_EXCLUDE_PATHS ?=
SWIFTLINT_BASELINE_SCOPE_PATTERN ?=
RULE ?=

SWIFT_FORMAT ?= xcrun swift-format
SWIFT_FORMAT_TARGETS ?= $(SWIFTLINT_TARGETS)

COMPLEXITY_RULES ?= cyclomatic_complexity,function_body_length,closure_body_length,file_length,type_body_length,function_parameter_count,large_tuple,nesting,todo
SWIFTLINT_COMPLEXITY_BASELINE ?= .swiftlint-complexity-baseline.jsonl

PERIPHERY ?= periphery
PERIPHERY_ARGS ?= scan --config $(SWIFT_MK_PERIPHERY_CONFIG) --strict
PERIPHERY_BASELINE ?= .periphery-baseline.jsonl
PERIPHERY_DEFAULT_EXCLUDE_PATHS ?=
PERIPHERY_EXCLUDE_PATHS ?=

OSV_SCANNER ?= osv-scanner
override OSV_SCANNER_ARGS := --recursive --allow-no-lockfiles --config $(SWIFT_MK_OSV_CONFIG)

LINT_CONCURRENCY ?= auto

SWIFT_MK_XCODE_VERSION_MAJOR := $(shell xcodebuild_path=$$(command -v xcodebuild || printf ''); if [ -n "$$xcodebuild_path" ]; then version_output=$$("$$xcodebuild_path" -version 2>/dev/null); printf '%s\n' "$$version_output" | awk '/^Xcode / { split($$2, version_parts, "."); print version_parts[1]; exit }'; else printf 0; fi)
SWIFT_MK_SWIFT_CACHE ?= auto
SWIFT_MK_SWIFTPM_CACHE ?= $(SWIFT_MK_SWIFT_CACHE)
SWIFT_MK_XCODE_CACHE ?= $(SWIFT_MK_SWIFT_CACHE)
SWIFT_MK_XCODE_CACHE_DIAGNOSTICS ?= false
SWIFT_MK_XCODE_CACHE_AUTO_ENABLED := $(shell awk 'BEGIN { version = "$(SWIFT_MK_XCODE_VERSION_MAJOR)" + 0; if (version >= 26) print "YES"; else print "NO"; }')
SWIFT_MK_XCODE_CACHE_ENABLED := NO
ifneq ($(filter $(SWIFT_MK_XCODE_CACHE),1 true TRUE yes YES on ON),)
SWIFT_MK_XCODE_CACHE_ENABLED := YES
else ifneq ($(filter $(SWIFT_MK_XCODE_CACHE),0 false FALSE no NO off OFF),)
SWIFT_MK_XCODE_CACHE_ENABLED := NO
else ifneq ($(filter $(SWIFT_MK_XCODE_CACHE),auto AUTO),)
SWIFT_MK_XCODE_CACHE_ENABLED := $(SWIFT_MK_XCODE_CACHE_AUTO_ENABLED)
endif
# Prefix mapping rewrites absolute path prefixes (SDK, toolchain, source root) out of
# the compilation-cache keys so a cache entry produced on one machine or CI runner
# hits on another whose checkout path differs. Without it the keys embed absolute
# paths and every cross-runner restore misses. Defaults to the Xcode cache policy, so
# it follows caching on Xcode 26+ and a consumer can drop just the mapping (keeping the
# local cache) with SWIFT_MK_XCODE_CACHE_PREFIX_MAP=0 if a path-sensitive input (a
# bridging header) regresses.
SWIFT_MK_XCODE_CACHE_PREFIX_MAP ?= $(SWIFT_MK_XCODE_CACHE)
SWIFT_MK_XCODE_CACHE_PREFIX_MAP_ENABLED := NO
ifneq ($(filter $(SWIFT_MK_XCODE_CACHE_PREFIX_MAP),1 true TRUE yes YES on ON),)
SWIFT_MK_XCODE_CACHE_PREFIX_MAP_ENABLED := YES
else ifneq ($(filter $(SWIFT_MK_XCODE_CACHE_PREFIX_MAP),0 false FALSE no NO off OFF),)
SWIFT_MK_XCODE_CACHE_PREFIX_MAP_ENABLED := NO
else ifneq ($(filter $(SWIFT_MK_XCODE_CACHE_PREFIX_MAP),auto AUTO),)
SWIFT_MK_XCODE_CACHE_PREFIX_MAP_ENABLED := $(SWIFT_MK_XCODE_CACHE_AUTO_ENABLED)
endif
SWIFT_MK_XCODE_CACHE_DIAGNOSTICS_ENABLED := NO
ifneq ($(filter $(SWIFT_MK_XCODE_CACHE_DIAGNOSTICS),1 true TRUE yes YES on ON),)
SWIFT_MK_XCODE_CACHE_DIAGNOSTICS_ENABLED := YES
endif
SWIFT_MK_XCODEBUILD_ARGS := $(strip $(if $(filter YES,$(SWIFT_MK_XCODE_CACHE_ENABLED)),COMPILATION_CACHE_ENABLE_CACHING=YES $(if $(filter YES,$(SWIFT_MK_XCODE_CACHE_PREFIX_MAP_ENABLED)),SWIFT_ENABLE_PREFIX_MAPPING=YES CLANG_ENABLE_PREFIX_MAPPING=YES,) $(if $(filter YES,$(SWIFT_MK_XCODE_CACHE_DIAGNOSTICS_ENABLED)),COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS=YES,),))
SWIFT_MK_XCODEBUILD_NO_CACHE_ARGS := COMPILATION_CACHE_ENABLE_CACHING=NO COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS=NO
# Canonical DerivedData path. A consumer that builds Xcode targets routes its
# `xcodebuild -derivedDataPath` here, and the dead-code gate reads the index store
# from the same place, so coverage analysis is deterministic across repos.
SWIFT_MK_DERIVED_DATA ?= $(CURDIR)/.derived-data
# Normalize to absolute once, at the source. Some consumers set this to a relative
# value (BUILD_DIR, e.g. `build`), and a relative DerivedData leaks into build settings
# that xcodebuild resolves against a different base than the consumer cwd: the dead-code
# OBJROOT resolved a relative value against each SwiftPM package's source root, landing
# coverage intermediates inside the shared SPM clone where `rm -rf` could not clear them.
# Absolutizing the one exported variable makes every make and Swift reader relative-safe.
# `override` so a relative command-line value is absolutized too (a plain `:=` loses to a
# command-line assignment), matching the `override LINT_GATES` hardening pattern. abspath
# is lexical (no stat), a no-op on an already-absolute value, and points a relative value
# at the same physical dir the consumer cwd already implied, so packaging that reads
# BUILD_DIR is unaffected.
override SWIFT_MK_DERIVED_DATA := $(abspath $(if $(strip $(SWIFT_MK_DERIVED_DATA)),$(SWIFT_MK_DERIVED_DATA),$(CURDIR)/.derived-data))
# Shared build caches reused across every worktree and clone. DerivedData stays
# per checkout (above) so concurrent builds never collide. On hosted and local
# checkouts, the Clang module cache and SPM clone dir can both live under the
# shared cache root. Pool builds keep the SPM clone dir on the shared mount but
# move write-heavy package support and module-cache state under
# SWIFT_MK_POOL_LOCAL_CACHE.
SWIFT_MK_CACHE_ROOT ?= $(HOME)/Library/Caches/swift-mk
SWIFT_MK_MODULE_CACHE ?= $(SWIFT_MK_CACHE_ROOT)/ModuleCache
SWIFT_MK_SPM_CACHE ?= $(SWIFT_MK_CACHE_ROOT)/SourcePackages
export SWIFT_MK_MODULE_CACHE
export SWIFT_MK_SPM_CACHE
export SWIFT_MK_POOL
export SWIFT_MK_POOL_LOCAL_CACHE
# The LLVM compilation-cache (CAS) store. Kept OUTSIDE per-checkout DerivedData,
# unlike Xcode's default of $(SWIFT_MK_DERIVED_DATA)/CompilationCache.noindex, so the
# dead-code coverage build's `rm -rf $(SWIFT_MK_DERIVED_DATA)` cannot destroy it, and
# shared across worktrees and clones like the module cache (the store is
# content-addressed, so one shared copy is safe and maximizes reuse). The engine
# injects COMPILATION_CACHE_CAS_PATH from this at the toolchain chokepoint; set it to
# `off` to fall back to Xcode's in-DerivedData default.
SWIFT_MK_XCODE_CACHE_PATH ?= $(SWIFT_MK_CACHE_ROOT)/CompilationCache
export SWIFT_MK_XCODE_CACHE_PATH
# The shared LLVM CAS store for `swift build` compilation caching. Kept outside
# DerivedData and shared across worktrees (content-addressed), the SwiftPM peer
# of SWIFT_MK_XCODE_CACHE_PATH. The engine owns this cache with no consumer opt-out:
# a real path relocates the store, and a disable token (off/none/0/disabled) is treated
# as unset and resolves to the default store rather than turning caching off.
SWIFT_MK_SWIFTPM_CACHE_PATH ?= $(SWIFT_MK_CACHE_ROOT)/SwiftPMCompilationCache
export SWIFT_MK_SWIFTPM_CACHE_PATH
# SwiftPM compilation caching via -explicit-module-build -cache-compile-job. On by
# default, the SwiftPM peer of the Xcode compilation cache, engine-owned with no consumer
# opt-in or opt-out: the engine enables it whenever the toolchain supports the flag,
# detected from the frontend help with a Swift 6.3 version-floor fallback (the release
# where swift build compilation caching is available) so a change in the hidden-help text
# cannot wrongly disable it, and a toolchain that lacks it never receives the flags.
SWIFT_MK_SWIFTPM_COMPILE_CACHE_ENABLED := $(shell sc=$$(command -v swiftc 2>/dev/null || true); if [ -z "$$sc" ]; then printf 'NO'; elif "$$sc" -frontend -help-hidden 2>&1 | grep -q -- '-cache-compile-job'; then printf 'YES'; else v=$$("$$sc" -version 2>&1 | sed -n 's/.*Swift version \([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2/p'); set -- $$v; maj=$${1:-0}; min=$${2:-0}; if [ "$$maj" -gt 6 ] || { [ "$$maj" -eq 6 ] && [ "$$min" -ge 3 ]; }; then printf 'YES'; else printf 'NO'; fi; fi)
export SWIFT_MK_SWIFTPM_COMPILE_CACHE_ENABLED
# Exported so `toolchain generate` can point Xcode.app's DerivedData at the same path.
export SWIFT_MK_DERIVED_DATA
SWIFT_MK_SWIFTPM_CACHE_ENABLED := NO
ifneq ($(filter $(SWIFT_MK_SWIFTPM_CACHE),1 true TRUE yes YES on ON auto AUTO),)
SWIFT_MK_SWIFTPM_CACHE_ENABLED := YES
else ifneq ($(filter $(SWIFT_MK_SWIFTPM_CACHE),0 false FALSE no NO off OFF),)
SWIFT_MK_SWIFTPM_CACHE_ENABLED := NO
endif
SWIFT_MK_SWIFTPM_CACHE_ARGS_AUTO := $(if $(filter YES,$(SWIFT_MK_SWIFTPM_CACHE_ENABLED)),$(shell swift_path=$$(command -v swift || printf ''); if [ -n "$$swift_path" ]; then build_help=$$("$$swift_path" build --help || true); args=""; printf '%s\n' "$$build_help" | grep -q -- '--enable-dependency-cache' && args="$$args --enable-dependency-cache"; printf '%s\n' "$$build_help" | grep -q -- '--enable-build-manifest-caching' && args="$$args --enable-build-manifest-caching"; printf '%s\n' "$$build_help" | grep -q -- '--manifest-cache' && args="$$args --manifest-cache shared"; printf '%s\n' "$$args" | awk '{$$1=$$1; print}'; fi),)
SWIFT_MK_SWIFTPM_CACHE_ARGS ?= $(SWIFT_MK_SWIFTPM_CACHE_ARGS_AUTO)

SWIFT_MK_GATE_TOKEN_CMD ?= curl -fsSL "https://en.wikipedia.org/api/rest_v1/feed/featured/$$(date -u +%Y/%m/%d)" | jq -r '.tfa.titles.canonical'
BYPASS_LINT ?=
BYPASS_CONFIRM ?=
BYPASS_TOKEN_CMD ?= $(SWIFT_MK_GATE_TOKEN_CMD)
BASELINE_CONFIRM ?=
BASELINE_TOKEN ?=
BASELINE_TOKEN_CMD ?= $(SWIFT_MK_GATE_TOKEN_CMD)
BASELINE_UPDATE_MODE ?= sync

# Canonical Xcode-app build path. A consumer that builds an Xcode app declares only
# its generator, container, scheme, and configuration; swift-mk derives the build,
# test, generate, and coverage commands, all routed through the `swift-mk toolchain`
# chokepoint so no consumer Makefile names tuist/xcodegen/xcodebuild. Set
# SWIFT_XCODE_SCHEME to opt in; leave it empty for a plain SwiftPM package (the
# `swift build`/`swift test` defaults below apply).
SWIFT_XCODE_SCHEME ?=
SWIFT_XCODE_GENERATOR ?= tuist
SWIFT_XCODE_CONFIGURATION ?= Debug
# The engine coverage xcconfig sets ONLY_ACTIVE_ARCH=YES so the dead-code
# coverage build avoids the cross-arch module race that a universal
# build-for-testing hits on a multi-module test target.
SWIFT_XCODE_COVERAGE_CONFIGURATION ?= Debug
SWIFT_XCODE_WORKSPACE ?=
SWIFT_XCODE_PROJECT ?=
SWIFT_XCODE_BUILD_SETTINGS ?=
SWIFT_XCODE_PREBUILD_CMD ?=
ifneq ($(strip $(SWIFT_XCODE_SCHEME)),)
SWIFT_XCODE_CONTAINER_ARG := $(if $(filter xcodegen,$(SWIFT_XCODE_GENERATOR)),--project $(SWIFT_XCODE_PROJECT),--workspace $(SWIFT_XCODE_WORKSPACE))
# Generate installs external dependencies first; Tuist cannot generate a project
# whose external SPM packages are unresolved, and xcodegen install is a no-op.
SWIFT_GENERATE_CMD ?= "$(SWIFT_MK_BIN)" toolchain install --generator $(SWIFT_XCODE_GENERATOR) && "$(SWIFT_MK_BIN)" toolchain generate --generator $(SWIFT_XCODE_GENERATOR)
SWIFT_BUILD_CMD ?= "$(SWIFT_MK_BIN)" toolchain build --generator $(SWIFT_XCODE_GENERATOR) $(SWIFT_XCODE_CONTAINER_ARG) --scheme $(SWIFT_XCODE_SCHEME) --configuration $(SWIFT_XCODE_CONFIGURATION) --derived-data-path $(SWIFT_MK_DERIVED_DATA) $(SWIFT_XCODE_BUILD_SETTINGS) $(SWIFT_MK_XCODEBUILD_ARGS)
# Test runner is decoupled from the generator. An Xcode consumer defaults to the
# scheme-driven `toolchain test` path, but a hybrid consumer whose tests run as a
# SwiftPM package (a Tuist overlay used only for generate and a metallib, with the
# real targets in Package.swift) sets SWIFT_TEST_MODE=spm to test via `swift test`.
# That sidesteps the Tuist static-framework SPM integration's failure to propagate
# internal C-target module maps (the EventSource/NIO/_NumericsShims case), which
# only affects the static-framework test build, never the SwiftPM executable build.
SWIFT_TEST_MODE ?= xcode
ifeq ($(strip $(SWIFT_TEST_MODE)),spm)
SWIFT_TEST_CMD ?= "$(SWIFT_MK_BIN)" toolchain swiftpm test
else
SWIFT_TEST_CMD ?= "$(SWIFT_MK_BIN)" toolchain test --generator $(SWIFT_XCODE_GENERATOR) $(SWIFT_XCODE_CONTAINER_ARG) --scheme $(SWIFT_XCODE_SCHEME) --configuration Debug --derived-data-path $(SWIFT_MK_DERIVED_DATA) $(SWIFT_MK_XCODEBUILD_ARGS)
endif
endif

SWIFT_BUILD_CMD ?= "$(SWIFT_MK_BIN)" toolchain swiftpm build
SWIFT_TEST_CMD ?= "$(SWIFT_MK_BIN)" toolchain swiftpm test
SWIFT_RUN_CMD ?=
SWIFT_GENERATE_CMD ?=
SWIFT_DEPLOY_CMD ?=
SWIFT_ANALYZE_CMD ?=
SWIFT_AUDIT_EXTRA_CMD ?=
SWIFT_LOG_AUDIT_CMD ?=
# Consumer-injected preflight rail: CHECK asserts a requirement the build needs,
# ENSURE establishes it on a miss, then the check re-runs and a still-failing
# check fails the run loud. Both empty (the default) leaves the rail inert. The
# engine owns only the pattern; both commands are opaque consumer strings, e.g.
# CHECK 'xcrun --find <tool>' with ENSURE '"$(SWIFT_MK_BIN)" toolchain
# download-component <ComponentName>'. An empty CHECK with a set ENSURE runs
# the ensure on every invocation, so that command must be idempotent.
SWIFT_PREFLIGHT_CHECK_CMD ?=
SWIFT_PREFLIGHT_ENSURE_CMD ?=

SWIFTCHECK_EXTRA_BIN ?=
SWIFTCHECK_EXTRA_BUILD_REPO ?= $(if $(and $(SWIFT_MK_DEV_DIR),$(wildcard $(SWIFT_MK_DEV_DIR)/swiftcheck/Package.swift)),$(SWIFT_MK_DEV_DIR)/swiftcheck,$(CURDIR)/.make/swiftcheck)
SWIFTCHECK_EXTRA_BUILD_PRODUCT ?= swiftcheck-extra
SWIFTCHECK_EXTRA_FLAGS ?= -no_any -no_anyobject -untyped_json -force_unwrap -force_try -silent_try -silent_catch -banned_direct_output -task_detached -sleep_in_production -fatal_exit -sensitive_log_field -missing_boundary_log -ignored_cleanup_error -missing_section_mark -unrouted_build_tooling -fragile_package_path
SWIFTCHECK_EXTRA_TARGETS ?= $(SWIFTLINT_TARGETS)
SWIFTCHECK_EXTRA_BASELINE ?= .swiftcheck-extra-baseline.jsonl
SWIFTCHECK_EXTRA_DEFAULT_EXCLUDE_PATHS ?=
SWIFTCHECK_EXTRA_EXCLUDE_PATHS ?=

# Framework-owned, not a consumer knob: swift-makefile enforces every gate. `override`
# so a consumer cannot drop, reorder, or substitute a gate even from the make command
# line (a plain `:=` still loses to a CLI `LINT_GATES=`). log-audit is appended only
# when the consumer declares SWIFT_LOG_AUDIT_CMD.
override LINT_GATES := lint-swiftlint lint-format lint-complexity lint-deadcode swiftcheck-extra $(if $(strip $(SWIFT_LOG_AUDIT_CMD)),log-audit,)

export SWIFT_MK_ROOT := $(CURDIR)
export SWIFT_MK_DEV_DIR
export SWIFT_MK_HELPER_DIR
export SWIFT_MK_RECURSIVE_MAKE
export SWIFT_MK_RECURSIVE_MAKE_ARGS
export SWIFT_MK_ENTRY_MAKEFILE
export SWIFT_MK_BASE_URL
export SWIFT_MK_API_REPO
export SWIFT_MK_API_REF
export SWIFT_MK_SWIFTLINT_CONFIG
export SWIFT_MK_SWIFT_FORMAT_CONFIG
export SWIFT_MK_PERIPHERY_CONFIG
export SWIFT_MK_OSV_CONFIG
export SWIFT_MK_MISE_CONFIG
export SWIFT_MK_BUILD_CACHE
export SWIFTLINT
export SWIFTLINT_FLAGS
export SWIFTLINT_TARGETS
export SWIFTLINT_BASELINE
export SWIFTLINT_BASELINE_SCOPE_PATTERN
export RULE
export SWIFT_MK_BIN
export SWIFT_MK_NOTICES_FILE
export SWIFTLINT_DEFAULT_EXCLUDE_PATHS
export SWIFTLINT_EXCLUDE_PATHS
export SWIFT_FORMAT
export SWIFT_FORMAT_TARGETS
export COMPLEXITY_RULES
export SWIFTLINT_COMPLEXITY_BASELINE
export PERIPHERY
export PERIPHERY_ARGS
export PERIPHERY_BASELINE
export PERIPHERY_DEFAULT_EXCLUDE_PATHS
export PERIPHERY_EXCLUDE_PATHS
export OSV_SCANNER
export OSV_SCANNER_ARGS
export LINT_CONCURRENCY
export SWIFT_MK_XCODE_VERSION_MAJOR
export SWIFT_MK_SWIFT_CACHE
export SWIFT_MK_SWIFTPM_CACHE
export SWIFT_MK_XCODE_CACHE
export SWIFT_MK_XCODE_CACHE_PREFIX_MAP
export SWIFT_MK_XCODE_CACHE_DIAGNOSTICS
export SWIFT_MK_XCODEBUILD_ARGS
export SWIFT_MK_XCODEBUILD_NO_CACHE_ARGS
export SWIFT_XCODE_GENERATOR
export SWIFT_XCODE_COVERAGE_CONFIGURATION
export SWIFT_XCODE_BUILD_SETTINGS
export SWIFT_XCODE_PREBUILD_CMD
export SWIFT_MK_DERIVED_DATA
export SWIFT_MK_SWIFTPM_CACHE_ARGS
export LINT_GATES
export LINT_FILES
export LINT_LINE_RANGES
export BASELINE
export BASELINE_CONFIRM
export BASELINE_TOKEN
export BASELINE_TOKEN_CMD
export BASELINE_UPDATE_MODE
export BYPASS_LINT
export BYPASS_CONFIRM
export BYPASS_TOKEN_CMD
export SWIFT_MK_GATE_TOKEN_CMD
export SWIFT_BUILD_CMD
# Signing context the swift-mk binary reads when it owns a build (the signing
# xcconfig, the dead-code coverage build). Consumers set these as plain make
# variables, so without the export the gate processes never see them and a CI
# runner with no local xcconfig loses DEVELOPMENT_TEAM inside the coverage build.
export CODE_SIGN_IDENTITY
export CODE_SIGN_KEYCHAIN
export CODE_SIGN_STYLE
export DEVELOPMENT_TEAM
export TUIST_DEVELOPMENT_TEAM
export SWIFT_MK_SIGN_IDENTITY
export SWIFT_MK_SIGN_KEYCHAIN
export SWIFT_MK_SIGN_TEAM
export SWIFT_MK_SIGN_STYLE
export SWIFT_MK_REQUIRE_SIGNING
export SWIFT_MK_VERIFY_XCCONFIG
# A consumer builds via Xcode when it declares a scheme or Xcode container; a plain
# SwiftPM package declares neither. The dead-code gate and the build chokepoint key
# off this one flag rather than guessing from on-disk project files, so a stray
# generated .xcodeproj/.xcworkspace never changes behavior.
SWIFT_MK_XCODE_BUILD := $(if $(strip $(SWIFT_XCODE_SCHEME))$(strip $(SWIFT_XCODE_WORKSPACE))$(strip $(SWIFT_XCODE_PROJECT)),1,)
export SWIFT_MK_XCODE_BUILD
export SWIFT_TEST_CMD
export SWIFT_RUN_CMD
export SWIFT_GENERATE_CMD
export SWIFT_DEPLOY_CMD
export SWIFT_ANALYZE_CMD
export SWIFT_AUDIT_EXTRA_CMD
export SWIFT_LOG_AUDIT_CMD
export SWIFT_PREFLIGHT_CHECK_CMD
export SWIFT_PREFLIGHT_ENSURE_CMD
export SWIFTCHECK_EXTRA_BIN
export SWIFTCHECK_EXTRA_BUILD_REPO
export SWIFTCHECK_EXTRA_BUILD_PRODUCT
export SWIFTCHECK_EXTRA_FLAGS
export SWIFTCHECK_EXTRA_TARGETS
export SWIFTCHECK_EXTRA_BASELINE
export SWIFTCHECK_EXTRA_DEFAULT_EXCLUDE_PATHS
export SWIFTCHECK_EXTRA_EXCLUDE_PATHS
export SWIFT_MK_CONSUMER_ROOTS
export SWIFT_MK_CONSUMER_MANIFEST
export SWIFT_MK_UPDATE_INCLUDE_DIRTY
export SWIFT_MK_UPDATE_VALIDATE
export SWIFT_MK_UPDATE_DRY_RUN

# SWIFT_MK_DERIVED_DATA is an override, so only rm a path that physically resolves
# to a real subpath of the checkout; refuse anything outside so an override cannot
# rm an arbitrary path. `abspath` is lexical (collapses `..`) but does not resolve
# symlinks, so also resolve the physical path of the checkout root and of the
# target's parent with `pwd -P`; a symlinked component then resolves to its real
# location and is refused if that lands outside the root. Also refuse a target that
# exists and is not a directory, so an override pointing at a tracked file (for
# example $(CURDIR)/Package.swift) is not deleted.
.PHONY: clean
clean:
	@if [ -f Package.swift ]; then swift package clean >/dev/null 2>&1 || true; fi; \
		rm -rf .build; \
		rm -rf .make/.build; \
		root=$$(cd "$(CURDIR)" 2>/dev/null && pwd -P) || root="$(CURDIR)"; \
		dd="$(abspath $(SWIFT_MK_DERIVED_DATA))"; \
		parent=$$(cd "$$(dirname "$$dd")" 2>/dev/null && pwd -P); \
		if [ -n "$$parent" ]; then dd="$$parent/$$(basename "$$dd")"; fi; \
		if [ -e "$$dd" ] && [ ! -d "$$dd" ]; then \
			printf 'swift-mk: refusing to remove SWIFT_MK_DERIVED_DATA=%s (not a directory)\n' "$(SWIFT_MK_DERIVED_DATA)" >&2; \
		else \
			case "$$dd" in \
				"$$root"/?*) rm -rf "$$dd" ;; \
				*) printf 'swift-mk: refusing to remove SWIFT_MK_DERIVED_DATA=%s (resolves outside the checkout)\n' "$(SWIFT_MK_DERIVED_DATA)" >&2 ;; \
			esac; \
		fi

swift-mk-bin:
	@if [ -x "$(SWIFT_MK_BIN)" ]; then "$(SWIFT_MK_BIN)" trace begin 2>/dev/null || true; fi
	@SWIFT_MK_ROOT="$(CURDIR)" bash "$(SWIFT_MK_HELPER_DIR)/swift-mk-build.sh" resolve

# Render the Xcode file-header macros from the current git identity so newly
# created files are stamped with this author. swift-mk reads the git identity,
# renders the template, and rewrites the plist only when it changes. Consumers
# invoke this on demand; swift-makefile's own Makefile runs it on every build.
xcode-file-header: swift-mk-bin
	@"$(SWIFT_MK_BIN)" xcode-file-header \
		--templates-dir "$(SWIFT_MK_SELF_DIR)/templates/xcode" \
		--output-dir "$(XCODE_TEMPLATE_DIR)"

swift-mk-notice: swift-mk-bin
	@"$(SWIFT_MK_BIN)" notice || true

lint: lint-tools | swift-mk-notice
	@"$(SWIFT_MK_BIN)" lint

lint-tools: swift-mk-bin
	@"$(SWIFT_MK_BIN)" lint-tools

quality-guard: swift-mk-bin
	@"$(SWIFT_MK_BIN)" quality-guard

lint-swiftlint: lint-tools
	@"$(SWIFT_MK_BIN)" lint-swiftlint

lint-format: swift-mk-bin
	@"$(SWIFT_MK_BIN)" lint-format

lint-complexity: swift-mk-bin
	@"$(SWIFT_MK_BIN)" lint-complexity

lint-complexity-baseline: swift-mk-bin
	@BASELINE_UPDATE_MODE=sync "$(SWIFT_MK_BIN)" baseline complexity

lint-complexity-baseline-prune-fixed: swift-mk-bin
	@BASELINE_UPDATE_MODE=prune-fixed "$(SWIFT_MK_BIN)" baseline complexity

lint-complexity-baseline-remove-fixed: lint-complexity-baseline-prune-fixed

lint-complexity-baseline-accept-new: swift-mk-bin
	@BASELINE_UPDATE_MODE=accept-new "$(SWIFT_MK_BIN)" baseline complexity

lint-files: lint-tools swiftcheck-extra-bin
	@"$(SWIFT_MK_BIN)" lint-files

lint-diff: lint-tools swiftcheck-extra-bin
	@"$(SWIFT_MK_BIN)" lint-diff

fmt: lint-tools
	@"$(SWIFT_MK_BIN)" fmt

test: swift-mk-bin
	@"$(SWIFT_MK_BIN)" test

log-audit: swift-mk-bin
	@"$(SWIFT_MK_BIN)" log-audit

audit: swift-mk-bin
	@"$(SWIFT_MK_BIN)" audit

analyze: lint-deadcode
	@if [ -n "$(strip $(SWIFT_ANALYZE_CMD))" ]; then eval "$(SWIFT_ANALYZE_CMD)"; fi

lint-deadcode: swift-mk-bin
	@"$(SWIFT_MK_BIN)" lint-deadcode

swiftcheck-extra-bin: swift-mk-bin
	@"$(SWIFT_MK_BIN)" swiftcheck-extra-bin

swiftcheck-extra: swiftcheck-extra-bin
	@"$(SWIFT_MK_BIN)" swiftcheck-extra

lint-swiftlint-baseline: swift-mk-bin
	@BASELINE_UPDATE_MODE=sync "$(SWIFT_MK_BIN)" baseline swiftlint

lint-swiftlint-baseline-prune-fixed: swift-mk-bin
	@BASELINE_UPDATE_MODE=prune-fixed "$(SWIFT_MK_BIN)" baseline swiftlint

lint-swiftlint-baseline-remove-fixed: lint-swiftlint-baseline-prune-fixed

lint-swiftlint-baseline-accept-new: swift-mk-bin
	@BASELINE_UPDATE_MODE=accept-new "$(SWIFT_MK_BIN)" baseline swiftlint

lint-swiftlint-scope: lint-tools
	@"$(SWIFT_MK_BIN)" lint-swiftlint-scope

lint-swiftlint-baseline-scope: swift-mk-bin
	@BASELINE_UPDATE_MODE=sync "$(SWIFT_MK_BIN)" baseline swiftlint-scope

lint-swiftlint-baseline-scope-accept-new: swift-mk-bin
	@BASELINE_UPDATE_MODE=accept-new "$(SWIFT_MK_BIN)" baseline swiftlint-scope

lint-deadcode-baseline: swift-mk-bin
	@BASELINE_UPDATE_MODE=sync "$(SWIFT_MK_BIN)" baseline deadcode

lint-deadcode-baseline-prune-fixed: swift-mk-bin
	@BASELINE_UPDATE_MODE=prune-fixed "$(SWIFT_MK_BIN)" baseline deadcode

lint-deadcode-baseline-remove-fixed: lint-deadcode-baseline-prune-fixed

lint-deadcode-baseline-accept-new: swift-mk-bin
	@BASELINE_UPDATE_MODE=accept-new "$(SWIFT_MK_BIN)" baseline deadcode

swiftcheck-extra-baseline: swift-mk-bin
	@BASELINE_UPDATE_MODE=sync "$(SWIFT_MK_BIN)" baseline swiftcheck-extra

swiftcheck-extra-baseline-prune-fixed: swift-mk-bin
	@BASELINE_UPDATE_MODE=prune-fixed "$(SWIFT_MK_BIN)" baseline swiftcheck-extra

swiftcheck-extra-baseline-remove-fixed: swiftcheck-extra-baseline-prune-fixed

swiftcheck-extra-baseline-accept-new: swift-mk-bin
	@BASELINE_UPDATE_MODE=accept-new "$(SWIFT_MK_BIN)" baseline swiftcheck-extra

build-check: swift-mk-bin
	@"$(SWIFT_MK_BIN)" build-check

check: lint

baseline: swift-mk-bin
	@BASELINE_UPDATE_MODE=sync "$(SWIFT_MK_BIN)" baseline all

baseline-prune-fixed: swift-mk-bin
	@BASELINE_UPDATE_MODE=prune-fixed "$(SWIFT_MK_BIN)" baseline all

baseline-remove-fixed: baseline-prune-fixed

baseline-accept-new: swift-mk-bin
	@BASELINE_UPDATE_MODE=accept-new "$(SWIFT_MK_BIN)" baseline all

baseline-add-new: baseline-accept-new

update-go-mk:
	@printf 'swift-makefile: use update-swift-mk instead of update-go-mk\n'
	@exit 2

update-swift-mk swift-mk-sync:
	@SWIFT_MK="$(SWIFT_MK)" bash "$(SWIFT_MK_HELPER_DIR)/swift-mk-sync.sh" update

smoke-fetch:
	@bash "$(SWIFT_MK_HELPER_DIR)/swift-mk-sync.sh" smoke-fetch

update-consumers:
	@bash "$(SWIFT_MK_HELPER_DIR)/swift-mk-fleet-update.sh" update

update-consumers-dry-run:
	@SWIFT_MK_UPDATE_DRY_RUN=1 bash "$(SWIFT_MK_HELPER_DIR)/swift-mk-fleet-update.sh" dry-run

install-hooks:
	@bash "$(SWIFT_MK_HELPER_DIR)/install-hooks.sh"

$(foreach m,$(SWIFT_MK_MODULES),$(eval -include .make/$(m)))

endif
