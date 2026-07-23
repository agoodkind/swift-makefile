# swift-makefile's own Makefile. This repo runs its shared Swift targets
# against the root render package and the swiftcheck analyzer package.

SWIFT_MK := swift.mk

# One run trace for every delegated make (root package and swiftcheck/). Minted
# here so ROOT_SWIFT_MK and CHECK_SWIFT_MK adopt the same TRACEPARENT instead of
# each minting under a different cwd (repo root vs swiftcheck/).
ifeq ($(strip $(TRACEPARENT)),)
SWIFT_MK_TRACE_RESULT := $(shell bash scripts/swift-mk-trace.sh)
ifeq ($(word 1,$(SWIFT_MK_TRACE_RESULT)),ok)
TRACEPARENT := $(word 2,$(SWIFT_MK_TRACE_RESULT))
TRACE_ID := $(word 3,$(SWIFT_MK_TRACE_RESULT))
SPAN_ID := $(word 4,$(SWIFT_MK_TRACE_RESULT))
SWIFT_MK_TRACE_ID := $(TRACE_ID)
SWIFT_MK_SPAN_ID := $(SPAN_ID)
endif
endif
export TRACEPARENT TRACE_ID SPAN_ID SWIFT_MK_TRACE_ID SWIFT_MK_SPAN_ID

ROOT_ARGS := \
	SWIFT_MK_DEV_DIR='$(CURDIR)' \
	SWIFT_MK_MODULES='swift-build.mk swift-release.mk' \
	SWIFT_MK_RELEASE_BUILD_CMD='bash scripts/release-build.sh' \
	SWIFT_BUILD_CMD='swift build --product swift-mk-render' \
	SWIFT_TEST_CMD='swift test' \
	SWIFT_VERIFY_BUILD_CMD='swift build --configuration release --build-tests -Xswiftc -enable-testing' \
	SWIFT_VERIFY_TEST_CMD='swift test --configuration release --skip-build --no-parallel' \
	SWIFT_FORMAT_TARGETS='Package.swift Sources Tests' \
	SWIFTLINT_TARGETS='Package.swift Sources Tests' \
	PERIPHERY_ARGS='scan --config .periphery.yml --exclude-tests' \
	SWIFTCHECK_EXTRA_EXCLUDE_PATHS='Sources/SwiftMkCore/Toolchain.swift,Sources/SwiftMkCore/Toolchain\+Generate\.swift,Sources/SwiftMkCore/Toolchain\+TuistCache\.swift,Sources/SwiftMkCore/BuildToolingAudit.swift,Sources/SwiftMkCore/SwiftPM.swift,Tests/SwiftMkCoreTests/ToolchainTests.swift,Tests/SwiftMkCoreTests/BuildToolingAuditTests.swift,Tests/SwiftMkCoreTests/SwiftPMTests.swift' \
	SWIFTCHECK_EXTRA_BUILD_REPO='$(CURDIR)/swiftcheck'

# SWIFT_MK_ROOT pins logging and the trace sentinel to the repo root even when
# make -C swiftcheck changes the process cwd, so CHECK joins the same .make/logs
# and does not print a second header for the same TRACEPARENT.
CHECK_ARGS := \
	SWIFT_MK_ROOT='$(CURDIR)' \
	SWIFT_MK_DEV_DIR='$(CURDIR)' \
	SWIFT_MK_MODULES=swift-build.mk \
	SWIFT_BUILD_CMD='swift build --product swiftcheck-extra' \
	SWIFT_TEST_CMD='swift test' \
	SWIFT_VERIFY_BUILD_CMD='swift build --configuration release --build-tests -Xswiftc -enable-testing' \
	SWIFT_VERIFY_TEST_CMD='swift test --configuration release --skip-build --no-parallel' \
	SWIFT_FORMAT_TARGETS='Package.swift Sources Tests' \
	SWIFTLINT_TARGETS='Package.swift Sources Tests' \
	SWIFT_MK_SWIFTLINT_CONFIG='../.swiftlint.yml' \
	SWIFT_MK_SWIFT_FORMAT_CONFIG='../.swift-format' \
	SWIFT_MK_PERIPHERY_CONFIG='../.periphery.yml' \
	SWIFTLINT_FLAGS='--config ../.swiftlint.yml --reporter xcode' \
	PERIPHERY_ARGS='scan --config ../.periphery.yml --exclude-tests' \
	SWIFT_MK_BIN='$(or $(SWIFT_MK_BIN),$(CURDIR)/.make/swift-mk)' \
	SWIFTCHECK_EXTRA_BUILD_REPO='$(CURDIR)/swiftcheck'

ROOT_SWIFT_MK := $(MAKE) -f $(SWIFT_MK) $(ROOT_ARGS)
CHECK_SWIFT_MK := $(MAKE) -C swiftcheck -f ../$(SWIFT_MK) $(CHECK_ARGS)

.DEFAULT_GOAL := check

.PHONY: build verify check lint fmt test analyze audit build-check lint-tools \
	quality-guard \
	lint-swiftlint lint-format lint-complexity lint-deadcode swiftcheck-extra \
	lint-swiftlint-baseline lint-swiftlint-baseline-prune-fixed lint-swiftlint-baseline-remove-fixed lint-swiftlint-baseline-accept-new \
	lint-swiftlint-scope lint-swiftlint-baseline-scope lint-swiftlint-baseline-scope-accept-new \
	lint-complexity-baseline lint-complexity-baseline-prune-fixed lint-complexity-baseline-remove-fixed lint-complexity-baseline-accept-new \
	lint-deadcode-baseline lint-deadcode-baseline-prune-fixed lint-deadcode-baseline-remove-fixed lint-deadcode-baseline-accept-new \
	swiftcheck-extra-baseline swiftcheck-extra-baseline-prune-fixed swiftcheck-extra-baseline-remove-fixed swiftcheck-extra-baseline-accept-new \
	baseline baseline-prune-fixed baseline-remove-fixed baseline-accept-new baseline-add-new \
	update-swift-mk swift-mk-sync smoke-fetch update-consumers update-consumers-dry-run help xcode-file-header \
	release-meta release-build release-publish

build:
	$(ROOT_SWIFT_MK) xcode-file-header build
	$(CHECK_SWIFT_MK) build

verify:
	$(ROOT_SWIFT_MK) verify
	$(CHECK_SWIFT_MK) verify

build-check:
	$(ROOT_SWIFT_MK) build-check
	$(CHECK_SWIFT_MK) build-check

lint:
	$(ROOT_SWIFT_MK) lint
	$(CHECK_SWIFT_MK) lint

lint-tools:
	$(ROOT_SWIFT_MK) lint-tools

quality-guard:
	$(ROOT_SWIFT_MK) quality-guard
	$(CHECK_SWIFT_MK) quality-guard

lint-swiftlint:
	$(ROOT_SWIFT_MK) lint-swiftlint
	$(CHECK_SWIFT_MK) lint-swiftlint

lint-swiftlint-baseline:
	$(ROOT_SWIFT_MK) lint-swiftlint-baseline
	$(CHECK_SWIFT_MK) lint-swiftlint-baseline

lint-swiftlint-baseline-prune-fixed:
	$(ROOT_SWIFT_MK) lint-swiftlint-baseline-prune-fixed
	$(CHECK_SWIFT_MK) lint-swiftlint-baseline-prune-fixed

lint-swiftlint-baseline-remove-fixed: lint-swiftlint-baseline-prune-fixed

lint-swiftlint-baseline-accept-new:
	$(ROOT_SWIFT_MK) lint-swiftlint-baseline-accept-new
	$(CHECK_SWIFT_MK) lint-swiftlint-baseline-accept-new

lint-swiftlint-scope:
	$(ROOT_SWIFT_MK) lint-swiftlint-scope
	$(CHECK_SWIFT_MK) lint-swiftlint-scope

lint-swiftlint-baseline-scope:
	$(ROOT_SWIFT_MK) lint-swiftlint-baseline-scope
	$(CHECK_SWIFT_MK) lint-swiftlint-baseline-scope

lint-swiftlint-baseline-scope-accept-new:
	$(ROOT_SWIFT_MK) lint-swiftlint-baseline-scope-accept-new
	$(CHECK_SWIFT_MK) lint-swiftlint-baseline-scope-accept-new

lint-format:
	$(ROOT_SWIFT_MK) lint-format
	$(CHECK_SWIFT_MK) lint-format

lint-complexity:
	$(ROOT_SWIFT_MK) lint-complexity
	$(CHECK_SWIFT_MK) lint-complexity

lint-complexity-baseline:
	$(ROOT_SWIFT_MK) lint-complexity-baseline
	$(CHECK_SWIFT_MK) lint-complexity-baseline

lint-complexity-baseline-prune-fixed:
	$(ROOT_SWIFT_MK) lint-complexity-baseline-prune-fixed
	$(CHECK_SWIFT_MK) lint-complexity-baseline-prune-fixed

lint-complexity-baseline-remove-fixed: lint-complexity-baseline-prune-fixed

lint-complexity-baseline-accept-new:
	$(ROOT_SWIFT_MK) lint-complexity-baseline-accept-new
	$(CHECK_SWIFT_MK) lint-complexity-baseline-accept-new

lint-deadcode:
	$(ROOT_SWIFT_MK) lint-deadcode
	$(CHECK_SWIFT_MK) lint-deadcode

lint-deadcode-baseline:
	$(ROOT_SWIFT_MK) lint-deadcode-baseline
	$(CHECK_SWIFT_MK) lint-deadcode-baseline

lint-deadcode-baseline-prune-fixed:
	$(ROOT_SWIFT_MK) lint-deadcode-baseline-prune-fixed
	$(CHECK_SWIFT_MK) lint-deadcode-baseline-prune-fixed

lint-deadcode-baseline-remove-fixed: lint-deadcode-baseline-prune-fixed

lint-deadcode-baseline-accept-new:
	$(ROOT_SWIFT_MK) lint-deadcode-baseline-accept-new
	$(CHECK_SWIFT_MK) lint-deadcode-baseline-accept-new

swiftcheck-extra:
	$(ROOT_SWIFT_MK) swiftcheck-extra
	$(CHECK_SWIFT_MK) swiftcheck-extra

swiftcheck-extra-baseline:
	$(ROOT_SWIFT_MK) swiftcheck-extra-baseline
	$(CHECK_SWIFT_MK) swiftcheck-extra-baseline

swiftcheck-extra-baseline-prune-fixed:
	$(ROOT_SWIFT_MK) swiftcheck-extra-baseline-prune-fixed
	$(CHECK_SWIFT_MK) swiftcheck-extra-baseline-prune-fixed

swiftcheck-extra-baseline-remove-fixed: swiftcheck-extra-baseline-prune-fixed

swiftcheck-extra-baseline-accept-new:
	$(ROOT_SWIFT_MK) swiftcheck-extra-baseline-accept-new
	$(CHECK_SWIFT_MK) swiftcheck-extra-baseline-accept-new

fmt:
	$(ROOT_SWIFT_MK) fmt
	$(CHECK_SWIFT_MK) fmt

test:
	$(ROOT_SWIFT_MK) test
	$(CHECK_SWIFT_MK) test

analyze:
	$(ROOT_SWIFT_MK) analyze
	$(CHECK_SWIFT_MK) analyze

audit:
	$(ROOT_SWIFT_MK) audit
	$(CHECK_SWIFT_MK) audit

baseline:
	$(ROOT_SWIFT_MK) baseline
	$(CHECK_SWIFT_MK) baseline

baseline-prune-fixed:
	$(ROOT_SWIFT_MK) baseline-prune-fixed
	$(CHECK_SWIFT_MK) baseline-prune-fixed

baseline-remove-fixed: baseline-prune-fixed

baseline-accept-new:
	$(ROOT_SWIFT_MK) baseline-accept-new
	$(CHECK_SWIFT_MK) baseline-accept-new

baseline-add-new: baseline-accept-new

update-swift-mk swift-mk-sync:
	$(ROOT_SWIFT_MK) update-swift-mk

smoke-fetch:
	$(ROOT_SWIFT_MK) smoke-fetch

update-consumers:
	$(ROOT_SWIFT_MK) update-consumers

update-consumers-dry-run:
	$(ROOT_SWIFT_MK) update-consumers-dry-run

check: lint
	$(ROOT_SWIFT_MK) xcode-file-header

# swift-makefile stamps its own Xcode file-header macros on every build from the
# current git identity. Consumers invoke this target on demand instead. The build
# recipe runs it in the same `make -f swift.mk` invocation as `build` so one
# parse-time trace header covers both goals.
xcode-file-header:
	$(ROOT_SWIFT_MK) xcode-file-header

release-meta release-build release-publish:
	$(ROOT_SWIFT_MK) $@

help:
	$(ROOT_SWIFT_MK) help
