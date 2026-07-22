# swift-app.mk
#
# Shared packaging for a macOS app that ships as a signed .app inside a .dmg. Load
# it next to swift-build.mk so a consumer Makefile keeps only configuration:
#
#   SWIFT_MK_MODULES := swift-build.mk swift-app.mk
#
# swift-build.mk owns `build` (it runs SWIFT_GENERATE_CMD then SWIFT_BUILD_CMD).
# swift-app.mk owns everything after the build: bundle assembly, codesign, and dmg.
# The build invocation itself stays a consumer hook (SWIFT_BUILD_CMD) because the
# xcodebuild/tuist line differs per project. Framework-specific packaging (for
# example an auto-update framework's inside-out nested signing, or an update feed)
# is a consumer concern: sign nested code at build time with the swift-mk
# codesign-run primitive, and keep any feed generation in the consumer.
#
# Targets:
#   app                     Assemble the built .app into SWIFT_APP_PRODUCTS_DIR and codesign it.
#   dmg                     Stage the app and build a UDZO .dmg (asserts one staged .app).
#   release-assets          Copy the dmg to the versioned release name.
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
#   SWIFT_APP_DMG_VOLUME_NAME        ?= $(SWIFT_APP_NAME)
#   SWIFT_APP_DMG_NAME               ?= $(SWIFT_APP_NAME)-$(SWIFT_APP_CONFIGURATION).dmg
#   SWIFT_APP_DMG_PATH               ?= $(SWIFT_APP_PRODUCTS_DIR)/$(SWIFT_APP_DMG_NAME)
#   SWIFT_APP_DMG_STAGING_DIR        ?= $(SWIFT_APP_BUILD_DIR)/dmg
#   SWIFT_APP_RELEASE_DMG_NAME       ?= $(SWIFT_APP_NAME)-$(CURRENT_PROJECT_VERSION).dmg
#   SWIFT_APP_RELEASE_DMG_PATH       ?= $(SWIFT_APP_PRODUCTS_DIR)/$(SWIFT_APP_RELEASE_DMG_NAME)

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

# Feed the built .app to the build-freshness check (swift-build.mk) so an app
# consumer rebuilds when the bundle is gone, not just when a source changes. Guarded
# on the app path being set so a misconfigured consumer does not record an empty
# product.
ifneq ($(strip $(SWIFT_APP_BUILT_APP_PATH)),)
SWIFT_MK_FRESH_PRODUCTS := $(SWIFT_APP_BUILT_APP_PATH)
endif
SWIFT_APP_SIGN_IDENTITY ?=

SWIFT_APP_DMG_VOLUME_NAME ?= $(SWIFT_APP_NAME)
SWIFT_APP_DMG_NAME ?= $(SWIFT_APP_NAME)-$(SWIFT_APP_CONFIGURATION).dmg
SWIFT_APP_DMG_PATH ?= $(SWIFT_APP_PRODUCTS_DIR)/$(SWIFT_APP_DMG_NAME)
SWIFT_APP_DMG_STAGING_DIR ?= $(SWIFT_APP_BUILD_DIR)/dmg

SWIFT_APP_RELEASE_DMG_NAME ?= $(SWIFT_APP_NAME)-$(CURRENT_PROJECT_VERSION).dmg
SWIFT_APP_RELEASE_DMG_PATH ?= $(SWIFT_APP_PRODUCTS_DIR)/$(SWIFT_APP_RELEASE_DMG_NAME)

.PHONY: app app-bundle dmg release-assets

# Assemble the freshly built bundle into Products and sign the outer app. A
# consumer that embeds a framework with nested signed code signs that nested code
# at build time (through the swift-mk codesign-run primitive), so its signatures
# are already valid inside the copied bundle when the outer app is signed here.
app-bundle: build
	@if [ -z "$(strip $(SWIFT_APP_NAME))" ]; then echo "swift-app.mk: SWIFT_APP_NAME is not set"; exit 1; fi
	@if [ ! -d "$(SWIFT_APP_BUILT_APP_PATH)" ]; then echo "swift-app.mk: built app not found at $(SWIFT_APP_BUILT_APP_PATH)"; exit 1; fi
	@mkdir -p "$(SWIFT_APP_PRODUCTS_DIR)"
	@rm -rf "$(SWIFT_APP_DEST)"
	@cp -R "$(SWIFT_APP_BUILT_APP_PATH)" "$(SWIFT_APP_DEST)"
	@if [ -n "$(strip $(SWIFT_APP_SIGN_IDENTITY))" ]; then \
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
