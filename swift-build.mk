.PHONY: build deploy install run generate

# swift-mk owns build-time code signing. Before any xcodebuild runs, ask the
# swift-mk binary for the signing xcconfig (built from DEVELOPMENT_TEAM /
# CODE_SIGN_IDENTITY / CODE_SIGN_STYLE) and export XCODE_XCCONFIG_FILE so it wins
# over every target's settings, including Tuist's per-target CODE_SIGN_IDENTITY =
# - default. It prints nothing when no signing values are set, so an unsigned
# build still works and nothing is forced. A consumer that already set
# XCODE_XCCONFIG_FILE is left untouched with a warning rather than clobbered. The
# prelude runs in the same shell as the build command so the export reaches it.
# The signing inputs are passed inline so swift-mk sees them whether they arrive
# as make variables (a -included local.xcconfig) or as the environment (CI); make
# expands an undefined variable to empty, which yields no override. SWIFT_MK_SIGN_*
# names from the real environment still win inside the binary.
SWIFT_MK_SIGN_KEYCHAIN_ENV = $(if $(strip $(CODE_SIGN_KEYCHAIN)$(SWIFT_MK_SIGN_KEYCHAIN)),CODE_SIGN_KEYCHAIN="$(CODE_SIGN_KEYCHAIN)" SWIFT_MK_SIGN_KEYCHAIN="$(SWIFT_MK_SIGN_KEYCHAIN)",)
SWIFT_MK_SHELL_COMMAND_SUBST = $$
SWIFT_MK_SIGNING_XCCONFIG_CMD = DEVELOPMENT_TEAM="$(DEVELOPMENT_TEAM)" CODE_SIGN_IDENTITY="$(CODE_SIGN_IDENTITY)" CODE_SIGN_STYLE="$(CODE_SIGN_STYLE)" "$(SWIFT_MK_BIN)" signing-xcconfig
SWIFT_MK_SIGNING_XCCONFIG_KEYCHAIN_CMD = DEVELOPMENT_TEAM="$(DEVELOPMENT_TEAM)" CODE_SIGN_IDENTITY="$(CODE_SIGN_IDENTITY)" CODE_SIGN_STYLE="$(CODE_SIGN_STYLE)" $(SWIFT_MK_SIGN_KEYCHAIN_ENV) "$(SWIFT_MK_BIN)" signing-xcconfig
SWIFT_MK_SIGNING_XCCONFIG_SELECTED_CMD = $(if $(strip $(CODE_SIGN_KEYCHAIN)$(SWIFT_MK_SIGN_KEYCHAIN)),$(SWIFT_MK_SIGNING_XCCONFIG_KEYCHAIN_CMD),$(SWIFT_MK_SIGNING_XCCONFIG_CMD))
SWIFT_MK_SIGNING_PRELUDE = xcc=""; if [ -n "$(strip $(SWIFT_MK_BIN))" ] && [ -x "$(SWIFT_MK_BIN)" ]; then xcc="$(SWIFT_MK_SHELL_COMMAND_SUBST)($(SWIFT_MK_SIGNING_XCCONFIG_SELECTED_CMD) 2>/dev/null || true)"; fi; if [ -n "$$xcc" ]; then if [ -n "$${XCODE_XCCONFIG_FILE:-}" ]; then echo "swift-build.mk: XCODE_XCCONFIG_FILE already set ($${XCODE_XCCONFIG_FILE}); leaving it, not applying swift-mk signing" >&2; else export XCODE_XCCONFIG_FILE="$$xcc"; fi; fi;
SWIFT_MK_SIGNING_PREFLIGHT = "$(SWIFT_MK_BIN)" signing-preflight
SWIFT_MK_SIGNING_REQUIRED = $(strip $(SWIFT_MK_VERIFY_XCCONFIG)$(if $(filter 1,$(SWIFT_MK_REQUIRE_SIGNING)),1,))

# Optional signature verification. A consumer opts in by setting the variables.
# Unset means no verification, so these never disturb an existing build. The
# settings check runs before the build (after generate) and the artifacts check
# after, both chained with && so a failure fails the build. The artifacts command
# defaults to `true` so the trailing `&&` always has a right-hand side.
#
# SWIFT_MK_VERIFY_XCCONFIG names the gitignored local xcconfig the team and
# identity live in, so verify-signing resolves the same inputs the override uses
# even when those values arrive as make variables rather than the environment.
# Without it a -included local.xcconfig leaves the verifier with no team, so it
# would skip the check instead of enforcing it. The --xcconfig flag parses up to
# the next option, so for the artifacts check it must follow the positional paths;
# leading it would swallow the bundle paths.
SWIFT_MK_VERIFY_XCCONFIG_ARGS = $(if $(strip $(SWIFT_MK_VERIFY_XCCONFIG)),--xcconfig $(SWIFT_MK_VERIFY_XCCONFIG),)
SWIFT_MK_VERIFY_SETTINGS_CMD = $(if $(and $(strip $(SWIFT_MK_VERIFY_WORKSPACE)),$(strip $(SWIFT_MK_VERIFY_SCHEME))),"$(SWIFT_MK_BIN)" verify-signing settings --workspace "$(SWIFT_MK_VERIFY_WORKSPACE)" --scheme "$(SWIFT_MK_VERIFY_SCHEME)" $(if $(strip $(SWIFT_MK_VERIFY_CONFIGURATION)),--configuration "$(SWIFT_MK_VERIFY_CONFIGURATION)") $(SWIFT_MK_VERIFY_XCCONFIG_ARGS) &&,)
SWIFT_MK_VERIFY_ARTIFACTS_CMD = $(if $(strip $(SWIFT_MK_VERIFY_SIGNING_PATHS)),"$(SWIFT_MK_BIN)" verify-signing artifacts $(SWIFT_MK_VERIFY_SIGNING_PATHS) $(SWIFT_MK_VERIFY_XCCONFIG_ARGS),true)

# Post-build code signing for products the xcconfig override cannot reach. The
# override only affects xcodebuild; a bare SwiftPM binary from `swift build` is
# never signed by it. A consumer declares what to sign, and swift-mk signs it
# through the same canonical codesign channel and identity resolution as the build
# override:
#   SWIFT_MK_SIGN_PRODUCTS          literal built binary paths (no make wildcard;
#                                   a shell glob in the value is fine, expanded at
#                                   recipe time after the build).
#   SWIFT_MK_SIGN_BUNDLES_DIR       directory whose top-level *.bundle resource
#                                   bundles are discovered and signed too.
#   SWIFT_MK_SIGN_IDENTIFIER        one bundle id applied to every path, or
#   SWIFT_MK_SIGN_IDENTIFIER_PREFIX derive each id as <prefix>.<basename>.
#   CODE_SIGN_KEYCHAIN             keychain path passed to codesign --keychain.
# It runs only when something is declared and an identity is set (CODE_SIGN_IDENTITY
# or SWIFT_MK_SIGN_IDENTITY), so an unsigned build (no cert, the common local and
# fork case) is left untouched.
SWIFT_MK_SIGN_PRODUCTS ?=
SWIFT_MK_SIGN_BUNDLES_DIR ?=
SWIFT_MK_SIGN_IDENTIFIER ?=
SWIFT_MK_SIGN_IDENTIFIER_PREFIX ?=
SWIFT_MK_HAS_SIGN_WORK := $(strip $(SWIFT_MK_SIGN_PRODUCTS)$(SWIFT_MK_SIGN_BUNDLES_DIR))
SWIFT_MK_SIGN_ID_ARGS = $(if $(strip $(SWIFT_MK_SIGN_IDENTIFIER)),--identifier $(SWIFT_MK_SIGN_IDENTIFIER),$(if $(strip $(SWIFT_MK_SIGN_IDENTIFIER_PREFIX)),--identifier-prefix $(SWIFT_MK_SIGN_IDENTIFIER_PREFIX),))
SWIFT_MK_SIGN_BUNDLES_ARGS = $(if $(strip $(SWIFT_MK_SIGN_BUNDLES_DIR)),--bundles-in $(SWIFT_MK_SIGN_BUNDLES_DIR),)
SWIFT_MK_SIGN_KEYCHAIN_VALUE = $(if $(strip $(SWIFT_MK_SIGN_KEYCHAIN)),$(SWIFT_MK_SIGN_KEYCHAIN),$(CODE_SIGN_KEYCHAIN))
SWIFT_MK_SIGN_KEYCHAIN_ARG = $(if $(strip $(SWIFT_MK_SIGN_KEYCHAIN_VALUE)),--keychain "$(SWIFT_MK_SIGN_KEYCHAIN_VALUE)",)
SWIFT_MK_POST_BUILD_SIGN_BASE_CMD = && "$(SWIFT_MK_BIN)" codesign-run --mode binary $(SWIFT_MK_SIGN_ID_ARGS) $(SWIFT_MK_SIGN_BUNDLES_ARGS)
SWIFT_MK_POST_BUILD_SIGN_KEYCHAIN_CMD = $(SWIFT_MK_POST_BUILD_SIGN_BASE_CMD) $(SWIFT_MK_SIGN_KEYCHAIN_ARG) $(SWIFT_MK_SIGN_PRODUCTS)
SWIFT_MK_POST_BUILD_SIGN_NO_KEYCHAIN_CMD = $(SWIFT_MK_POST_BUILD_SIGN_BASE_CMD) $(SWIFT_MK_SIGN_PRODUCTS)
SWIFT_MK_POST_BUILD_SIGN_CMD = $(if $(SWIFT_MK_HAS_SIGN_WORK),$(if $(strip $(CODE_SIGN_IDENTITY))$(strip $(SWIFT_MK_SIGN_IDENTITY)),$(if $(strip $(SWIFT_MK_SIGN_KEYCHAIN_VALUE)),$(SWIFT_MK_POST_BUILD_SIGN_KEYCHAIN_CMD),$(SWIFT_MK_POST_BUILD_SIGN_NO_KEYCHAIN_CMD)),),)

# `swift-mk build` is the chokepoint: it runs the lint gates in-process and then
# the configured SWIFT_BUILD_CMD, so there is no separate recipe step that compiles
# without gating. The gates run inside it, not as a make prerequisite.
#
# Freshness gate. `make build` no-ops when the tracked inputs and the built product
# are unchanged since the last successful build. The engine (swift-mk build-fresh)
# owns the freshness decision; this target is the make-level guard that ships that
# behavior to every consumer with no consumer edit.
#
# The record file is the stamp: make rebuilds it only when an input is newer, and
# the recipe itself decides between a no-op and the full build chain.
SWIFT_MK_FRESH_RECORD := $(CURDIR)/.make/.build/last-success
# Opaque fingerprint of the build inputs that are not source files, so a change to
# the build command, generate command, configuration, or any signing knob is itself
# a rebuild trigger even when no tracked source changed. The post-build signing
# variables are folded in too, so changing only what gets signed rebuilds and
# re-signs rather than skipping as fresh.
SWIFT_MK_FRESH_CONFIG_KEY := $(SWIFT_BUILD_CMD)|$(SWIFT_GENERATE_CMD)|$(SWIFT_XCODE_CONFIGURATION)|$(DEVELOPMENT_TEAM)|$(CODE_SIGN_IDENTITY)|$(CODE_SIGN_STYLE)|$(CODE_SIGN_KEYCHAIN)|$(SWIFT_MK_SIGN_PRODUCTS)|$(SWIFT_MK_SIGN_BUNDLES_DIR)|$(SWIFT_MK_SIGN_IDENTIFIER)|$(SWIFT_MK_SIGN_IDENTIFIER_PREFIX)|$(SWIFT_MK_SIGN_IDENTITY)
# Export the key so the recipe passes it through the environment rather than a
# shell-quoted argument. make hands an exported variable to the recipe verbatim, so
# a folded value containing an apostrophe (a signing identity like O'Brien, a path)
# cannot break the build command's shell parse. build-fresh reads it from here.
export SWIFT_MK_FRESH_CONFIG_KEY
# Product paths the freshness check confirms still exist. Empty by default so a
# plain SwiftPM consumer relies on the source digest alone; swift-app.mk sets the
# built .app so an app consumer also rebuilds when the bundle is gone.
SWIFT_MK_FRESH_PRODUCTS ?=
SWIFT_MK_FRESH_ARGS = $(foreach p,$(SWIFT_MK_FRESH_PRODUCTS),--product '$(p)')
# Escape hatch: FORCE with a truthy value, or SWIFT_MK_BUILD_FRESH with a falsy
# value, makes this non-empty, so the guard skips the freshness check and always
# runs the build chain. FORCE=0 is filtered out so it does not force a build.
SWIFT_MK_FRESH_FORCE := $(strip $(filter-out 0 false no off,$(FORCE)) $(filter 0 false no off,$(SWIFT_MK_BUILD_FRESH)))
# The make-level input list that decides whether the stamp is out of date. It lists
# source FILES and every non-pruned DIRECTORY. A directory is a prerequisite because
# adding, deleting, or renaming a child bumps that directory's mtime, so a pure
# deletion (which a file-only list cannot see, the deleted file simply vanishes from
# the list) still re-runs the recipe. Config files, the engine binary, and the
# makefiles round out the set. POSIX find keeps this bootstrap-safe (no rg). The
# pruned directories match the engine's digestExcludedDirectories, so make and the
# binary agree on the file set and a large build output tree is never walked.
SWIFT_MK_FRESH_INPUTS := $(shell find $(CURDIR) -type d \( -name .git -o -name .build -o -name .make -o -name .derived-data -o -name DerivedData -o -name Derived -o -name Products -o -name SourcePackages -o -name node_modules -o -name .swiftpm -o -name build -o -name .tuist -o -name Pods \) -prune -o \( -type d -o -type f \( -name '*.swift' -o -name '*.h' -o -name '*.m' -o -name '*.c' -o -name '*.metal' -o -name '*.mk' \) \) -print 2>/dev/null) $(wildcard Package.swift Package.resolved Project.swift Workspace.swift *.xcconfig Tuist/*) $(SWIFT_MK_BIN) $(MAKEFILE_LIST)

build: $(SWIFT_MK_FRESH_RECORD)

# swift-mk-bin is an ORDER-ONLY prerequisite (after the `|`). It still ensures the
# engine binary is current before the recipe runs, but as a phony target it is always
# considered out of date; a normal prerequisite on it would force this record to
# rebuild on every invocation and defeat the whole gate. The order-only form runs it
# without letting its perpetual out-of-dateness propagate to the stamp.
$(SWIFT_MK_FRESH_RECORD): $(SWIFT_MK_FRESH_INPUTS) | swift-mk-bin
	@if [ -z "$(SWIFT_MK_FRESH_FORCE)" ] && "$(SWIFT_MK_BIN)" build-fresh check $(SWIFT_MK_FRESH_ARGS); then \
		echo "swift-build.mk: build up to date, skipping (FORCE=1 to rebuild)"; \
		touch "$@"; \
	else \
		$(SWIFT_MK_SIGNING_PRELUDE) \
			$(if $(SWIFT_MK_SIGNING_REQUIRED),$(SWIFT_MK_SIGNING_PREFLIGHT) && ,) \
			$(if $(strip $(SWIFT_GENERATE_CMD)),$(SWIFT_GENERATE_CMD) &&,) \
			$(SWIFT_MK_VERIFY_SETTINGS_CMD) \
			"$(SWIFT_MK_BIN)" build \
			$(SWIFT_MK_POST_BUILD_SIGN_CMD) \
			&& $(SWIFT_MK_VERIFY_ARTIFACTS_CMD) \
			&& "$(SWIFT_MK_BIN)" build-fresh record $(SWIFT_MK_FRESH_ARGS) \
			&& touch "$@"; \
	fi
# The fresh branch touches the stamp so a content-identical mtime churn (a checkout
# or a no-op formatter pass that flips file mtimes but not bytes) resets the stamp
# past the inputs; the next make run then hits make's own no-op with no recipe at all.

# Consumers that define their own `run` set SWIFT_MK_OWN_RUN := 1 before include,
# so this default does not collide and Make does not warn about overriding it.
ifeq ($(strip $(SWIFT_MK_OWN_RUN)),)
run: build
ifeq ($(strip $(SWIFT_RUN_CMD)),)
	@echo "swift-build.mk: SWIFT_RUN_CMD is not set"; exit 1
else
	@$(SWIFT_RUN_CMD)
endif
endif

generate: $(if $(SWIFT_MK_SIGNING_REQUIRED),swift-mk-bin,)
ifeq ($(strip $(SWIFT_GENERATE_CMD)),)
	@echo "generate: no generate command configured"; exit 0
else
	@$(if $(SWIFT_MK_SIGNING_REQUIRED),$(SWIFT_MK_SIGNING_PREFLIGHT) && ,)$(SWIFT_GENERATE_CMD)
endif

deploy: build
ifeq ($(strip $(SWIFT_DEPLOY_CMD)),)
	@echo "swift-build.mk: SWIFT_DEPLOY_CMD is not set"; exit 1
else
	@$(SWIFT_MK_SIGNING_PRELUDE) $(SWIFT_DEPLOY_CMD) && $(SWIFT_MK_VERIFY_ARTIFACTS_CMD)
endif

install: deploy
