.PHONY: build deploy install run generate clean

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
# without gating. It depends only on the binary; the gates run inside it, not as a
# make prerequisite.
build: swift-mk-bin
	@$(SWIFT_MK_SIGNING_PRELUDE) \
		$(if $(SWIFT_MK_SIGNING_REQUIRED),$(SWIFT_MK_SIGNING_PREFLIGHT) && ,) \
		$(if $(strip $(SWIFT_GENERATE_CMD)),$(SWIFT_GENERATE_CMD) &&,) \
		$(SWIFT_MK_VERIFY_SETTINGS_CMD) \
		"$(SWIFT_MK_BIN)" build \
		$(SWIFT_MK_POST_BUILD_SIGN_CMD) \
		&& $(SWIFT_MK_VERIFY_ARTIFACTS_CMD)

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

# Engine-owned trivial clean. swift-mk owns clean now: it removes the SwiftPM
# build dir and the engine-managed DerivedData and runs `swift package clean`,
# ignoring any consumer SWIFT_CLEAN_CMD so a clean never compiles a dev tool. This
# is the full-path clean (for example `make clean build`); a clean-only goal takes
# the self-contained fast path in bootstrap.mk and never loads this module.
clean:
	@if [ -f Package.swift ]; then swift package clean >/dev/null 2>&1 || true; fi; \
		rm -rf .build "$(SWIFT_MK_DERIVED_DATA)"
