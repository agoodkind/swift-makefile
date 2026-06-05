# swift-app.mk
#
# Shared packaging for a macOS app that ships as a signed .app inside a .dmg and
# updates through Sparkle. Load it next to swift-build.mk so a consumer Makefile
# keeps only configuration:
#
#   SWIFT_MK_MODULES := swift-build.mk swift-app.mk
#
# swift-build.mk owns `build` (it runs SWIFT_GENERATE_CMD then SWIFT_BUILD_CMD).
# swift-app.mk owns everything after the build: bundle assembly, codesign, dmg,
# and the Sparkle appcast. The build invocation itself stays a consumer hook
# (SWIFT_BUILD_CMD) because the xcodebuild/tuist line differs per project.
#
# Targets:
#   app                     Assemble the built .app into SWIFT_APP_PRODUCTS_DIR and codesign it.
#   dmg                     Stage the app and build a UDZO .dmg (asserts one staged .app).
#   release-assets          Copy the dmg to the versioned release name.
#   prepare-sparkle-updates Run Sparkle generate_appcast over the staged dmg.
#   sparkle-appcast         release-assets then prepare-sparkle-updates.
#   app-coverage-build      Clean Debug build for the dead-code gate's coverage build.
#
# Required:
#   SWIFT_APP_NAME          App identity. Defaults derive bundle, scheme, dmg from it.
#
# Optional (defaults shown):
#   SWIFT_APP_BUNDLE_NAME            ?= $(SWIFT_APP_NAME)         .app basename (display name may differ from SWIFT_APP_NAME)
#   SWIFT_APP_SCHEME                 ?= $(SWIFT_APP_NAME)
#   SWIFT_APP_CONFIGURATION          ?= Release
#   SWIFT_APP_BUILD_DIR              ?= build                     DerivedData path the build writes to
#   SWIFT_APP_PRODUCTS_DIR           ?= Products
#   SWIFT_APP_XCODE_PRODUCTS_DIR     ?= $(SWIFT_APP_BUILD_DIR)/Build/Products/$(SWIFT_APP_CONFIGURATION)
#   SWIFT_APP_BUILT_APP_PATH         ?= $(SWIFT_APP_XCODE_PRODUCTS_DIR)/$(SWIFT_APP_BUNDLE_NAME).app
#   SWIFT_APP_DEST                   ?= $(SWIFT_APP_PRODUCTS_DIR)/$(SWIFT_APP_BUNDLE_NAME).app
#   SWIFT_APP_SIGN_IDENTITY          ?=                          Empty skips all codesign steps
#   SWIFT_APP_SPARKLE_FRAMEWORK      ?= $(SWIFT_APP_DEST)/Contents/Frameworks/Sparkle.framework
#   SWIFT_APP_DMG_VOLUME_NAME        ?= $(SWIFT_APP_NAME)
#   SWIFT_APP_DMG_NAME               ?= $(SWIFT_APP_NAME)-$(SWIFT_APP_CONFIGURATION).dmg
#   SWIFT_APP_DMG_PATH               ?= $(SWIFT_APP_PRODUCTS_DIR)/$(SWIFT_APP_DMG_NAME)
#   SWIFT_APP_DMG_STAGING_DIR        ?= $(SWIFT_APP_BUILD_DIR)/dmg
#   SWIFT_APP_RELEASE_DMG_NAME       ?= $(SWIFT_APP_NAME)-$(CURRENT_PROJECT_VERSION).dmg
#   SWIFT_APP_RELEASE_DMG_PATH       ?= $(SWIFT_APP_PRODUCTS_DIR)/$(SWIFT_APP_RELEASE_DMG_NAME)
#   SWIFT_APP_SPARKLE_UPDATES_DIR    ?= $(SWIFT_APP_BUILD_DIR)/sparkle-updates
#   SWIFT_APP_GITHUB_RELEASE_BASE_URL ?=
#   SWIFT_APP_SPARKLE_APPCAST_TOOL_CMD ?= command -v generate_appcast   Shell command that prints the generate_appcast path
#   SWIFT_APP_COVERAGE_CONFIGURATION ?= Debug
#   SWIFT_APP_COVERAGE_BUILD_CMD     ?= a clean tuist xcodebuild of SWIFT_APP_SCHEME into SWIFT_MK_DERIVED_DATA

TUIST ?= tuist

SWIFT_APP_NAME ?=
SWIFT_APP_BUNDLE_NAME ?= $(SWIFT_APP_NAME)
SWIFT_APP_SCHEME ?= $(SWIFT_APP_NAME)
SWIFT_APP_CONFIGURATION ?= Release
SWIFT_APP_BUILD_DIR ?= build
SWIFT_APP_PRODUCTS_DIR ?= Products
SWIFT_APP_XCODE_PRODUCTS_DIR ?= $(SWIFT_APP_BUILD_DIR)/Build/Products/$(SWIFT_APP_CONFIGURATION)
SWIFT_APP_BUILT_APP_PATH ?= $(SWIFT_APP_XCODE_PRODUCTS_DIR)/$(SWIFT_APP_BUNDLE_NAME).app
SWIFT_APP_DEST ?= $(SWIFT_APP_PRODUCTS_DIR)/$(SWIFT_APP_BUNDLE_NAME).app
SWIFT_APP_SIGN_IDENTITY ?=
SWIFT_APP_SPARKLE_FRAMEWORK ?= $(SWIFT_APP_DEST)/Contents/Frameworks/Sparkle.framework

SWIFT_APP_DMG_VOLUME_NAME ?= $(SWIFT_APP_NAME)
SWIFT_APP_DMG_NAME ?= $(SWIFT_APP_NAME)-$(SWIFT_APP_CONFIGURATION).dmg
SWIFT_APP_DMG_PATH ?= $(SWIFT_APP_PRODUCTS_DIR)/$(SWIFT_APP_DMG_NAME)
SWIFT_APP_DMG_STAGING_DIR ?= $(SWIFT_APP_BUILD_DIR)/dmg

SWIFT_APP_RELEASE_DMG_NAME ?= $(SWIFT_APP_NAME)-$(CURRENT_PROJECT_VERSION).dmg
SWIFT_APP_RELEASE_DMG_PATH ?= $(SWIFT_APP_PRODUCTS_DIR)/$(SWIFT_APP_RELEASE_DMG_NAME)
SWIFT_APP_SPARKLE_UPDATES_DIR ?= $(SWIFT_APP_BUILD_DIR)/sparkle-updates
SWIFT_APP_GITHUB_RELEASE_BASE_URL ?=
SWIFT_APP_SPARKLE_APPCAST_TOOL_CMD ?= command -v generate_appcast

SWIFT_APP_COVERAGE_CONFIGURATION ?= Debug
SWIFT_APP_COVERAGE_BUILD_CMD ?= $(TUIST) xcodebuild build -scheme $(SWIFT_APP_SCHEME) -configuration $(SWIFT_APP_COVERAGE_CONFIGURATION) -derivedDataPath $(SWIFT_MK_DERIVED_DATA) $(SWIFT_MK_XCODEBUILD_ARGS) COMPILER_INDEX_STORE_ENABLE=YES

.PHONY: app app-bundle dmg release-assets prepare-sparkle-updates sparkle-appcast app-coverage-build

# Assemble the freshly built bundle into Products and codesign it. The Sparkle
# helper executables sign first (inside-out) so the outer app signature stays
# valid; each codesign is guarded so a non-Sparkle app skips it.
app-bundle: build
	@if [ -z "$(strip $(SWIFT_APP_NAME))" ]; then echo "swift-app.mk: SWIFT_APP_NAME is not set"; exit 1; fi
	@if [ ! -d "$(SWIFT_APP_BUILT_APP_PATH)" ]; then echo "swift-app.mk: built app not found at $(SWIFT_APP_BUILT_APP_PATH)"; exit 1; fi
	@mkdir -p "$(SWIFT_APP_PRODUCTS_DIR)"
	@rm -rf "$(SWIFT_APP_DEST)"
	@cp -R "$(SWIFT_APP_BUILT_APP_PATH)" "$(SWIFT_APP_DEST)"
	@if [ -n "$(strip $(SWIFT_APP_SIGN_IDENTITY))" ]; then \
		for item in \
			"$(SWIFT_APP_SPARKLE_FRAMEWORK)/Versions/B/Autoupdate" \
			"$(SWIFT_APP_SPARKLE_FRAMEWORK)/Versions/B/Updater.app" \
			"$(SWIFT_APP_SPARKLE_FRAMEWORK)/Versions/B/XPCServices/Downloader.xpc" \
			"$(SWIFT_APP_SPARKLE_FRAMEWORK)/Versions/B/XPCServices/Installer.xpc"; do \
			if [ -e "$$item" ]; then \
				codesign --force --sign "$(SWIFT_APP_SIGN_IDENTITY)" --timestamp --options runtime --preserve-metadata=identifier,entitlements,flags "$$item"; \
			fi; \
		done; \
		if [ -e "$(SWIFT_APP_SPARKLE_FRAMEWORK)" ]; then \
			codesign --force --sign "$(SWIFT_APP_SIGN_IDENTITY)" --timestamp --options runtime --preserve-metadata=identifier,entitlements,flags "$(SWIFT_APP_SPARKLE_FRAMEWORK)"; \
		fi; \
		codesign --force --sign "$(SWIFT_APP_SIGN_IDENTITY)" --timestamp --options runtime --preserve-metadata=identifier,entitlements,flags "$(SWIFT_APP_DEST)"; \
	fi

app: app-bundle

# Stage the assembled app plus an /Applications symlink, assert exactly one app
# bundle is staged, then build a compressed dmg and optionally sign it.
dmg: app
	@mkdir -p "$(SWIFT_APP_PRODUCTS_DIR)" "$(SWIFT_APP_DMG_STAGING_DIR)"
	@rm -rf "$(SWIFT_APP_DMG_STAGING_DIR)/$(SWIFT_APP_BUNDLE_NAME).app" "$(SWIFT_APP_DMG_STAGING_DIR)/Applications" "$(SWIFT_APP_DMG_PATH)"
	@cp -R "$(SWIFT_APP_DEST)" "$(SWIFT_APP_DMG_STAGING_DIR)/"
	@ln -s /Applications "$(SWIFT_APP_DMG_STAGING_DIR)/Applications"
	@staged_count="$$(find "$(SWIFT_APP_DMG_STAGING_DIR)" -maxdepth 1 -name '*.app' | wc -l | tr -d ' ')"; \
	if [ "$$staged_count" != "1" ] || [ ! -d "$(SWIFT_APP_DMG_STAGING_DIR)/$(SWIFT_APP_BUNDLE_NAME).app" ]; then \
		echo "dmg staging error: expected exactly one app bundle ($(SWIFT_APP_BUNDLE_NAME).app) in $(SWIFT_APP_DMG_STAGING_DIR), found $$staged_count:"; \
		find "$(SWIFT_APP_DMG_STAGING_DIR)" -maxdepth 1 -name '*.app'; \
		exit 1; \
	fi
	hdiutil create -volname "$(SWIFT_APP_DMG_VOLUME_NAME)" \
		-srcfolder "$(SWIFT_APP_DMG_STAGING_DIR)" \
		-fs HFS+ \
		-format UDZO \
		-ov "$(SWIFT_APP_DMG_PATH)"
	@if [ -n "$(strip $(SWIFT_APP_SIGN_IDENTITY))" ]; then \
		codesign --force --sign "$(SWIFT_APP_SIGN_IDENTITY)" "$(SWIFT_APP_DMG_PATH)"; \
	fi

release-assets: dmg
	@cp "$(SWIFT_APP_DMG_PATH)" "$(SWIFT_APP_RELEASE_DMG_PATH)"

# Resolve the generate_appcast tool at recipe time (Sparkle installs it under the
# build dir during the build, so it does not exist at parse time).
prepare-sparkle-updates:
	@test -f "$(SWIFT_APP_RELEASE_DMG_PATH)"
	@rm -rf "$(SWIFT_APP_SPARKLE_UPDATES_DIR)"
	@mkdir -p "$(SWIFT_APP_SPARKLE_UPDATES_DIR)"
	@cp "$(SWIFT_APP_RELEASE_DMG_PATH)" "$(SWIFT_APP_SPARKLE_UPDATES_DIR)/"
	@appcast_tool="$$( $(SWIFT_APP_SPARKLE_APPCAST_TOOL_CMD) )"; \
	if [ -z "$$appcast_tool" ]; then echo "prepare-sparkle-updates: could not resolve generate_appcast via SWIFT_APP_SPARKLE_APPCAST_TOOL_CMD"; exit 1; fi; \
	if [ -n "$${SPARKLE_PRIVATE_KEY_FILE:-}" ]; then \
		"$$appcast_tool" --ed-key-file "$${SPARKLE_PRIVATE_KEY_FILE}" --download-url-prefix "$(SWIFT_APP_GITHUB_RELEASE_BASE_URL)" "$(SWIFT_APP_SPARKLE_UPDATES_DIR)"; \
	else \
		"$$appcast_tool" --download-url-prefix "$(SWIFT_APP_GITHUB_RELEASE_BASE_URL)" "$(SWIFT_APP_SPARKLE_UPDATES_DIR)"; \
	fi

sparkle-appcast: release-assets prepare-sparkle-updates

# Clean coverage build for the dead-code gate. Point SWIFT_DEADCODE_BUILD_CMD at
# `$(MAKE) app-coverage-build`. It rebuilds into SWIFT_MK_DERIVED_DATA from clean
# so the index store the gate reads holds no stale units.
app-coverage-build:
	@rm -rf "$(SWIFT_MK_DERIVED_DATA)"
ifneq ($(strip $(SWIFT_GENERATE_CMD)),)
	@$(SWIFT_GENERATE_CMD)
endif
	$(SWIFT_APP_COVERAGE_BUILD_CMD)
