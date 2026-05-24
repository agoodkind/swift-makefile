.PHONY: build deploy run generate clean

build: $(default-build-deps)
ifneq ($(strip $(SWIFT_GENERATE_CMD)),)
	@$(SWIFT_GENERATE_CMD)
endif
ifeq ($(strip $(SWIFT_BUILD_CMD)),)
	@echo "swift-build.mk: SWIFT_BUILD_CMD is not set"; exit 1
else
	@$(SWIFT_BUILD_CMD)
endif

run: build
ifeq ($(strip $(SWIFT_RUN_CMD)),)
	@echo "swift-build.mk: SWIFT_RUN_CMD is not set"; exit 1
else
	@$(SWIFT_RUN_CMD)
endif

generate:
ifeq ($(strip $(SWIFT_GENERATE_CMD)),)
	@echo "generate: no generate command configured"; exit 0
else
	@$(SWIFT_GENERATE_CMD)
endif

deploy:
ifeq ($(strip $(SWIFT_DEPLOY_CMD)),)
	@echo "swift-build.mk: SWIFT_DEPLOY_CMD is not set"; exit 1
else
	@$(SWIFT_DEPLOY_CMD)
endif

clean:
ifneq ($(strip $(SWIFT_CLEAN_CMD)),)
	@$(SWIFT_CLEAN_CMD)
endif
