# bootstrap.mk fetches swift.mk into .make/ and includes it. swift.mk fetches its
# own helper scripts, the shared lint/format/periphery/osv configs, and the
# selected modules, so this stub is the only file a consumer commits and it
# rarely changes. Consumer Makefiles set their project commands and
# SWIFT_MK_MODULES, then include this file.

SWIFT_MK_DEV_DIR ?=
SWIFT_MK := .make/swift.mk
SWIFT_MK_BASE_URL ?= https://raw.githubusercontent.com/agoodkind/swift-makefile/main
SWIFT_MK_API_REPO ?= agoodkind/swift-makefile
SWIFT_MK_API_REF ?= main

# This pre-fetch trace bootstrap is mirrored in swift.mk because the consumer
# bootstrap must run before any fetched script exists.
define swift_mk_trace_bootstrap
$(shell \
swift_mk_is_lower_hex() { \
	value=$$1; \
	expected=$$2; \
	[ -n "$$value" ] || return 1; \
	[ $${#value} -eq "$$expected" ] || return 1; \
	stripped=$$(printf '%s' "$$value" | tr -d '0123456789abcdef'); \
	[ -z "$$stripped" ]; \
}; \
swift_mk_use_traceparent() { \
	candidate=$$1; \
	trace=$${candidate#00-}; \
	[ "$$trace" != "$$candidate" ] || return 1; \
	trace=$${trace%%-*}; \
	remainder=$${candidate#00-$$trace-}; \
	[ "$$remainder" != "$$candidate" ] || return 1; \
	span=$${remainder%%-*}; \
	flags=$${remainder#$$span-}; \
	[ "$$flags" = "01" ] || return 1; \
	swift_mk_is_lower_hex "$$trace" 32 || return 1; \
	swift_mk_is_lower_hex "$$span" 16 || return 1; \
	[ "$$candidate" = "00-$$trace-$$span-01" ] || return 1; \
	traceparent="00-$$trace-$$span-01"; \
}; \
swift_mk_random_hex() { \
	bytes=$$1; \
	expected=16; \
	if [ "$$bytes" = "16" ]; then expected=32; fi; \
	value=""; \
	if command -v openssl >/dev/null 2>&1; then \
		value=$$(openssl rand -hex "$$bytes" 2>/dev/null || true); \
		if swift_mk_is_lower_hex "$$value" "$$expected"; then printf '%s' "$$value"; return 0; fi; \
	fi; \
	if [ -r /dev/urandom ] && command -v od >/dev/null 2>&1; then \
		value=$$(od -An -N "$$bytes" -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'); \
		if swift_mk_is_lower_hex "$$value" "$$expected"; then printf '%s' "$$value"; return 0; fi; \
	fi; \
	if [ -r /dev/urandom ] && command -v hexdump >/dev/null 2>&1; then \
		value=$$(hexdump -n "$$bytes" -e '1/1 "%02x"' /dev/urandom 2>/dev/null); \
		if swift_mk_is_lower_hex "$$value" "$$expected"; then printf '%s' "$$value"; return 0; fi; \
	fi; \
	return 1; \
}; \
log_dir=".make/logs"; \
traceparent_file="$$log_dir/.traceparent"; \
run_file="$$log_dir/.run"; \
make_traceparent="$(TRACEPARENT)"; \
make_trace_id="$(SWIFT_MK_TRACE_ID)"; \
make_span_id="$(SWIFT_MK_SPAN_ID)"; \
traceparent=""; \
trace=""; \
span=""; \
mkdir -p "$$log_dir" || exit 1; \
if swift_mk_use_traceparent "$$make_traceparent"; then \
	:; \
elif swift_mk_use_traceparent "$$TRACEPARENT"; then \
	:; \
elif swift_mk_is_lower_hex "$$make_trace_id" 32 && swift_mk_is_lower_hex "$$make_span_id" 16; then \
	trace=$$make_trace_id; \
	span=$$make_span_id; \
	traceparent="00-$$trace-$$span-01"; \
elif swift_mk_is_lower_hex "$$SWIFT_MK_TRACE_ID" 32 && swift_mk_is_lower_hex "$$SWIFT_MK_SPAN_ID" 16; then \
	trace=$$SWIFT_MK_TRACE_ID; \
	span=$$SWIFT_MK_SPAN_ID; \
	traceparent="00-$$trace-$$span-01"; \
elif [ "$(strip $(SWIFT_MK_SKIP_FETCH))" = "1" ] && [ -s "$$traceparent_file" ]; then \
	IFS= read -r file_traceparent < "$$traceparent_file" || file_traceparent=""; \
	swift_mk_use_traceparent "$$file_traceparent" || traceparent=""; \
fi; \
if [ -z "$$traceparent" ]; then \
	trace=$$(swift_mk_random_hex 16) || exit 1; \
	span=$$(swift_mk_random_hex 8) || exit 1; \
	traceparent="00-$$trace-$$span-01"; \
fi; \
printf '%s\n' "$$traceparent" > "$$traceparent_file" || exit 1; \
previous_run=""; \
if [ -s "$$run_file" ]; then IFS= read -r previous_run < "$$run_file" || previous_run=""; fi; \
if [ "$$previous_run" != "$$trace" ]; then \
	printf '%s\n' "$$trace" > "$$run_file" || exit 1; \
	printf '🔎 logs=.make/logs trace_id=%s span_id=%s\n' "$$trace" "$$span" >&2; \
fi; \
printf 'ok %s %s %s\n' "$$traceparent" "$$trace" "$$span")
endef

SWIFT_MK_TRACE_BOOTSTRAP_RESULT := $(call swift_mk_trace_bootstrap)
$(if $(filter ok,$(word 1,$(SWIFT_MK_TRACE_BOOTSTRAP_RESULT))),,$(error swift-makefile failed to initialize trace))
TRACEPARENT := $(word 2,$(SWIFT_MK_TRACE_BOOTSTRAP_RESULT))
TRACE_ID := $(word 3,$(SWIFT_MK_TRACE_BOOTSTRAP_RESULT))
SPAN_ID := $(word 4,$(SWIFT_MK_TRACE_BOOTSTRAP_RESULT))
SWIFT_MK_TRACE_ID := $(TRACE_ID)
SWIFT_MK_SPAN_ID := $(SPAN_ID)
export TRACEPARENT TRACE_ID SPAN_ID SWIFT_MK_TRACE_ID SWIFT_MK_SPAN_ID

# Fetch a single file from the local swift-makefile checkout (SWIFT_MK_DEV_DIR) or
# GitHub. Used only to obtain swift.mk; swift.mk fetches everything else itself.
define _swift_mk_fetch
	tmp_file=$$(mktemp "$(2).tmp.XXXXXX") || exit 1; \
	trap 'rm -f "$$tmp_file"' EXIT; \
	if [ -n "$(SWIFT_MK_DEV_DIR)" ] && [ -f "$(SWIFT_MK_DEV_DIR)/$(1)" ]; then \
		cp "$(SWIFT_MK_DEV_DIR)/$(1)" "$$tmp_file" && [ -s "$$tmp_file" ] && mv "$$tmp_file" "$(2)"; \
	else \
		gh_path=$$(command -v gh || true); \
		if [ -n "$$gh_path" ] && gh api "repos/$(SWIFT_MK_API_REPO)/contents/$(1)?ref=$(SWIFT_MK_API_REF)" -H "Accept: application/vnd.github.raw" > "$$tmp_file" && [ -s "$$tmp_file" ]; then \
			mv "$$tmp_file" "$(2)"; \
		elif curl -fsSL --connect-timeout 5 --max-time 10 "$(SWIFT_MK_BASE_URL)/$(1)" -o "$$tmp_file" && [ -s "$$tmp_file" ]; then \
			mv "$$tmp_file" "$(2)"; \
		else \
			printf '%s\n' "error: could not fetch $(1) (tried SWIFT_MK_DEV_DIR, gh api, then $(SWIFT_MK_BASE_URL)); check your network connection, and if gh is installed run 'gh auth status'" >&2; \
			exit 1; \
		fi; \
	fi
endef

ifeq ($(strip $(SWIFT_MK_SKIP_FETCH)),1)
$(if $(wildcard $(SWIFT_MK)),,$(error swift-makefile expected $(SWIFT_MK); rerun without SWIFT_MK_SKIP_FETCH))
else
$(if $(filter ok,$(shell mkdir -p .make && if $(call _swift_mk_fetch,swift.mk,$(SWIFT_MK)); then printf ok; else printf fail; fi)),,$(error swift-makefile failed to fetch swift.mk))
endif

-include $(SWIFT_MK)
