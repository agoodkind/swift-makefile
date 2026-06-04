.PHONY: build deploy install run generate clean

build: build-check
ifneq ($(strip $(SWIFT_GENERATE_CMD)),)
	@$(SWIFT_GENERATE_CMD)
endif
ifeq ($(strip $(SWIFT_BUILD_CMD)),)
	@echo "swift-build.mk: SWIFT_BUILD_CMD is not set"; exit 1
else
	@$(SWIFT_BUILD_CMD)
endif

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
	@$(SWIFT_DEPLOY_CMD)
endif

install: deploy

clean:
ifneq ($(strip $(SWIFT_CLEAN_CMD)),)
	@$(SWIFT_CLEAN_CMD)
endif
