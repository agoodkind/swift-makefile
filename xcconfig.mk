# xcconfig.mk
#
# Render-and-generate helper for Tuist projects whose source of truth is one
# or more xcconfig files. The consumer Makefile -includes the xcconfig files
# so their key=value pairs are visible as Make variables, lists the keys it
# wants exposed to its templates, and lists one or more render plans. Each
# plan says "take every *.template under <templates_dir>, render it, and drop
# the rendered file under <output_dir>". The keys are exported into the env
# seen by swift-mk render-batch so [[KEY]] tokens substitute.
#
# Consumer-provided variables (set BEFORE including this file):
#
#   XCCONFIG_RENDER_PLANS    whitespace-separated list of plans. Each plan is
#                            <templates_dir>:<output_dir>[:<target_name>].
#                            If target_name is present it is exported to the
#                            generator as TARGET_NAME.
#   XCCONFIG_EXPORTED_VARS   whitespace-separated list of variable names to
#                            expose as [[KEY]] substitutions. Each name must
#                            resolve to a Make variable, which is exported
#                            into the env seen by swift-mk render-batch.
#
# Optional:
#
#   TUIST                    tuist executable (default: tuist).
#   SWIFT_MK_BIN             path to swift-mk (default: $(CURDIR)/.make/swift-mk).
#
# Targets:
#
#   xcconfig-generate-config     Render every plan in XCCONFIG_RENDER_PLANS.
#   xcconfig-generate-project    xcconfig-generate-config, then tuist generate --no-open.
#   xcconfig-print-env           Print the resolved exported env for debugging.

TUIST ?= tuist
SWIFT_MK_BIN ?= $(CURDIR)/.make/swift-mk

# Build "KEY=$(KEY)" pairs from XCCONFIG_EXPORTED_VARS so the recipe can pass
# them inline as one-shot env assignments.
XCCONFIG_ENV_PAIRS := $(foreach v,$(XCCONFIG_EXPORTED_VARS),$(v)="$($(v))")

.PHONY: xcconfig-generate-config xcconfig-generate-project xcconfig-print-env

xcconfig-generate-config:
	@if [ -z "$(XCCONFIG_RENDER_PLANS)" ]; then \
		echo "xcconfig.mk: XCCONFIG_RENDER_PLANS is empty" >&2; exit 1; \
	fi
	@if [ ! -x "$(SWIFT_MK_BIN)" ]; then \
		echo "xcconfig.mk: $(SWIFT_MK_BIN) is not executable; run 'make swift-mk-bin' first" >&2; exit 1; \
	fi
	@for plan in $(XCCONFIG_RENDER_PLANS); do \
		templates_dir=$$(echo "$$plan" | cut -d: -f1); \
		output_dir=$$(echo "$$plan" | cut -d: -f2); \
		target_name=$$(echo "$$plan" | cut -d: -f3); \
		if [ -z "$$templates_dir" ] || [ -z "$$output_dir" ]; then \
			echo "xcconfig.mk: malformed plan '$$plan'; expected templates_dir:output_dir[:target_name]" >&2; exit 1; \
		fi; \
		mkdir -p "$$output_dir"; \
		TARGET_NAME="$$target_name" $(XCCONFIG_ENV_PAIRS) \
			"$(SWIFT_MK_BIN)" render-batch \
				--templates-dir "$$templates_dir" \
				--output-dir "$$output_dir" \
				--env TARGET_NAME $(XCCONFIG_EXPORTED_VARS) ; \
	done

xcconfig-generate-project: xcconfig-generate-config
	$(TUIST) generate --no-open

xcconfig-print-env:
	@printf '%s\n' $(XCCONFIG_ENV_PAIRS)
