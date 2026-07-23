.PHONY: release release-check release-snapshot

SWIFT_MK_RELEASE_CHECK_CMD ?=
SWIFT_MK_RELEASE_CMD ?=
SWIFT_MK_RELEASE_SNAPSHOT_CMD ?=

release-check:
	@if [ -z "$(strip $(SWIFT_MK_RELEASE_CHECK_CMD))" ]; then echo "release-check: no release check command configured"; exit 0; fi
	@eval "$(SWIFT_MK_RELEASE_CHECK_CMD)"

release-snapshot:
	@if [ -z "$(strip $(SWIFT_MK_RELEASE_SNAPSHOT_CMD))" ]; then echo "release-snapshot: no snapshot release command configured"; exit 1; fi
	@eval "$(SWIFT_MK_RELEASE_SNAPSHOT_CMD)"

release: release-check
	@if [ -z "$(strip $(SWIFT_MK_RELEASE_CMD))" ]; then echo "release: no release command configured"; exit 1; fi
	@eval "$(SWIFT_MK_RELEASE_CMD)"

# Staged release contract for the shared _release.yml workflow. The workflow
# orchestrates; these targets own the logic, mirroring go-makefile's
# RELEASE_STAGE pattern. release-meta uses swift-mk when available and retains
# a plain-shell fallback, so release-meta and release-publish run on Linux.
.PHONY: release-meta release-build release-publish

SWIFT_MK_DIST_DIR ?= dist
# Consumer hook: build the release artifacts into $(SWIFT_MK_DIST_DIR).
SWIFT_MK_RELEASE_BUILD_CMD ?=
# Optional wholesale override of the tag scheme.
SWIFT_MK_RELEASE_META_CMD ?=
# Optional hook run after the GitHub release is created.
SWIFT_MK_RELEASE_PUBLISH_EXTRA_CMD ?=

# Tag scheme: the pushed tag name when the ref is a tag, else
# <UTC yyyymmddHHMM>-<hex run number>-<short sha>. build_version must fit
# CFBundleVersion's 18-character limit. marketing_version is yy.m.d without
# leading zeros, computed portably (BSD date has no %-m).
release-meta:
	@if [ -n "$(strip $(SWIFT_MK_RELEASE_META_CMD))" ]; then eval "$(SWIFT_MK_RELEASE_META_CMD)"; exit $$?; fi; \
	out="$${GITHUB_OUTPUT:-/dev/stdout}"; \
	if [ -n "$(strip $(SWIFT_MK_BIN))" ] && [ -x "$(SWIFT_MK_BIN)" ]; then \
		"$(SWIFT_MK_BIN)" version-meta >> "$$out"; \
		exit $$?; \
	fi; \
	ts="$$(date -u +%Y%m%d%H%M)"; \
	sha="$$(git rev-parse --short HEAD)"; \
	if [ "$${GITHUB_REF_TYPE:-}" = "tag" ] && [ -n "$${GITHUB_REF_NAME:-}" ]; then \
		tag="$$GITHUB_REF_NAME"; \
	else \
		run_hex="$$(printf '%x' "$${GITHUB_RUN_NUMBER:-0}")"; \
		tag="$$ts-$$run_hex-$$sha"; \
	fi; \
	build_version="$$ts$${GITHUB_RUN_NUMBER:-0}"; \
	if [ "$${#build_version}" -gt 18 ]; then \
		echo "release-meta: build_version $$build_version exceeds CFBundleVersion's 18 chars" >&2; \
		exit 1; \
	fi; \
	year="$$(date -u +%y)"; \
	month="$$(date -u +%m | sed 's/^0//')"; \
	day="$$(date -u +%d | sed 's/^0//')"; \
	marketing_version="$$year.$$month.$$day"; \
	{ \
		echo "tag=$$tag"; \
		echo "build_version=$$build_version"; \
		echo "marketing_version=$$marketing_version"; \
	} >> "$$out"

release-build:
	@if [ -z "$(strip $(SWIFT_MK_RELEASE_BUILD_CMD))" ]; then \
		echo "release-build: set SWIFT_MK_RELEASE_BUILD_CMD to populate $(SWIFT_MK_DIST_DIR)/" >&2; \
		exit 1; \
	fi
	@mkdir -p "$(SWIFT_MK_DIST_DIR)"
	@eval "$(SWIFT_MK_RELEASE_BUILD_CMD)"
	@if [ -z "$$(ls -A '$(SWIFT_MK_DIST_DIR)' 2>/dev/null)" ]; then \
		echo "release-build: SWIFT_MK_RELEASE_BUILD_CMD left $(SWIFT_MK_DIST_DIR)/ empty" >&2; \
		exit 1; \
	fi

release-publish:
	@if [ -z "$${RELEASE_TAG:-}" ]; then echo "release-publish: RELEASE_TAG is not set" >&2; exit 1; fi; \
	git config user.name "github-actions[bot]"; \
	git config user.email "github-actions[bot]@users.noreply.github.com"; \
	if [ "$${GITHUB_REF_TYPE:-}" != "tag" ]; then \
		git tag "$$RELEASE_TAG"; \
		git push origin "$$RELEASE_TAG"; \
	fi; \
	gh release create "$$RELEASE_TAG" $(SWIFT_MK_DIST_DIR)/* \
		--target "$${GITHUB_SHA:-$$(git rev-parse HEAD)}" \
		--title "$$RELEASE_TAG" \
		--notes "Automated release for $${GITHUB_SHA:-$$(git rev-parse HEAD)}"; \
	if [ -n "$(strip $(SWIFT_MK_RELEASE_PUBLISH_EXTRA_CMD))" ]; then eval "$(SWIFT_MK_RELEASE_PUBLISH_EXTRA_CMD)"; fi
