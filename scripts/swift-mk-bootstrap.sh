#!/usr/bin/env bash
# The bootstrap script provisions the swift-makefile engine snapshot into .make.
#
# Fetch policy is defined in this fetched script instead of the bootstrap.mk
# copy each consumer commits. bootstrap.mk delegates fetching to this script.
# Each consumer receives policy changes on its next parse without a pull request.
#
# The script extracts one tarball into a temporary directory and verifies the
# required assets before replacing .make. The script removes the previous .make
# tree only after the replacement passes verification.
#
# The script executes from a temporary copy because provisioning replaces the
# installed script inside .make. Bash can misread remaining bytes when its
# running script file is rewritten.

set -euo pipefail

SWIFT_MK_API_REPO="${SWIFT_MK_API_REPO:-agoodkind/swift-makefile}"
SWIFT_MK_API_REF="${SWIFT_MK_API_REF:-main}"
# SWIFT_MK_CODELOAD_BASE is an internal override like SWIFT_MK_API_REPO and
# SWIFT_MK_API_REF. Tests use a local server; consumers never set the override.
SWIFT_MK_CODELOAD_BASE="${SWIFT_MK_CODELOAD_BASE:-https://codeload.github.com}"
SWIFT_MK_DEV_DIR="${SWIFT_MK_DEV_DIR:-}"
SWIFT_MK_MODULES="${SWIFT_MK_MODULES:-}"

MAKE_DIR=".make"
# FETCH_MAX_TIME bounds transfers that continue above the low-speed threshold.
# FETCH_SPEED_LIMIT and FETCH_SPEED_TIME abort stalled transfers sooner.
# Measured codeload downloads took 2.06-2.4 seconds on a good link.
# The 15-second limit is about six times that duration to allow slower or
# roaming links.
FETCH_MAX_TIME=15
FETCH_CONNECT_TIMEOUT=2
# curl aborts after FETCH_SPEED_TIME seconds below FETCH_SPEED_LIMIT instead
# of waiting for FETCH_MAX_TIME. Measurements recorded 3.0-second aborts for
# servers that accepted connections but stalled or never sent headers, compared
# with 30.0 seconds or more without the flags. A measured 2 KB/s transfer
# completed above the 1 KB/s floor.
FETCH_SPEED_LIMIT=1024
FETCH_SPEED_TIME=3
MARKER_PATH="${MAKE_DIR}/.swift-mk-snapshot-ref"
VALIDATION_CONNECT_TIMEOUT=2
VALIDATION_MAX_TIME=3
REUSE_WINDOW_SECONDS=3600

# LOCK_DIR serializes concurrent parses of one consumer directory.
# A process owns the lock while its owner file is the only owner record
# in LOCK_DIR.
#
# The lock directory is outside .make, under the temporary directory.
# The directory suffix uses a digest of the consumer's absolute path, or a
# sanitized path when no digest tool exists. Creating or removing a lock inside
# .make would change .make's directory mtime even after a 304 response.
# The 304 response requires no writes under .make.
#
# Each consumer path has a separate lock. Reboots end every parse, so the
# temporary lock does not need to survive a reboot.
swift_mk_lock_dir() {
    local consumer_path
    local digest
    consumer_path=$(pwd -P)
    if command -v shasum >/dev/null 2>&1; then
        digest=$(printf '%s' "${consumer_path}" | shasum | cut -d' ' -f1)
    elif command -v sha1sum >/dev/null 2>&1; then
        digest=$(printf '%s' "${consumer_path}" | sha1sum | cut -d' ' -f1)
    else
        # The sanitized name provides a lock when no digest tool is available.
        # Without a lock, concurrent parses of one consumer could run unserialized.
        # Different consumer paths can share a sanitized name.
        # A shared name makes one consumer wait for the other.
        digest=$(printf '%s' "${consumer_path}" | tr -c 'A-Za-z0-9' '-')
    fi
    printf '%s/swift-mk-lock-%s' "${TMPDIR:-/tmp}" "${digest}"
}
LOCK_DIR=$(swift_mk_lock_dir)
# Provisioning measures a few seconds. The timeout allows extra time.
# A wait that exhausts the timeout indicates a problem rather than slow
# provisioning.
LOCK_WAIT_SECONDS=30
LOCK_OWNER_FILE=""
# The process name in field 2 can contain spaces and parentheses.
# Deleting through the last ) makes start time at field 22 zero-based index 19.
PROC_STAT_START_FIELD_INDEX=19
UNKNOWN_START_TOKEN="unknown"
LOCK_DIR_CREATE_ATTEMPTS=3

# Linux start tokens are clock ticks since boot from /proc/<pid>/stat.
# Wall clock changes do not change those ticks.
# Without /proc, process_start_token prints ps lstart.
# The function prints an empty string when neither source gives a value.
process_start_token() {
    local pid="$1"
    local stat_path="/proc/${pid}/stat"
    local stat_text=""
    local ps_output=""
    local ps_status=0
    local -a stat_fields=()
    if [[ -r "${stat_path}" ]]; then
        if ! stat_text=$(cat "${stat_path}"); then
            printf 'swift-mk: could not read %s for the start time of process %s\n' \
                "${stat_path}" "${pid}" >&2
            return 0
        fi
        stat_text="${stat_text##*)}"
        read -r -a stat_fields <<<"${stat_text}"
        printf '%s' "${stat_fields[PROC_STAT_START_FIELD_INDEX]:-}"
        return 0
    fi
    ps_output=$(LC_ALL=C ps -o lstart= -p "${pid}") || ps_status=$?
    if [[ ${ps_status} -ne 0 ]]; then
        printf 'swift-mk: could not read the start time of process %s (ps exit %d)\n' \
            "${pid}" "${ps_status}" >&2
        return 0
    fi
    printf '%s' "${ps_output}" | tr -cd 'A-Za-z0-9'
    return 0
}

# The lock protects marker reads and subsequent writes under .make until
# process exit.
#
# Concurrent parses can mix two archive trees because each parse stages and
# swaps an archive using .make.next and .make.previous. The last marker write
# records one archive's ETag. Later non-CI parses can reuse the mixed tree
# indefinitely on 304 responses if the asset checks pass and the upstream
# ETag remains unchanged. Both parses can exit 0 without reporting the mixed tree.
#
# macOS does not ship flock.
# At most one contender returns 0 because the later file creator lists
# the other contender's owner record.
# Removing a contender's own record before waiting limits interference
# with the owner and other waiters to one attempt.
# Dead processes cannot delete their owner files.
# acquire_lock reclaims a record when kill -0 reports its PID as not running.
# The operating system can reuse a dead owner's PID for an unrelated process.
# Owner file names use owner.<pid>.<start_token>.<random>.
# acquire_lock reclaims records when the running process's start token differs.
# Unique names prevent delayed deletion of another process's record.
# acquire_lock counts pid as another owner record and reads its PID from
# the first field.
acquire_lock() {
    local waited=0
    local mkdir_error=""
    local owner_file=""
    local record_path=""
    local record_name=""
    local record_content=""
    local record_pid=""
    local record_token=""
    local current_token=""
    local own_token=""
    local other_count=0
    local create_failures=0
    local removed_dead_record=0
    local -a other_records=()
    own_token=$(process_start_token "$$")
    if [[ -z "${own_token}" ]]; then
        own_token="${UNKNOWN_START_TOKEN}"
    fi
    while true; do
        # Only contention on an existing lock warrants waiting. A missing or
        # unwritable TMPDIR is a local setup problem. Waiting for that failure would
        # report a lock conflict instead of the creation error.
        if ! mkdir_error=$(mkdir "${LOCK_DIR}" 2>&1); then
            if [[ ! -d "${LOCK_DIR}" ]]; then
                # A releasing process can remove the empty directory between mkdir's failure
                # and the directory test. Retry up to LOCK_DIR_CREATE_ATTEMPTS before reporting
                # a local setup problem.
                create_failures=$(( create_failures + 1 ))
                if (( create_failures < LOCK_DIR_CREATE_ATTEMPTS )); then
                    continue
                fi
                printf 'error: could not create the lock directory %s: %s. This is a local setup problem, not another build holding the lock.\n' \
                    "${LOCK_DIR}" "${mkdir_error}" >&2
                return 1
            fi
        fi
        create_failures=0

        owner_file="${LOCK_DIR}/owner.$$.${own_token}.${RANDOM}${RANDOM}"
        if ! printf '' 2>/dev/null >"${owner_file}"; then
            if [[ ! -d "${LOCK_DIR}" ]]; then
                continue
            fi
            printf 'error: could not record the lock holder in %s: a local setup problem, not a lock conflict\n' \
                "${LOCK_DIR}" >&2
            return 1
        fi
        LOCK_OWNER_FILE="${owner_file}"

        other_records=()
        other_count=0
        for record_path in "${LOCK_DIR}"/owner.* "${LOCK_DIR}/pid"; do
            if [[ ! -e "${record_path}" ]]; then
                continue
            fi
            if [[ "${record_path}" == "${LOCK_OWNER_FILE}" ]]; then
                continue
            fi
            other_records[other_count]="${record_path}"
            other_count=$(( other_count + 1 ))
        done

        if (( other_count == 0 )); then
            return 0
        fi

        rm -f "${LOCK_OWNER_FILE}"
        LOCK_OWNER_FILE=""
        removed_dead_record=0
        for record_path in "${other_records[@]}"; do
            record_name="${record_path##*/}"
            if [[ "${record_name}" == "pid" ]]; then
                record_content=$(cat "${record_path}" 2>/dev/null || printf '')
                read -r record_pid _ <<<"${record_content}"
            else
                record_pid="${record_name#owner.}"
                record_pid="${record_pid%%.*}"
            fi
            if [[ ! "${record_pid}" =~ ^[0-9]+$ ]]; then
                continue
            fi
            if kill -0 "${record_pid}" 2>/dev/null; then
                if [[ "${record_name}" == "pid" ]]; then
                    continue
                fi
                record_token="${record_name#owner.*.}"
                record_token="${record_token%%.*}"
                if [[ "${record_token}" == "${UNKNOWN_START_TOKEN}" ]]; then
                    continue
                fi
                current_token=$(process_start_token "${record_pid}")
                if [[ -z "${current_token}" ]]; then
                    continue
                fi
                if [[ "${current_token}" == "${record_token}" ]]; then
                    continue
                fi
            fi
            if rm -f "${record_path}"; then
                removed_dead_record=1
            fi
        done
        if (( removed_dead_record == 1 )); then
            continue
        fi

        if (( waited >= LOCK_WAIT_SECONDS )); then
            printf 'error: another swift-makefile parse has held %s for %ss. If no other build is running, remove that directory.\n' \
                "${LOCK_DIR}" "${LOCK_WAIT_SECONDS}" >&2
            return 1
        fi
        # The random fraction gives waiters different retry times because equal
        # retry times can make each waiter list the other's file on every attempt.
        sleep "1.$(( RANDOM % 10 ))"
        waited=$(( waited + 1 ))
    done
}

release_lock() {
    if [[ -n "${LOCK_OWNER_FILE}" ]]; then
        rm -f "${LOCK_OWNER_FILE}"
    fi
    rmdir "${LOCK_DIR}" 2>/dev/null || true
}

# The temporary copy prevents replacement of the original script from
# disrupting execution.
# The guard prevents recursive re-execution.
reexec_from_temp_copy() {
    local temp_copy
    if [[ -n "${SWIFT_MK_BOOTSTRAP_REEXEC:-}" ]]; then
        return 0
    fi
    temp_copy=$(mktemp "${TMPDIR:-/tmp}/swift-mk-bootstrap.XXXXXXXX") || return 1
    cp "$0" "${temp_copy}"
    chmod +x "${temp_copy}"
    SWIFT_MK_BOOTSTRAP_REEXEC=1 exec bash "${temp_copy}" "$@"
}

# Failure messages use stderr excerpts to distinguish a 403 body, a DNS
# error, and a tar format error.
stderr_sample() {
    tr '\n' ' ' < "$1" | cut -c1-200
}

required_assets() {
    printf '%s\n' "swift.mk"
    printf '%s\n' "Package.swift"
    printf '%s\n' "scripts/swift-mk-build.sh"
    # A matching etag can prevent re-provisioning when assets_complete accepts
    # a tree with a missing or stale bootstrap helper.
    # The consumer can continue executing its existing helper after an upstream
    # update if the required assets omit the bootstrap successor.
    printf '%s\n' "scripts/swift-mk-bootstrap.sh"
    local module_name
    for module_name in ${SWIFT_MK_MODULES}; do
        printf '%s\n' "${module_name}"
    done
}

assets_complete() {
    local base_dir="$1"
    local asset_name
    local asset_path
    while IFS= read -r asset_name; do
        asset_path="${base_dir}/${asset_name}"
        # A required asset that is a directory can pass the -s check.
        if [[ ! -f "${asset_path}" || ! -s "${asset_path}" ]]; then
            return 1
        fi
    done < <(required_assets)
    return 0
}

# HTTP 403 responses, DNS failures, and corrupt archives produce distinct
# diagnostics from HTTP statuses, command exit codes, and short stderr excerpts.
# stage_fetch_and_verify does not modify .make.
stage_fetch_and_verify() {
    local stage_root="$1"
    local stage_dir="$2"
    local url="${SWIFT_MK_CODELOAD_BASE}/${SWIFT_MK_API_REPO}/tar.gz/${SWIFT_MK_API_REF}"
    local curl_log="${stage_root}/curl.log"
    local tar_log="${stage_root}/tar.log"
    local status_code
    local curl_status=0
    local tar_status=0

    # curl aborts stalled transfers once throughput averages below
    # FETCH_SPEED_LIMIT bytes per second for FETCH_SPEED_TIME seconds.
    # The speed timeout avoids waiting for --max-time to expire.
    # --max-time bounds transfers that continue making slow progress.
    status_code=$(curl -sS --connect-timeout "${FETCH_CONNECT_TIMEOUT}" \
        --speed-limit "${FETCH_SPEED_LIMIT}" --speed-time "${FETCH_SPEED_TIME}" \
        --max-time "${FETCH_MAX_TIME}" \
        -D "${stage_root}/headers" \
        -o "${stage_root}/snapshot.tar.gz" -w '%{http_code}' \
        "${url}" 2>"${curl_log}") || curl_status=$?
    if [[ ${curl_status} -ne 0 ]]; then
        printf 'error: fetch failed (curl exit %d) for %s: %s\n' \
            "${curl_status}" "${url}" "$(stderr_sample "${curl_log}")" >&2
        return 1
    fi
    if [[ "${status_code}" != "200" ]]; then
        printf 'error: fetch returned HTTP %s for %s\n' "${status_code}" "${url}" >&2
        return 1
    fi

    if ! mkdir -p "${stage_dir}"; then
        printf 'error: could not create %s\n' "${stage_dir}" >&2
        return 1
    fi
    tar -xzf "${stage_root}/snapshot.tar.gz" -C "${stage_dir}" --strip-components 1 \
        2>"${tar_log}" || tar_status=$?
    if [[ ${tar_status} -ne 0 ]]; then
        printf 'error: tar extraction failed (exit %d): %s\n' \
            "${tar_status}" "$(stderr_sample "${tar_log}")" >&2
        return 1
    fi
    if ! assets_complete "${stage_dir}"; then
        printf 'error: fetched snapshot is missing a required asset\n' >&2
        return 1
    fi
    return 0
}

# The snapshot includes the engine's config dotfiles. Local copies provide
# swift.mk's renamed config targets without five to eight network fetches on
# every parse.
# install_renamed_configs runs after every successful install and on main's
# 304 and offline-reuse paths. The reuse paths do not call install_from_stage.
# A consumer with a valid marker does not re-provision. The reuse paths create
# renamed targets for consumers with valid markers.
# swift.mk's wildcard guards fetch each missing config over the network when
# the snapshot lacks its source.
#
# Config copy failures do not roll back an install because required_assets
# excludes these targets and swift.mk's wildcard guards fetch missing targets.
# The chmod step in install_from_stage also uses best-effort error handling.
# Each copy failure produces a warning. A failed pair does not prevent attempts
# to copy later pairs.
install_renamed_configs() {
    local pair
    local source_name
    local target_path
    for pair in \
        ".swiftlint.yml:${MAKE_DIR}/swiftlint.yml" \
        ".swift-format:${MAKE_DIR}/swift-format.json" \
        ".periphery.yml:${MAKE_DIR}/periphery.yml" \
        "osv-scanner.toml:${MAKE_DIR}/osv-scanner.toml" \
        "mise.toml:.config/mise/conf.d/swift-mk.toml"; do
        source_name="${pair%%:*}"
        target_path="${pair#*:}"
        if [[ ! -s "${MAKE_DIR}/${source_name}" ]]; then
            continue
        fi
        if ! mkdir -p "$(dirname "${target_path}")"; then
            printf 'warning: could not create %s for the renamed config copy; swift.mk will fetch %s over the network instead\n' \
                "$(dirname "${target_path}")" "${target_path}" >&2
            continue
        fi
        if ! cp "${MAKE_DIR}/${source_name}" "${target_path}"; then
            printf 'warning: could not copy %s to %s; swift.mk will fetch it over the network instead\n' \
                "${MAKE_DIR}/${source_name}" "${target_path}" >&2
        fi
    done
}

# install_from_stage stages the replacement beside .make and preserves the
# generated runtime files that builds require. snapshot_clear_engine in
# scripts/swift-mk-sync.sh preserves the same files.
# install_from_stage swaps the verified replacement into .make with mv.
# install_from_stage does not remove files under .make until the replacement
# is fully staged and verified. A partial cp failure or another failure before
# the final mv does not change the existing .make.
#
# Bash suppresses -e throughout a command used as an if or while condition,
# including every function and subshell called from that command.
# install_from_stage executes within `if provision; then`. Each fallible step
# checks its status explicitly and returns 1 on failure.
install_from_stage() {
    local stage_dir="$1"
    local next_dir="${MAKE_DIR}.next"
    local previous_dir="${MAKE_DIR}.previous"
    local cp_log
    local cp_status=0
    local clear_log
    local clear_status=0
    local preserved_path
    local preserve_list
    local preserve_log
    cp_log="$(dirname "${stage_dir}")/install-cp.log"
    clear_log="$(dirname "${stage_dir}")/clear-stage.log"
    preserve_list="$(dirname "${stage_dir}")/preserve.list"
    preserve_log="$(dirname "${stage_dir}")/preserve.log"

    # The rm status check prevents a partial removal failure from producing a
    # successful install with stale content. rm can fail on a locked or immutable
    # file from a previous run. mkdir -p accepts a surviving next_dir directory.
    # cp -R adds new files without deleting stale files. Both assets_complete
    # checks can pass when every required asset exists alongside stale content.
    rm -rf "${next_dir}" "${previous_dir}" 2>"${clear_log}" || clear_status=$?
    if [[ ${clear_status} -ne 0 ]]; then
        printf 'error: could not clear stale staging directories %s and %s (rm exit %d): %s\n' \
            "${next_dir}" "${previous_dir}" "${clear_status}" "$(stderr_sample "${clear_log}")" >&2
        return 1
    fi

    if ! mkdir -p "${next_dir}"; then
        printf 'error: could not create staging directory %s\n' "${next_dir}" >&2
        return 1
    fi

    if [[ -d "${MAKE_DIR}" ]]; then
        # The enumeration is captured and its exit status checked BEFORE the loop
        # rather than being read straight from a process substitution. A process
        # substitution's exit status is invisible to the reading loop: if find
        # fails, the loop simply sees no input, every preserved file is silently
        # skipped, and the swap below then replaces .make without them. That
        # loses the live build.lock while a build holds it, so the running build
        # keeps the old inode while the next build creates and locks a new one
        # and the per-worktree lock stops serializing anything.
        #
        # .gate is preserved for the same reason: a consumer's generate step
        # recurses into make, and when that nested run finds a new engine ref it
        # stages a fresh tree and swaps .make wholesale. The swap keeps only what
        # this list names, so an unlisted .gate/stamp is destroyed in the middle of
        # the gated build that wrote it. Every later compile then reports no proof
        # and takes the decoupled path, which runs the hard gate on a release
        # runner that installs no lint tooling, so the release fails on missing
        # binaries rather than on a finding. The sibling allowlist in
        # scripts/swift-mk-sync.sh guards the same runtime state on the clear path;
        # a name added there belongs here too.
        if ! find "${MAKE_DIR}" -mindepth 1 -maxdepth 1 \
            \( -name logs -o -name build.lock -o -name swift-mk -o -name swift-mk.key \
               -o -name '*.bundle' \
               -o -name swift-mk-build -o -name dev -o -name .swift-mk-snapshot-ref \
               -o -name .gate -o -name signing.xcconfig \
               -o -name swift.mk -o -name '*.log' \) -print0 \
            > "${preserve_list}" 2>"${preserve_log}"; then
            printf 'error: could not enumerate the runtime files to preserve (find failed): %s\n' \
                "$(stderr_sample "${preserve_log}")" >&2
            rm -rf "${next_dir}"
            return 1
        fi
        while IFS= read -r -d '' preserved_path; do
            if ! cp -R "${preserved_path}" "${next_dir}/"; then
                printf 'error: could not preserve %s while staging the engine tree\n' \
                    "${preserved_path}" >&2
                rm -rf "${next_dir}"
                return 1
            fi
        done < "${preserve_list}"
    fi

    cp -R "${stage_dir}/." "${next_dir}/" 2>"${cp_log}" || cp_status=$?
    if [[ ${cp_status} -ne 0 ]]; then
        printf 'error: staging the engine tree failed (cp exit %d): %s\n' \
            "${cp_status}" "$(stderr_sample "${cp_log}")" >&2
        rm -rf "${next_dir}"
        return 1
    fi

    # chmod is best effort because a build reports an execution error when
    # the build tries to execute a script that chmod could not make executable.
    find "${next_dir}/scripts" -type f -name '*.sh' -exec chmod +x {} + 2>/dev/null || true

    if ! assets_complete "${next_dir}"; then
        printf 'error: staged engine tree is missing a required asset after copy\n' >&2
        rm -rf "${next_dir}"
        return 1
    fi

    if [[ -d "${MAKE_DIR}" ]]; then
        if ! mv "${MAKE_DIR}" "${previous_dir}"; then
            printf 'error: could not move the current .make aside for the swap\n' >&2
            rm -rf "${next_dir}"
            return 1
        fi
    fi

    if ! mv "${next_dir}" "${MAKE_DIR}"; then
        printf 'error: could not swap the staged engine tree into .make\n' >&2
        if [[ -d "${previous_dir}" ]]; then
            mv "${previous_dir}" "${MAKE_DIR}"
        fi
        rm -rf "${next_dir}"
        return 1
    fi

    if ! assets_complete "${MAKE_DIR}"; then
        printf 'error: .make is missing a required asset after the swap\n' >&2
        if [[ -d "${previous_dir}" ]]; then
            rm -rf "${MAKE_DIR}"
            mv "${previous_dir}" "${MAKE_DIR}"
        fi
        return 1
    fi

    install_renamed_configs

    rm -rf "${previous_dir}"
    return 0
}

current_epoch_seconds() {
    if [[ -n "${EPOCHSECONDS:-}" ]]; then
        printf '%s' "${EPOCHSECONDS}"
        return 0
    fi
    date +%s
}

# The caller takes the cold path because a marker containing only a bare ref
# name fails every field lookup. The previous engine wrote this marker format.
# The cold path unfreezes a consumer exactly once.
read_marker_field() {
    local field_name="$1"
    local line
    if [[ ! -s "${MARKER_PATH}" ]]; then
        return 1
    fi
    while IFS= read -r line; do
        if [[ "${line}" == "${field_name}="* ]]; then
            printf '%s' "${line#"${field_name}="}"
            return 0
        fi
    done < "${MARKER_PATH}"
    return 1
}

write_marker() {
    local etag_value="$1"
    {
        printf 'ref=%s\n' "${SWIFT_MK_API_REF}"
        printf 'etag=%s\n' "${etag_value}"
        printf 'timestamp=%s\n' "$(current_epoch_seconds)"
    } > "${MARKER_PATH}"
}

# A GET probe would double the transfer after an upstream change by downloading
# and discarding the full tarball before the provision fetch.
# A GET probe would make the 3-second validation budget unreliable for larger
# snapshots.
# HEAD responses have no body for HTTP 200 or HTTP 304.
#
# The caller needs curl's stderr and exit status to report repeated validation
# failures when choosing disk reuse or full provisioning.
# curl's exit statuses distinguish timeouts, DNS failures, and refused
# connections.
validate_upstream() {
    local known_etag="$1"
    local log_path="$2"
    local status_code
    local curl_status=0
    local -a header_args=()
    if [[ -n "${known_etag}" ]]; then
        header_args=(-H "If-None-Match: ${known_etag}")
    fi
    # With `set -u`, Bash 3.2 raises "unbound variable" for a direct expansion of
    # a zero-element array.
    # Stock macOS uses Bash 3.2 at /bin/bash.
    # The `+` form expands the array only when it is non-empty.
    status_code=$(curl -sS --head \
        --connect-timeout "${VALIDATION_CONNECT_TIMEOUT}" \
        --max-time "${VALIDATION_MAX_TIME}" \
        "${header_args[@]+"${header_args[@]}"}" \
        -o /dev/null -w '%{http_code}' \
        "${SWIFT_MK_CODELOAD_BASE}/${SWIFT_MK_API_REPO}/tar.gz/${SWIFT_MK_API_REF}" \
        2>"${log_path}") || curl_status=$?
    if [[ ${curl_status} -ne 0 ]]; then
        return "${curl_status}"
    fi
    printf '%s' "${status_code}"
}

# marker_is_recent reports whether the recorded validation is inside the reuse
# window.
# A future timestamp forces a fetch to prevent unbounded disk reuse after a
# backward clock adjustment.
marker_is_recent() {
    local recorded
    local now
    if ! recorded=$(read_marker_field "timestamp"); then
        return 1
    fi
    if [[ ! "${recorded}" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    now=$(current_epoch_seconds)
    if (( recorded > now )); then
        return 1
    fi
    (( now - recorded <= REUSE_WINDOW_SECONDS ))
}

format_age() {
    local seconds="$1"
    if (( seconds < 60 )); then
        printf '%ds' "${seconds}"
        return 0
    fi
    printf '%dm' "$(( seconds / 60 ))"
}

serve_from_disk_with_warning() {
    local validate_status="$1"
    local log_path="$2"
    local recorded
    local etag_value
    local now
    recorded=$(read_marker_field "timestamp")
    etag_value=$(read_marker_field "etag" || printf 'unknown')
    now=$(current_epoch_seconds)
    printf '%s\n' "swift-mk: upstream unreachable; serving the .make snapshot validated $(format_age $(( now - recorded ))) ago (etag ${etag_value}); validation curl exit ${validate_status}: $(stderr_sample "${log_path}"). Check network access to ${SWIFT_MK_CODELOAD_BASE}" >&2
}

# running_in_ci matches the test Build.runsInlineGates already uses.
# GITHUB_ACTIONS alone is not a CI run.
running_in_ci() {
    [[ "${GITHUB_ACTIONS:-}" == "true" && -n "${GITHUB_RUN_ID:-}" ]]
}

# A RETURN trap persists after the function that sets the trap returns.
# The trap would read an out-of-scope stage_root when an enclosing caller returns.
# The staging subshell's EXIT trap removes the temporary directory exactly once
# at subshell exit.
provision() {
    local stage_root
    local stage_dir
    local etag_value
    (
        stage_root=$(mktemp -d "${TMPDIR:-/tmp}/swift-mk-stage.XXXXXXXX") || exit 1
        trap 'rm -rf "${stage_root}"' EXIT

        stage_dir="${stage_root}/tree"
        if ! stage_fetch_and_verify "${stage_root}" "${stage_dir}"; then
            exit 1
        fi

        etag_value=$(awk 'tolower($1) == "etag:" { print $2 }' "${stage_root}/headers" | tr -d '\r' | tail -n 1)

        if ! install_from_stage "${stage_dir}"; then
            exit 1
        fi

        # A missing ETag does not fail the provision: refusing to install a
        # verified, complete tree would be worse than the defect this guards
        # against, since a cold consumer would be left with no engine at all
        # if codeload ever stopped sending ETag on archives. The tree
        # installs regardless; skipping the marker write means every later
        # run has no known etag and downloads unconditionally, the same
        # behavior this script had before conditional validation existed,
        # with a loud warning every time so the degradation stays visible.
        if [[ -z "${etag_value}" ]]; then
            printf 'swift-mk: warning: upstream response for %s carried no ETag header; validation is disabled until it does, downloading unconditionally each run\n' \
                "${SWIFT_MK_API_REF}" >&2
        else
            write_marker "${etag_value}"
        fi
    )
}

main() {
    local known_etag=""
    local status_code=""
    local stored_ref=""
    local validate_status=0
    local validation_log=""

    mkdir -p "${MAKE_DIR}"

    # The lock protects marker reads and writes under .make.
    # Concurrent parses could collide on .make.next and .make.previous.
    # A collision could install a tree assembled from different archives
    # with the marker from the last completed marker write.
    if ! acquire_lock; then
        return 1
    fi
    trap release_lock EXIT

    if [[ -n "${SWIFT_MK_DEV_DIR}" ]]; then
        return 0
    fi

    if [[ "${_SWIFT_MK_PROVISIONED:-}" == "1" ]]; then
        if assets_complete "${MAKE_DIR}"; then
            return 0
        fi
        printf '%s\n' "error: engine snapshot is missing a required asset" >&2
        return 1
    fi

    # CI skips marker reads and conditional requests.
    # A failed fetch never falls back to reusing the snapshot on disk.
    if ! running_in_ci && assets_complete "${MAKE_DIR}"; then
        # The stored ETag applies only to its recorded ref.
        # Validating a different SWIFT_MK_API_REF against that ETag could accept
        # content from the wrong ref.
        # Reusing the stored snapshot when the new ref is unreachable could
        # serve content from the wrong ref.
        stored_ref=$(read_marker_field "ref" || printf '')
        if [[ "${stored_ref}" == "${SWIFT_MK_API_REF}" ]]; then
            known_etag=$(read_marker_field "etag" || printf '')
        fi
    fi

    if [[ -n "${known_etag}" ]]; then
        # A local mktemp failure cannot justify offline reuse because validation
        # has not contacted upstream. A diagnostic must identify the local cause,
        # such as a full or unwritable TMPDIR.
        if ! validation_log=$(mktemp "${TMPDIR:-/tmp}/swift-mk-validate.XXXXXXXX"); then
            printf 'error: could not create a temporary file for validation (mktemp failed); check TMPDIR access\n' >&2
            return 1
        fi
        status_code=$(validate_upstream "${known_etag}" "${validation_log}") || validate_status=$?
        if [[ "${status_code}" == "304" ]]; then
            # The 304 branch does not write under .make, including its marker.
            # The reuse window expires one hour after the last download.
            # Successful validation must not extend the window or change .make
            # contents or mtimes.
            # A validated tree already includes the renamed configs because
            # provisioning recorded its ETag and every provision installs those configs.
            rm -f "${validation_log}"
            return 0
        fi
    fi

    # Offline reuse serves the stored tree with a warning when validation
    # returns no HTTP status and the marker is within the reuse window.
    # Reuse avoids a full fetch on a slow network.
    # Validation failures include timeouts, DNS failures, and refused connections.
    # An expired marker requires a full provision attempt because a failed
    # three-second validation does not establish that the full fetch will fail.
    if ! running_in_ci && [[ -n "${known_etag}" && -z "${status_code}" ]] && marker_is_recent; then
        # Offline reuse does not write under .make because the provision that
        # recorded the ETag already installed the renamed configs.
        serve_from_disk_with_warning "${validate_status}" "${validation_log}"
        rm -f "${validation_log}"
        return 0
    fi

    # Repeated validation failures require a diagnostic when an expired
    # marker prevents offline reuse.
    if [[ -n "${validation_log}" ]]; then
        if [[ -z "${status_code}" ]]; then
            printf 'swift-mk: validation curl exit %d: %s; falling through to a full provision\n' \
                "${validate_status}" "$(stderr_sample "${validation_log}")" >&2
        fi
        rm -f "${validation_log}"
    fi

    # Bash ignores -e in provision and its callees because provision runs
    # as an if condition. An unguarded failing command does not abort the call.
    # provision and install_from_stage check each step's exit status
    # explicitly to detect failures during installation.
    if provision; then
        return 0
    fi

    printf '%s\n' "error: could not provision the swift-makefile engine snapshot. Set SWIFT_MK_DEV_DIR, or check network access to ${SWIFT_MK_CODELOAD_BASE}" >&2
    return 1
}

reexec_from_temp_copy "$@"
main "$@"
