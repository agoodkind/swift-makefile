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
SWIFT_MK_SIGNING_PRELUDE = xcc=""; if [ -n "$(strip $(SWIFT_MK_BIN))" ] && [ -x "$(SWIFT_MK_BIN)" ]; then xcc="$$(DEVELOPMENT_TEAM="$(DEVELOPMENT_TEAM)" CODE_SIGN_IDENTITY="$(CODE_SIGN_IDENTITY)" CODE_SIGN_STYLE="$(CODE_SIGN_STYLE)" "$(SWIFT_MK_BIN)" signing-xcconfig 2>/dev/null || true)"; fi; if [ -n "$$xcc" ]; then if [ -n "$${XCODE_XCCONFIG_FILE:-}" ]; then echo "swift-build.mk: XCODE_XCCONFIG_FILE already set ($${XCODE_XCCONFIG_FILE}); leaving it, not applying swift-mk signing" >&2; else export XCODE_XCCONFIG_FILE="$$xcc"; fi; fi;

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

# `swift-mk build` is the chokepoint: it runs the lint gates in-process and then
# the configured SWIFT_BUILD_CMD, so there is no separate recipe step that compiles
# without gating. It depends only on the binary; the gates run inside it, not as a
# make prerequisite.
build: swift-mk-bin
	@$(SWIFT_MK_SIGNING_PRELUDE) \
		$(if $(strip $(SWIFT_GENERATE_CMD)),$(SWIFT_GENERATE_CMD) &&,) \
		$(SWIFT_MK_VERIFY_SETTINGS_CMD) \
		"$(SWIFT_MK_BIN)" build \
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

generate:
ifeq ($(strip $(SWIFT_GENERATE_CMD)),)
	@echo "generate: no generate command configured"; exit 0
else
	@$(SWIFT_GENERATE_CMD)
endif

deploy: build
ifeq ($(strip $(SWIFT_DEPLOY_CMD)),)
	@echo "swift-build.mk: SWIFT_DEPLOY_CMD is not set"; exit 1
else
	@$(SWIFT_MK_SIGNING_PRELUDE) $(SWIFT_DEPLOY_CMD) && $(SWIFT_MK_VERIFY_ARTIFACTS_CMD)
endif

install: deploy

clean:
ifneq ($(strip $(SWIFT_CLEAN_CMD)),)
	@$(SWIFT_CLEAN_CMD)
endif
