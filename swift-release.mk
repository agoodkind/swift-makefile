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
