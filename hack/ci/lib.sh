#!/usr/bin/env bash
# shellcheck shell=bash
#
# Helpers shared by the integration, chaos and load stands in hack/.
#
# A stand script sets (or lets the defaults apply):
#   STAND            short stand name, also the artifacts sub-directory;
#   COMPOSE_FILE     compose file that describes the stand;
#   COMPOSE_PROJECT  unique compose project name (parallel runs must not clash);
#   HTTP_PORT        host port of the Traefik web entry point;
#   API_PORT         host port of the Traefik API (middleware status);
#   ARTIFACTS_DIR    where the logs and the summaries of a run are collected.
#
# Only bash, curl and docker are used: the helpers run unchanged on a GitHub
# runner and on a workstation.
#
# The plugin messages are reported in the Traefik log file (interpreter stdout ->
# Traefik logger) with the plugin prefix; a scenario empties that file before the
# requests it asserts on (reset_traefik_log). Traefik appends to the file, so a
# truncation from the host is safe, and it keeps the checks free of any ordering
# assumption about the writes.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-${ROOT_DIR}/artifacts}"

HTTP_PORT="${HTTP_PORT:-18000}"
API_PORT="${API_PORT:-18080}"
TRAEFIK_VERSION="${TRAEFIK_VERSION:-v3.8.0}"
TRAEFIK_LOG_LEVEL="${TRAEFIK_LOG_LEVEL:-DEBUG}"

# Work directory of the stand: the generated configuration, the plugin sources
# and the Traefik log file of the containers all live here.
WORK="${WORK:-${ROOT_DIR}/.stand}"
PLUGIN_DIR="${PLUGIN_DIR:-${WORK}/plugin}"
DYNAMIC_FILE="${DYNAMIC_FILE:-${WORK}/dynamic.yaml}"
LOGS_DIR="${LOGS_DIR:-${WORK}/logs}"
TRACEFILE="${TRACEFILE:-${LOGS_DIR}/traefik.log}"

# The plugin reports its messages with this prefix (see logger.go). PLUGIN_PREFIX
# is an ERE for grep, PLUGIN_PREFIX_LITERAL a plain substring for awk's index()
# (awk would read the backslash of the ERE as an escape).
PLUGIN_PREFIX='\[cookie-extract '
PLUGIN_PREFIX_LITERAL='[cookie-extract '

COOKIE_NAME="${COOKIE_NAME:-access_token}"
COOKIE_VALUE="${COOKIE_VALUE:-secret-token}"

# Exported once: every docker compose call (up, down, restart, logs, exec) reads
# the compose file, and a call without them fails on the required variables -
# which would leave the stand running under the next scenario.
export PLUGIN_DIR DYNAMIC_FILE LOGS_DIR TRACEFILE
export HTTP_PORT API_PORT TRAEFIK_VERSION TRAEFIK_LOG_LEVEL
export COOKIE_NAME COOKIE_VALUE

log() { printf '[%s] %s\n' "$(date -u '+%H:%M:%S')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date -u '+%H:%M:%S')" "$*" >&2; }
die() {
    printf '[%s] ERROR: %s\n' "$(date -u '+%H:%M:%S')" "$*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

stand_dir() { printf '%s/%s' "${ARTIFACTS_DIR}" "${STAND}"; }
tmp_file() { printf '%s/%s' "$(stand_dir)" "$1"; }

compose() { docker compose -p "${COMPOSE_PROJECT}" -f "${COMPOSE_FILE}" "$@"; }

# ---------------------------------------------------------------------------
# Stand lifecycle
# ---------------------------------------------------------------------------

# prepare_plugin copies the runtime sources of the plugin: the mount stays small
# and the stand proves that nothing but the Go standard library is needed.
prepare_plugin() {
    rm -rf "${PLUGIN_DIR}"
    mkdir -p "${PLUGIN_DIR}"
    cp "${ROOT_DIR}/.traefik.yml" "${ROOT_DIR}/go.mod" "${ROOT_DIR}"/cookieextract.go "${ROOT_DIR}"/logger.go "${PLUGIN_DIR}/"
}

stand_up() {
    require_cmd docker
    require_cmd curl

    mkdir -p "$(stand_dir)" "${LOGS_DIR}"

    log "stand ${STAND}: docker compose up (project ${COMPOSE_PROJECT}, ${COMPOSE_FILE})"
    compose up -d --quiet-pull
}

stand_down() {
    # A running Traefik keeps writing to the inode of a log file removed
    # underneath it: the stand is always brought down before the files are reset,
    # and the removal is checked: a compose error swallowed here would leave the
    # containers running under the next scenario.
    log "stand ${STAND}: docker compose down"
    compose down -v --remove-orphans >/dev/null 2>&1 || true

    local left
    left="$(compose ps -q 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "${left}" != "0" ]]; then
        warn "stand ${STAND}: ${left} container(s) of project ${COMPOSE_PROJECT} are still running"
        compose down -v --remove-orphans >&2 || true
    fi
}

stand_restart() { # [SERVICE]
    log "stand ${STAND}: restarting ${1:-traefik}"
    compose restart "${1:-traefik}" >/dev/null
}

# reset_logs brings the stand down and drops the previous log file and dynamic
# configuration, so that a run starts from a clean slate.
reset_logs() {
    stand_down
    rm -f "${TRACEFILE}" "$(stand_dir)/summary.txt"
    mkdir -p "${LOGS_DIR}"
}

# reset_traefik_log empties the Traefik log file: a scenario then asserts on the
# lines produced by its own requests only. Traefik appends to the file, so the
# truncation from the host is safe (checked by the callers: the file grows again).
reset_traefik_log() { # [DESCRIPTION]
    # The previous content is archived first: the assertions of a scenario only
    # look at its own lines, but the artifacts keep the whole run.
    if [[ -s "${TRACEFILE}" ]]; then
        cat "${TRACEFILE}" >>"$(tmp_file traefik-full.log)" 2>/dev/null || true
    fi
    : >"${TRACEFILE}" || die "stand ${STAND}: could not truncate ${TRACEFILE}"
    log "stand ${STAND}: Traefik log reset${1:+ (${1})}"
}

# dump_stand_state collects everything needed to understand a failure: container
# states, full logs, the Traefik log file and the summaries; a tail is printed so
# that the CI job log is useful without downloading the artifacts.
dump_stand_state() {
    local dir
    dir="$(stand_dir)"
    mkdir -p "${dir}"
    compose ps >"${dir}/compose-ps.txt" 2>&1 || true
    compose logs --no-color --timestamps >"${dir}/compose-logs.txt" 2>&1 || true
    cp "${TRACEFILE}" "${dir}/traefik.log" 2>/dev/null || true
    log "stand ${STAND}: state collected in ${dir} (compose-ps.txt, compose-logs.txt, traefik.log)"
    warn "--- tail of the Traefik log ---"
    tail -n 30 "${TRACEFILE}" >&2 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Summaries and artifacts
# ---------------------------------------------------------------------------

init_summary() {
    mkdir -p "$(stand_dir)"
    : >"$(stand_dir)/summary.txt"
}

summary() {
    mkdir -p "$(stand_dir)"
    printf '%s\n' "$*" | tee -a "$(stand_dir)/summary.txt"
}

# ---------------------------------------------------------------------------
# HTTP helpers: the backend (traefik/whoami) echoes the request headers in its
# body, which is the observation channel of the assertions on the translation.
# ---------------------------------------------------------------------------

http_code() { # URL [curl args...]
    local url="$1"
    shift
    curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@" "${url}" 2>/dev/null || printf '000'
}

http_body() { # URL [curl args...]
    local url="$1"
    shift
    curl -s --max-time 10 "$@" "${url}" 2>/dev/null || true
}

http_headers() { # URL [curl args...]
    local url="$1"
    shift
    curl -s -D - -o /dev/null --max-time 10 "$@" "${url}" 2>/dev/null || true
}

backend_url() { printf 'http://127.0.0.1:%s/' "${HTTP_PORT}"; }
api_url() { printf 'http://127.0.0.1:%s' "${API_PORT}"; }

# cookie_arg builds a Cookie header argument: cookie_arg [name] [value].
cookie_arg() {
    printf 'Cookie: %s=%s' "${1:-${COOKIE_NAME}}" "${2:-${COOKIE_VALUE}}"
}

# wait_ready waits until a router answers through Traefik.
wait_ready() { # URL TIMEOUT_S [curl args...]
    local url="$1" timeout="$2"
    shift 2
    local start="${SECONDS}" code="000"
    while :; do
        code="$(http_code "${url}" "$@")"
        [[ "${code}" == "200" ]] && {
            log "stand ${STAND}: ready after $((SECONDS - start))s"
            return 0
        }
        ((SECONDS - start >= timeout)) && die "stand ${STAND}: not ready after ${timeout}s (last HTTP ${code})"
        sleep 0.5
    done
}

# wait_log_pattern PATTERN MIN_COUNT TIMEOUT_S DESCRIPTION waits until the
# Traefik log contains at least MIN_COUNT lines matching PATTERN (e.g. the
# "Plugins loaded" marker of a restart).
wait_log_pattern() {
    local pattern="$1" min="$2" timeout="$3" what="$4" start="${SECONDS}" n
    while :; do
        n="$(grep -cE -- "${pattern}" "${TRACEFILE}" 2>/dev/null || true)"
        n="${n:-0}"
        if ((n >= min)); then
            log "stand ${STAND}: ${what}: ${n} line(s) matching /${pattern}/ after $((SECONDS - start))s"
            return 0
        fi
        ((SECONDS - start >= timeout)) && die "stand ${STAND}: ${what}: no line matching /${pattern}/ after ${timeout}s"
        sleep 0.5
    done
}

# wait_middleware_rebuilt NAME TIMEOUT_S waits until Traefik has built a new
# instance of a middleware: a 200 answer on an untouched router would not prove
# that a configuration reload was applied.
wait_middleware_rebuilt() { # NAME TIMEOUT_S
    local name="$1" timeout="$2" before after start="${SECONDS}"
    before="$(grep -cE "middlewareName=${name}" "${TRACEFILE}" 2>/dev/null || true)"
    before="${before:-0}"
    while :; do
        after="$(grep -cE "middlewareName=${name}" "${TRACEFILE}" 2>/dev/null || true)"
        after="${after:-0}"
        if ((after > before)); then
            log "stand ${STAND}: ${name} rebuilt (${before} -> ${after}) after $((SECONDS - start))s"
            return 0
        fi
        ((SECONDS - start >= timeout)) && die "stand ${STAND}: ${name} was not rebuilt after ${timeout}s"
        sleep 0.5
    done
}

# ---------------------------------------------------------------------------
# Plugin log assertions (whole log: the caller resets it first)
# ---------------------------------------------------------------------------

plugin_lines() { # [LOG_FILE]
    # -a: a NUL byte (a log file truncated under a running container) must not
    # turn the whole file into "binary file matches".
    grep -aE "${PLUGIN_PREFIX}" "${1:-${TRACEFILE}}" 2>/dev/null || true
}

count_plugin_lines() { # [LOG_FILE]
    local n
    n="$(grep -acE "${PLUGIN_PREFIX}" "${1:-${TRACEFILE}}" 2>/dev/null || true)"
    printf '%s' "${n:-0}"
}

plugin_lines_matching() { # PATTERN
    plugin_lines | grep -aE -- "$1" || true
}

count_plugin_lines_matching() { # PATTERN
    local n
    n="$(plugin_lines_matching "$1" | grep -c . || true)"
    printf '%s' "${n:-0}"
}

# plugin_evidence prints the plugin messages, without the Traefik fields, for the
# failure messages and the summary.
plugin_evidence() {
    plugin_lines | sed -E 's/^.*(\[cookie-extract[^]]*\].*?)( module=.*)?$/\1/' | tr '\n' '|'
}

# wait_plugin_lines MIN_COUNT PATTERN TIMEOUT_S DESCRIPTION waits until at least
# MIN_COUNT plugin lines match PATTERN. The plugin writes through the interpreter
# channel Traefik redirects into its logger, and a line can land slightly after
# the response: the assertions wait for their condition instead of racing it.
wait_plugin_lines() {
    local min="$1" pattern="$2" timeout="$3" what="$4" start="${SECONDS}" n
    while :; do
        n="$(count_plugin_lines_matching "${pattern}")"
        if ((n >= min)); then
            log "stand ${STAND}: ${what}: ${n} plugin line(s) matching /${pattern}/ after $((SECONDS - start))s"
            summary "  ${what}: ${n} plugin line(s) /${pattern}/"
            return 0
        fi
        ((SECONDS - start >= timeout)) && die "stand ${STAND}: ${what}: only ${n} plugin line(s) matching /${pattern}/ after ${timeout}s (expected at least ${min}); got: $(plugin_evidence)"
        sleep 0.2
    done
}

# drain_plugin_log gives the pending messages the time to land, before an
# assertion on their absence (or on an exact count).
drain_plugin_log() {
    sleep "${1:-1}"
}

assert_plugin_lines() { # MIN_COUNT PATTERN DESCRIPTION
    local min="$1" pattern="$2" what="$3" n
    n="$(count_plugin_lines_matching "${pattern}")"
    ((n >= min)) || die "stand ${STAND}: ${what}: ${n} plugin lines matching /${pattern}/, expected at least ${min}; got: $(plugin_evidence)"
    log "stand ${STAND}: ${what}: ${n} plugin line(s) matching /${pattern}/ (>= ${min})"
    summary "  ${what}: ${n} plugin line(s) /${pattern}/"
}

assert_plugin_lines_exactly() { # COUNT PATTERN DESCRIPTION
    local want="$1" pattern="$2" what="$3" n
    n="$(count_plugin_lines_matching "${pattern}")"
    ((n == want)) || die "stand ${STAND}: ${what}: ${n} plugin lines matching /${pattern}/, expected ${want}; got: $(plugin_evidence)"
    log "stand ${STAND}: ${what}: exactly ${n} plugin line(s) matching /${pattern}/"
    summary "  ${what}: exactly ${n} plugin line(s) /${pattern}/"
}

assert_plugin_lines_at_most() { # MAX_COUNT PATTERN DESCRIPTION
    local max="$1" pattern="$2" what="$3" n
    n="$(count_plugin_lines_matching "${pattern}")"
    ((n <= max)) || die "stand ${STAND}: ${what}: ${n} plugin lines matching /${pattern}/, expected at most ${max}; got: $(plugin_evidence)"
    log "stand ${STAND}: ${what}: ${n} plugin line(s) matching /${pattern}/ (<= ${max})"
    summary "  ${what}: ${n} plugin line(s) /${pattern}/ (<= ${max})"
}

assert_no_plugin_lines_matching() { # PATTERN DESCRIPTION
    local pattern="$1" what="$2" n
    n="$(count_plugin_lines_matching "${pattern}")"
    ((n == 0)) || die "stand ${STAND}: ${what}: ${n} plugin lines matching /${pattern}/, expected none; got: $(plugin_evidence)"
    log "stand ${STAND}: ${what}: 0 plugin line(s) matching /${pattern}/"
    summary "  ${what}: 0 plugin line(s) /${pattern}/"
}

# assert_no_process_output checks that the plugin messages never reach the
# process output (journald, /var/log/messages on systemd hosts).
assert_no_process_output() { # DESCRIPTION
    local what="$1" logs
    logs="$(compose logs --no-color traefik 2>/dev/null || true)"
    printf '%s\n' "${logs}" >"$(tmp_file "process-output.txt")"
    if grep -qE "${PLUGIN_PREFIX}" <<<"${logs}"; then
        die "stand ${STAND}: ${what}: the plugin wrote to the process output (see $(stand_dir)/process-output.txt)"
    fi
    log "stand ${STAND}: ${what}: the plugin output stays in the Traefik log file"
    summary "  ${what}: no plugin line on the process output"
}

# assert_no_panic greps the Traefik log for a panic of the interpreted plugin.
assert_no_panic() { # DESCRIPTION
    local what="$1"
    if grep -qE 'panic: |goroutine [0-9]+ \[running\]' "${TRACEFILE}" 2>/dev/null; then
        die "stand ${STAND}: ${what}: a panic was reported in the Traefik log (see $(stand_dir))"
    fi
    log "stand ${STAND}: ${what}: no panic in the Traefik log"
}

# assert_no_value_leak checks that a cookie value never shows up in the log.
assert_no_value_leak() { # VALUE DESCRIPTION
    local value="$1" what="$2"
    if grep -qF -- "${value}" "${TRACEFILE}" 2>/dev/null; then
        die "stand ${STAND}: ${what}: the value is present in the Traefik log (see $(stand_dir))"
    fi
    log "stand ${STAND}: ${what}: the value is not in the Traefik log"
    summary "  ${what}: cookie value not logged"
}

# ---------------------------------------------------------------------------
# Backend assertions (traefik/whoami echoes the request headers)
# ---------------------------------------------------------------------------

assert_backend_header() { # BODY NAME VALUE_REGEX DESCRIPTION
    local body="$1" name="$2" expect="$3" what="$4"
    # The echoed body carries CRLF line endings: drop the CR before matching, so
    # that an anchored expectation works.
    body="$(tr -d '\r' <<<"${body}")"
    grep -qiE "^${name}: ${expect}" <<<"${body}" ||
        die "stand ${STAND}: ${what}: header ${name} matching /${expect}/ not echoed by the backend (got: $(grep -i "^${name}:" <<<"${body}" | sed -n '1p' || printf '<absent>'))"
    log "stand ${STAND}: ${what}: backend saw $(grep -i "^${name}:" <<<"${body}" | sed -n '1p')"
    summary "  ${what}: $(grep -i "^${name}:" <<<"${body}" | sed -n '1p')"
}

assert_backend_header_absent() { # BODY NAME DESCRIPTION
    local body="$1" name="$2" what="$3"
    body="$(tr -d '\r' <<<"${body}")"
    if grep -qiE "^${name}:" <<<"${body}"; then
        die "stand ${STAND}: ${what}: the backend received a ${name} header ($(grep -i "^${name}:" <<<"${body}" | sed -n '1p'))"
    fi
    log "stand ${STAND}: ${what}: the backend received no ${name} header"
    summary "  ${what}: no ${name} header at the backend"
}

# ---------------------------------------------------------------------------
# Request batches
# ---------------------------------------------------------------------------

run_requests() { # OUT_FILE COUNT URL [curl args...]
    local out="$1" count="$2" url="$3"
    shift 3
    : >"${out}"
    local i
    for ((i = 1; i <= count; i++)); do
        printf '%s\n' "$(http_code "${url}" "$@")" >>"${out}"
    done
}

# background_load keeps hammering URL until STOP_FILE appears: the chaos stand
# uses it so that the traffic really spans the injected fault.
background_load() { # OUT_FILE STOP_FILE URL [curl args...]
    local out="$1" stop="$2" url="$3"
    shift 3
    : >"${out}"
    local workers="${LOAD_WORKERS:-6}"
    while [[ ! -f "${stop}" ]]; do
        seq 1 "${workers}" | xargs -P "${workers}" -I{} \
            curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 "$@" "${url}" >>"${out}" 2>/dev/null || true
    done
}

show_histogram() { # FILE DESCRIPTION
    local file="$1" what="$2"
    log "stand ${STAND}: ${what}: $(grep -c . "${file}" 2>/dev/null || printf 0) requests"
    sort "${file}" | uniq -c | sed 's/^/    /' | tee -a "$(stand_dir)/summary.txt" >&2
}

count_codes() { # FILE CODE
    local n
    n="$(grep -c -x "$2" "$1" 2>/dev/null || true)"
    printf '%s' "${n:-0}"
}

assert_no_5xx() { # FILE DESCRIPTION
    local file="$1" what="$2" n
    n="$(awk '/^5[0-9][0-9]$/ { c++ } END { print c+0 }' "${file}")"
    ((n == 0)) || die "stand ${STAND}: ${what}: ${n} x 5xx - see $(stand_dir)"
    log "stand ${STAND}: ${what}: 0 x 5xx over $(grep -c . "${file}" || printf 0) requests"
}

assert_no_transport_errors() { # FILE DESCRIPTION
    local file="$1" what="$2" n
    n="$(count_codes "${file}" 000)"
    ((n == 0)) || die "stand ${STAND}: ${what}: ${n} requests did not reach Traefik (curl 000)"
}

assert_all_codes() { # FILE CODE DESCRIPTION
    local file="$1" code="$2" what="$3" total other
    total="$(grep -c . "${file}" || printf 0)"
    other="$((total - $(count_codes "${file}" "${code}")))"
    ((other == 0)) ||
        die "stand ${STAND}: ${what}: ${other} of ${total} responses are not ${code} ($(sort "${file}" | uniq -c | awk '{ printf "%s x %s ", $1, $2 }'))"
    log "stand ${STAND}: ${what}: all ${total} responses are ${code}"
    summary "  ${what}: ${total} x ${code}"
}

# assert_middleware_disabled checks that Traefik refused to create a middleware
# and reported why: the behaviour every invalid configuration must have.
assert_middleware_disabled() { # NAME ERROR_REGEX DESCRIPTION
    local name="$1" expect="$2" what="$3" json
    json="$(curl -s --max-time 10 "$(api_url)/api/http/middlewares/${name}" || true)"
    [[ -n "${json}" ]] || die "stand ${STAND}: ${what}: the API returned nothing for ${name}"
    printf '%s\n' "${json}" >"$(tmp_file "middleware-${name//[@:\/]/_}.json")"
    grep -qE '"status":[[:space:]]*"disabled"' <<<"${json}" ||
        die "stand ${STAND}: ${what}: ${name} is not disabled: ${json}"
    grep -qE "${expect}" <<<"${json}" ||
        die "stand ${STAND}: ${what}: ${name} carries no error matching /${expect}/: ${json}"
    log "stand ${STAND}: ${what}: ${name} is disabled with the expected error"
    summary "  ${what}: ${name} disabled"
}
