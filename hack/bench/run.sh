#!/usr/bin/env bash
#
# End-to-end LOAD/benchmark of the cookieExtract plugin behind Traefik.
#
# The stand (docker-compose.bench.yaml) is one Traefik in front of
# traefik/whoami, with the plugin mounted as a local plugin. The load is
# generated from the host by hack/bench/loadgen (stdlib only), through the
# published port, exactly as an external client would drive it.
#
# Four cases, all against a router whose middleware carries the log level noted
# below, all with the same cookie (sent as a plain `Cookie:` request header):
#
#   a. logLevel off,   WITH the cookie     - control: the plugin with logging off;
#   b. logLevel info,  WITH the cookie     - the cheap log path (one template);
#   c. logLevel debug, WITHOUT the cookie  - the anti-spam case: thousands of
#                                            requests must produce a handful of
#                                            lines (per-template 5 s throttling
#                                            plus one warning per instance);
#   d. logLevel debug, WITH the cookie     - the throttled detail path.
#
# Each case measures the client side (rps, percentiles) and counts the plugin
# lines in the Traefik log file, i.e. the lines carrying the `[cookie-extract `
# prefix. Cases a, b and c count the whole case (warmup included); case d counts
# only the measured window, because its bound (3 + (duration + warmup)/5)
# describes the throttled detail path alone. Every case asserts:
#
#   * requests >= 1000, 0 transport errors (curl 000), all responses 200;
#   * a: exactly 0 plugin lines;
#   * b: 1 .. 3 + (duration + warmup)/5 plugin lines;
#   * c: 1 .. 10 plugin lines;
#   * d: 1 .. 3 + (duration + warmup)/5 plugin lines.
#
# The summary table lands in artifacts/bench/summary.txt; the Traefik logs are
# archived in artifacts/bench/ before the stand is brought down (compressed:
# Traefik at DEBUG also writes a line of its own per request), next to
# plugin-lines.txt, the plugin lines of the whole run. The raw per-case loadgen
# output stays in the scratch dir (.bench/) when BENCH_KEEP=1.
#
# Requirements: docker (compose), go, curl.
#
#   ./hack/bench/run.sh
#   BENCH_WORKERS=64 BENCH_DURATION=10s BENCH_KEEP=1 ./hack/bench/run.sh
#
# Knobs (defaults): BENCH_WORKERS=32, BENCH_DURATION=10s, BENCH_WARMUP=2s,
# BENCH_TIMEOUT=5s, BENCH_KEEP=0, BENCH_HTTP_PORT=18500, BENCH_API_PORT=18580,
# TRAEFIK_VERSION=v3.8.0.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"

COMPOSE_FILE="${HERE}/docker-compose.bench.yaml"
COMPOSE_PROJECT="${BENCH_PROJECT:-cookie-extract-bench}"

WORKERS="${BENCH_WORKERS:-32}"
DURATION="${BENCH_DURATION:-10s}"
WARMUP="${BENCH_WARMUP:-2s}"
TIMEOUT="${BENCH_TIMEOUT:-5s}"
KEEP="${BENCH_KEEP:-0}"

HTTP_PORT="${BENCH_HTTP_PORT:-18500}"
API_PORT="${BENCH_API_PORT:-18580}"
TRAEFIK_VERSION="${TRAEFIK_VERSION:-v3.8.0}"

# Scratch dir inside the repository: the generated configuration, the copied
# plugin sources and the container log live here.
WORK="${BENCH_WORK:-${ROOT}/.bench}"
CONF_DIR="${WORK}/conf"
PLUGIN_DIR="${WORK}/plugin"
LOGS_DIR="${WORK}/logs"
TRACEFILE="${LOGS_DIR}/traefik.log"
LOADGEN="${WORK}/loadgen"
ARTIFACTS_DIR="${ROOT}/artifacts/bench"

export BENCH_CONF_DIR="${CONF_DIR}"
export BENCH_PLUGIN_DIR="${PLUGIN_DIR}"
export BENCH_LOGS_DIR="${LOGS_DIR}"
export BENCH_HTTP_PORT="${HTTP_PORT}"
export BENCH_API_PORT="${API_PORT}"
export TRAEFIK_VERSION

# The Go caches are kept inside the scratch dir: the bench then also runs in a
# restricted environment (see run-tests.sh), and the build is stdlib only.
export GOCACHE="${WORK}/go/cache"
export GOTMPDIR="${WORK}/go/tmp"
export GOMODCACHE="${WORK}/go/mod"
export GOPATH="${WORK}/go/path"

URL="http://127.0.0.1:${HTTP_PORT}"
API="http://127.0.0.1:${API_PORT}"
COOKIE_HEADER="Cookie: access_token=secret-token"

# Every plugin message carries this prefix (see logger.go); an ERE for grep.
PLUGIN_PREFIX='\[cookie-extract '

MIN_REQUESTS=1000
MAX_LINES_CASE_C=10

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() { printf '[%s] %s\n' "$(date -u '+%H:%M:%S')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date -u '+%H:%M:%S')" "$*" >&2; }
die() {
    printf '[%s] ERROR: %s\n' "$(date -u '+%H:%M:%S')" "$*" >&2
    exit 1
}
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
compose() { docker compose -p "${COMPOSE_PROJECT}" -f "${COMPOSE_FILE}" "$@"; }

# The plugin line bound of the throttled detail path: the first occurrence of
# each of the two templates (the debug "serving" line and the info extraction)
# plus one extra occurrence per 5 s of the window the case really spans (warmup
# included), with one line of margin so that a slower runner does not fail the
# bound by timer drift.
DURATION_SECS="${DURATION%s}"
WARMUP_SECS="${WARMUP%s}"
[[ "${DURATION_SECS}" =~ ^[0-9]+$ ]] || die "BENCH_DURATION must be a whole number of seconds, got '${DURATION}'"
[[ "${WARMUP_SECS}" =~ ^[0-9]+$ ]] || die "BENCH_WARMUP must be a whole number of seconds, got '${WARMUP}'"
LINE_BOUND=$((3 + (DURATION_SECS + WARMUP_SECS) / 5))

ROWS=()
FAILURES=0
SUMMARY_WRITTEN=0

fail() {
    warn "ASSERTION FAILED: $*"
    FAILURES=$((FAILURES + 1))
}

# ---------------------------------------------------------------------------
# Stand lifecycle
# ---------------------------------------------------------------------------

prepare_scratch() {
    rm -rf "${WORK}"
    mkdir -p "${CONF_DIR}" "${PLUGIN_DIR}" "${LOGS_DIR}" "${ARTIFACTS_DIR}"
    mkdir -p "${WORK}/go/cache" "${WORK}/go/tmp" "${WORK}/go/mod" "${WORK}/go/path"

    # Drop the artifacts of a previous run so that a stale log is never mistaken
    # for the current one (the log of a load run is compressed, see archive_stand).
    rm -f "${ARTIFACTS_DIR}/traefik.log" "${ARTIFACTS_DIR}/traefik.log.gz" \
        "${ARTIFACTS_DIR}/traefik-full.log" "${ARTIFACTS_DIR}/traefik-full.log.gz" \
        "${ARTIFACTS_DIR}/plugin-lines.txt"

    # Only the runtime sources are copied: the mount stays small and the stand
    # then also proves that the plugin needs nothing but the Go standard library.
    cp "${ROOT}/.traefik.yml" "${ROOT}/go.mod" "${PLUGIN_DIR}/"

    # Every runtime source (the test files are not part of the plugin package).
    local f
    for f in "${ROOT}"/*.go; do
        case "${f}" in
        *_test.go) continue ;;
        esac
        cp "${f}" "${PLUGIN_DIR}/"
    done

    : >"${TRACEFILE}"
    log "bench: plugin runtime sources copied to ${PLUGIN_DIR}"
}

build_loadgen() {
    log "bench: building the load generator (stdlib only)"
    (cd "${ROOT}" && go build -o "${LOADGEN}" ./hack/bench/loadgen) ||
        die "cannot build ./hack/bench/loadgen"
}

write_static_conf() {
    # The static configuration is complete on purpose. When Traefik finds a
    # static configuration file it uses it as-is (the command line flags of the
    # stand are then ignored), so everything the stand needs has to be here: the
    # entry point, the API, the log level and file, the file provider and the
    # local plugin. The plugin messages are reported through the logger Traefik
    # redirects into its log file, hence the DEBUG level.
    cat >"${CONF_DIR}/traefik.yaml" <<'YAML'
entryPoints:
  web:
    address: ":8000"

api:
  insecure: true

log:
  level: DEBUG
  filePath: /var/log/traefik/traefik.log

providers:
  file:
    filename: /etc/traefik/dynamic.yaml

experimental:
  localPlugins:
    cookieExtract:
      moduleName: github.com/MichNG/traefik-cookie-extract
YAML
}

# One router and one middleware instance per case, so that an assertion on the
# plugin lines of a case is never polluted by another case and each middleware
# has its own throttling state. The two debug middlewares are separate instances
# (ce-debug-missing / ce-debug).
write_dynamic_conf() {
    cat >"${CONF_DIR}/dynamic.yaml" <<'YAML'
http:
  routers:
    case-a:
      rule: "PathPrefix(`/a`)"
      entryPoints: [web]
      middlewares: [ce-off]
      service: target
    case-b:
      rule: "PathPrefix(`/b`)"
      entryPoints: [web]
      middlewares: [ce-info]
      service: target
    case-c:
      rule: "PathPrefix(`/c`)"
      entryPoints: [web]
      middlewares: [ce-debug-missing]
      service: target
    case-d:
      rule: "PathPrefix(`/d`)"
      entryPoints: [web]
      middlewares: [ce-debug]
      service: target

  middlewares:
    ce-off:
      plugin:
        cookieExtract:
          cookieName: access_token
          logLevel: off
    ce-info:
      plugin:
        cookieExtract:
          cookieName: access_token
          logLevel: info
    ce-debug-missing:
      plugin:
        cookieExtract:
          cookieName: access_token
          logLevel: debug
    ce-debug:
      plugin:
        cookieExtract:
          cookieName: access_token
          logLevel: debug

  services:
    target:
      loadBalancer:
        servers:
          - url: http://target
YAML
}

stand_up() {
    log "bench: starting the stand (traefik ${TRAEFIK_VERSION}, http :${HTTP_PORT}, api :${API_PORT})"
    compose up -d --quiet-pull
}

dump_diagnostics() {
    warn "--- docker compose ps ---"
    compose ps >&2 2>&1 || true
    warn "--- docker compose logs (tail) ---"
    compose logs --no-color --tail 80 >&2 2>&1 || true
    warn "--- Traefik log (tail) ---"
    tail -n 40 "${TRACEFILE}" >&2 2>/dev/null || true
}

wait_ready() {
    local start="${SECONDS}" code
    log "bench: waiting for Traefik to answer through the plugin"
    while :; do
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${URL}/a" 2>/dev/null || printf '000')"
        [[ "${code}" == "200" ]] && {
            log "bench: ready after $((SECONDS - start))s"
            return 0
        }
        if ((SECONDS - start >= 90)); then
            dump_diagnostics
            die "the stand is not ready after 90s (last HTTP ${code})"
        fi
        sleep 0.5
    done
}

# check_plugin_instances makes sure all four middlewares were loaded by the
# plugin and are not disabled by the configuration validation.
check_plugin_instances() {
    local mw json
    for mw in ce-off ce-info ce-debug-missing ce-debug; do
        json="$(curl -s --max-time 5 "${API}/api/http/middlewares/${mw}@file" 2>/dev/null || true)"
        [[ -n "${json}" ]] || {
            dump_diagnostics
            die "middleware ${mw} is missing from the API (did the plugin load?)"
        }
        if grep -qE '"status":[[:space:]]*"disabled"' <<<"${json}"; then
            printf '%s\n' "${json}" >"${WORK}/${mw}.json"
            dump_diagnostics
            die "middleware ${mw} is disabled: ${json}"
        fi
    done
    log "bench: the four plugin instances are loaded"
}

# ---------------------------------------------------------------------------
# Artifacts and cleanup
# ---------------------------------------------------------------------------

write_summary() {
    [[ "${SUMMARY_WRITTEN}" == "1" ]] && return 0
    SUMMARY_WRITTEN=1

    local out="${ARTIFACTS_DIR}/summary.txt"
    mkdir -p "${ARTIFACTS_DIR}"
    {
        printf 'cookieExtract e2e load bench\n'
        printf 'workers=%s duration=%s warmup=%s timeout=%s traefik=%s\n' \
            "${WORKERS}" "${DURATION}" "${WARMUP}" "${TIMEOUT}" "${TRAEFIK_VERSION}"
        printf 'plugin-line bounds: a == 0; c <= %s; b/d <= 3 + (duration + warmup)/5 = %s\n' \
            "${MAX_LINES_CASE_C}" "${LINE_BOUND}"
        printf '\n'
        printf '%-26s %9s %7s %7s %7s %9s %12s %10s\n' \
            "case" "rps" "p50 ms" "p95 ms" "p99 ms" "200" "plugin lines" "requests"

        local row label rps p50 p95 p99 s200 lines requests errors
        # Guarded: bash 3.2 (macOS) treats "${ROWS[@]}" on an empty array as an
        # unbound variable under `set -u`.
        if ((${#ROWS[@]} > 0)); then
            for row in "${ROWS[@]}"; do
                IFS='|' read -r label rps p50 p95 p99 s200 lines requests errors <<<"${row}"
                printf '%-26s %9s %7s %7s %7s %9s %12s %10s\n' \
                    "${label}" "${rps}" "${p50}" "${p95}" "${p99}" "${s200}" "${lines}" "${requests}"
            done
        fi

        printf '\nassertions failed: %s\n' "${FAILURES}"
    } >"${out}"

    log "bench: summary written to ${out}"
    cat "${out}"
}

archive_stand() {
    mkdir -p "${ARTIFACTS_DIR}"

    # Traefik at DEBUG also emits a line of its own per request (the WRR
    # selection), so a load run fills the log file fast. The whole log is stored
    # compressed (a few hundred KiB); the plugin lines alone - the headline
    # evidence - are also kept uncompressed. `tr -d '\000'` is defensive: a NUL
    # can only appear if the file was ever truncated while Traefik wrote to it,
    # which this script does not do (cases count from a byte offset instead).
    if command -v gzip >/dev/null 2>&1; then
        gzip -c "${TRACEFILE}" >"${ARTIFACTS_DIR}/traefik.log.gz" 2>/dev/null ||
            cp -f "${TRACEFILE}" "${ARTIFACTS_DIR}/traefik.log" 2>/dev/null || true
    else
        cp -f "${TRACEFILE}" "${ARTIFACTS_DIR}/traefik.log" 2>/dev/null || true
    fi

    grep -aE "${PLUGIN_PREFIX}" "${TRACEFILE}" 2>/dev/null | tr -d '\000' >"${ARTIFACTS_DIR}/plugin-lines.txt" || true

    compose ps >"${ARTIFACTS_DIR}/compose-ps.txt" 2>&1 || true
    compose logs --no-color >"${ARTIFACTS_DIR}/compose-logs.txt" 2>&1 || true

    log "bench: Traefik log and plugin lines archived in ${ARTIFACTS_DIR}"
}

cleanup() {
    local status=$?
    local left

    # Archive before the stand goes down: the log file is on a bind mount of the
    # scratch dir.
    archive_stand

    log "bench: docker compose down (project ${COMPOSE_PROJECT})"
    compose down -v --remove-orphans >/dev/null 2>&1 || true

    left="$(compose ps -q 2>/dev/null | wc -l | tr -d ' ')"
    [[ "${left}" == "0" ]] || warn "bench: ${left} container(s) of ${COMPOSE_PROJECT} are still running"

    write_summary || true

    if [[ "${KEEP}" == "1" ]]; then
        log "bench: raw output kept in ${WORK} (BENCH_KEEP=1)"
    else
        rm -rf "${WORK}"
    fi

    if ((FAILURES > 0)); then
        exit 1
    fi
    exit "${status}"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Log helpers
# ---------------------------------------------------------------------------

# A case counts the plugin lines written after it started, from the byte offset
# of the Traefik log file at that moment. The file is never truncated: truncating
# a file Traefik still holds open leaves NUL holes (the writer keeps its offset),
# and the holes then show up in every later read.
log_offset() {
    wc -c <"${TRACEFILE}" 2>/dev/null | tr -d ' '
}

count_plugin_lines_since() { # OFFSET
    local off="$1" n
    n="$(tail -c "+$((off + 1))" "${TRACEFILE}" 2>/dev/null | grep -acE "${PLUGIN_PREFIX}" || true)"
    printf '%s' "${n:-0}"
}

plugin_evidence_since() { # OFFSET
    local off="$1"
    tail -c "+$((off + 1))" "${TRACEFILE}" 2>/dev/null |
        grep -aE "${PLUGIN_PREFIX}" | sed -E 's/ module=.*$//' | tail -n 12 || true
}

# ---------------------------------------------------------------------------
# Load and assertions
# ---------------------------------------------------------------------------

run_loadgen() { # OUT COOKIE(0|1) DURATION WARMUP URL
    local out="$1" cookie="$2" dur="$3" warm="$4" url="$5"
    local args=(-url "${url}" -workers "${WORKERS}" -duration "${dur}" -warmup "${warm}" -timeout "${TIMEOUT}")
    if [[ "${cookie}" == "1" ]]; then
        args+=(-header "${COOKIE_HEADER}")
    fi
    "${LOADGEN}" "${args[@]}" >"${out}"
}

parse_out() { # OUT
    P_REQUESTS="$(sed -n 's/^requests=\([0-9]*\) .*/\1/p' "$1")"
    P_200="$(sed -n 's/^requests=[0-9]* status_200=\([0-9]*\) .*/\1/p' "$1")"
    P_ERRORS="$(sed -n 's/^requests=.* errors=\([0-9]*\)$/\1/p' "$1")"
    P_RPS="$(sed -n 's/^rps=//p' "$1")"
    P_P50="$(sed -n 's/^lat_ms_min=[0-9.]* p50=\([0-9.]*\).*/\1/p' "$1")"
    P_P95="$(sed -n 's/.* p95=\([0-9.]*\).*/\1/p' "$1")"
    P_P99="$(sed -n 's/.* p99=\([0-9.]*\).*/\1/p' "$1")"
}

assert_common() { # LABEL OUT
    local label="$1" out="$2"
    parse_out "${out}"

    ((P_REQUESTS >= MIN_REQUESTS)) ||
        fail "${label}: only ${P_REQUESTS} requests (>= ${MIN_REQUESTS} expected); loadgen: $(tr '\n' ' ' <"${out}")"
    ((P_ERRORS == 0)) ||
        fail "${label}: ${P_ERRORS} transport error(s) (curl 000); loadgen: $(tr '\n' ' ' <"${out}")"
    ((P_200 == P_REQUESTS)) ||
        fail "${label}: only ${P_200}/${P_REQUESTS} responses are HTTP 200; loadgen: $(sed -n '1p' "${out}")"
}

record() { # LABEL OUT LINES
    local label="$1" out="$2" lines="$3"
    ROWS+=("${label}|${P_RPS}|${P_P50}|${P_P95}|${P_P99}|${P_200}|${lines}|${P_REQUESTS}|${P_ERRORS}")
    printf '   %s: %s\n' "${label}" "$(tr '\n' ' ' <"${out}")"
}

# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------

case_a() {
    log "bench: case a - logLevel off, WITH the cookie (control)"
    local off lines
    off="$(log_offset)"
    run_loadgen "${WORK}/a.txt" 1 "${DURATION}" "${WARMUP}" "${URL}/a"
    assert_common "a" "${WORK}/a.txt"

    lines="$(count_plugin_lines_since "${off}")"
    ((lines == 0)) ||
        fail "a: logLevel off must be silent, got ${lines} plugin line(s): $(plugin_evidence_since "${off}")"
    record "a) off + cookie" "${WORK}/a.txt" "${lines}"
}

case_b() {
    log "bench: case b - logLevel info, WITH the cookie (cheap log path)"
    local off lines
    off="$(log_offset)"
    run_loadgen "${WORK}/b.txt" 1 "${DURATION}" "${WARMUP}" "${URL}/b"
    assert_common "b" "${WORK}/b.txt"

    lines="$(count_plugin_lines_since "${off}")"
    ((lines >= 1)) ||
        fail "b: the info extraction must be reported, got 0 plugin line(s)"
    ((lines <= LINE_BOUND)) ||
        fail "b: ${lines} plugin line(s) > throttling bound ${LINE_BOUND} (3 + (duration + warmup)/5): $(plugin_evidence_since "${off}")"
    record "b) info + cookie" "${WORK}/b.txt" "${lines}"
}

case_c() {
    log "bench: case c - logLevel debug, WITHOUT the cookie (anti-spam)"
    local off lines warns
    off="$(log_offset)"
    run_loadgen "${WORK}/c.txt" 0 "${DURATION}" "${WARMUP}" "${URL}/c"
    assert_common "c" "${WORK}/c.txt"

    lines="$(count_plugin_lines_since "${off}")"
    ((lines >= 1)) ||
        fail "c: expected at least the single warning line, got 0 plugin line(s)"
    ((lines <= MAX_LINES_CASE_C)) ||
        fail "c: ${lines} plugin line(s) exceed ${MAX_LINES_CASE_C}: $(plugin_evidence_since "${off}")"

    # The warning is emitted once per middleware instance: prove it is there.
    warns="$(tail -c "+$((off + 1))" "${TRACEFILE}" 2>/dev/null | grep -acE "${PLUGIN_PREFIX}.*WARN " || true)"
    log "bench: case c - ${lines} plugin line(s), ${warns:-0} warning(s) for the whole case"
    record "c) debug, no cookie" "${WORK}/c.txt" "${lines}"
}

case_d() {
    log "bench: case d - logLevel debug, WITH the cookie (throttled detail)"
    # A warmup pass primes the connections and the throttle clock of the
    # instance; the measured window is then counted alone, so the bound
    # (3 + (duration + warmup)/5) describes the throttled detail path only.
    local off lines
    run_loadgen "${WORK}/d-warmup.txt" 1 "${WARMUP}" "0" "${URL}/d"
    off="$(log_offset)"
    run_loadgen "${WORK}/d.txt" 1 "${DURATION}" "0" "${URL}/d"
    assert_common "d" "${WORK}/d.txt"

    lines="$(count_plugin_lines_since "${off}")"
    ((lines >= 1)) ||
        fail "d: expected at least one plugin line, got 0"
    ((lines <= LINE_BOUND)) ||
        fail "d: ${lines} plugin line(s) > throttling bound ${LINE_BOUND} (2 + duration/5): $(plugin_evidence_since "${off}")"
    record "d) debug + cookie" "${WORK}/d.txt" "${lines}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    require_cmd docker
    require_cmd go
    require_cmd curl

    prepare_scratch
    build_loadgen
    write_static_conf
    write_dynamic_conf

    stand_up
    wait_ready
    check_plugin_instances

    log "bench: workers=${WORKERS} duration=${DURATION} warmup=${WARMUP} line_bound=${LINE_BOUND}"

    case_a
    case_b
    case_c
    case_d

    write_summary

    if ((FAILURES > 0)); then
        die "${FAILURES} assertion(s) failed - see ${ARTIFACTS_DIR}/summary.txt"
    fi
    log "bench: all assertions passed"
}

main "$@"
