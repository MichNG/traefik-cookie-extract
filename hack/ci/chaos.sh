#!/usr/bin/env bash
#
# Chaos stand: the cookieExtract plugin must keep serving (and never flood the
# logs) while the stand is being broken on purpose.
#
# The scenarios inject a fault while traffic is running through the plugin and
# check the invariants that matter in production:
#
#   1. baseline          traffic without any fault: all 200
#   2. backend restart   traefik/whoami is restarted under load: the requests
#                        during the fault fail (that is the backend, not the
#                        plugin), the traffic recovers, and the plugin still sets
#                        the header; the logs stay bounded
#   3. traefik restart   Traefik itself is restarted under load: the stand comes
#                        back, the middleware instance is rebuilt, the plugin
#                        still works, no panic
#   4. reload storm      the dynamic configuration is rewritten fifteen times
#                        under load: every middleware instance is rebuilt, the
#                        traffic keeps being served, and the log stays bounded
#   5. hostile requests  an 8 KiB cookie, 120 cookies, an empty value, percent
#                        sequences and an invalid byte: always served, never a
#                        panic, no injected header
#   6. spam under load   thousands of requests without the cookie: a handful of
#                        log lines only (throttling + one warning per instance)
#
#   HTTP_PORT=28400 API_PORT=28480 hack/ci/chaos.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAND="chaos"
COMPOSE_FILE="${HERE}/docker-compose.stand.yaml"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-cookie-extract-chaos}"
LOAD_WORKERS="${LOAD_WORKERS:-8}"
# shellcheck source=hack/ci/lib.sh
source "${HERE}/lib.sh"

FAILURES=0
LOAD_PID=""

on_exit() {
    local status=$?
    [[ -n "${LOAD_PID}" ]] && kill "${LOAD_PID}" 2>/dev/null || true
    dump_stand_state
    stand_down
    if ((FAILURES > 0)); then
        warn "stand ${STAND}: ${FAILURES} scenario(s) failed - see $(stand_dir)/summary.txt"
        exit 1
    fi
    exit "${status}"
}
trap on_exit EXIT

# ---------------------------------------------------------------------------
# Stand configuration
# ---------------------------------------------------------------------------

# write_dynamic <r-chaos log level>
write_dynamic() {
    local level="${1:-debug}"

    cat >"${DYNAMIC_FILE}" <<YAML
http:
  routers:
    chaos:
      rule: "PathPrefix(\`/chaos\`)"
      entryPoints: [web]
      middlewares: [r-chaos]
      service: target

  middlewares:
    r-chaos:
      plugin:
        cookieExtract:
          cookieName: access_token
          logLevel: ${level}

  services:
    target:
      loadBalancer:
        servers:
          - url: http://target
YAML
}

# run_scenario NAME FUNCTION: a failure is recorded and the run continues.
run_scenario() {
    local name="$1" fn="$2"
    summary ""
    summary "### ${name}"
    if (set -e; "${fn}"); then
        summary "scenario ${name}: OK"
        log "scenario ${name}: OK"
    else
        summary "scenario ${name}: FAILED"
        warn "scenario ${name}: FAILED"
        FAILURES=$((FAILURES + 1))
    fi
}

# run_phase NAME SECONDS ASSERT: hammers the router for a while, writes the status
# of every request into an artifact file, and asserts on it when ASSERT is true.
run_phase() { # NAME SECONDS ASSERT [curl args...]
    local name="$1" seconds="$2" assert="$3"
    shift 3

    local out stop
    out="$(tmp_file "requests-${name}.txt")"
    stop="$(tmp_file ".stop-load-${name}")"
    rm -f "${stop}"

    LOAD_WORKERS="${LOAD_WORKERS}" background_load "${out}" "${stop}" "$(backend_url)chaos" "$@" &
    LOAD_PID=$!

    sleep "${seconds}"
    : >"${stop}"
    wait "${LOAD_PID}" 2>/dev/null || true
    LOAD_PID=""

    show_histogram "${out}" "${name}"

    if [[ "${assert}" == "true" ]]; then
        assert_no_5xx "${out}" "${name}"
        assert_no_transport_errors "${out}" "${name}"
        assert_all_codes "${out}" 200 "${name}"
    fi
}

# wait_back: waits for the router to answer again after a fault.
wait_back() {
    wait_ready "$(backend_url)chaos" 60 -H "$(cookie_arg)"
}

# ---------------------------------------------------------------------------
# 1. Baseline
# ---------------------------------------------------------------------------

scenario_baseline() {
    summary "traffic without any fault: every request is served and translated"
    reset_traefik_log

    run_phase "baseline" 3 true -H "$(cookie_arg)"

    assert_backend_header "$(http_body "$(backend_url)chaos" -H "$(cookie_arg)")" \
        Authorization "Bearer ${COOKIE_VALUE}" "the header is set before the faults"
    assert_no_panic "before the faults"
}

# ---------------------------------------------------------------------------
# 2. Backend restart under load
# ---------------------------------------------------------------------------

scenario_backend_restart() {
    summary "the backend is restarted while the plugin serves traffic"
    reset_traefik_log

    run_phase "backend-restart" 6 false -H "$(cookie_arg)" &
    local phase=$!
    sleep 2
    stand_restart target
    wait "${phase}" 2>/dev/null || true
    show_histogram "$(tmp_file "requests-backend-restart.txt")" "backend restart (fault window, not asserted)"

    wait_back

    run_phase "backend-recovered" 3 true -H "$(cookie_arg)"
    assert_backend_header "$(http_body "$(backend_url)chaos" -H "$(cookie_arg)")" \
        Authorization "Bearer ${COOKIE_VALUE}" "the header is still set after the backend restart"
    assert_no_panic "after the backend restart"
}

# ---------------------------------------------------------------------------
# 3. Traefik restart under load
# ---------------------------------------------------------------------------

scenario_traefik_restart() {
    summary "Traefik itself is restarted while the plugin serves traffic"
    reset_traefik_log

    run_phase "traefik-restart" 6 false -H "$(cookie_arg)" &
    local phase=$!
    sleep 2
    stand_restart traefik
    wait "${phase}" 2>/dev/null || true
    show_histogram "$(tmp_file "requests-traefik-restart.txt")" "traefik restart (fault window, not asserted)"

    wait_back
    # Traefik has reloaded the whole configuration: the plugin is loaded again.
    wait_log_pattern 'Plugins loaded' 1 60 "Traefik is back after the restart"

    run_phase "traefik-recovered" 3 true -H "$(cookie_arg)"
    assert_backend_header "$(http_body "$(backend_url)chaos" -H "$(cookie_arg)")" \
        Authorization "Bearer ${COOKIE_VALUE}" "the header is still set after the Traefik restart"
    assert_no_panic "after the Traefik restart"

    # The whole log of the scenario: the fault window, the probes of wait_back
    # and the recovered phase. Traefik rebuilds the middleware instance on the
    # restart, and every instance throttles its own messages, so the total stays
    # bounded even though the traffic spans the fault.
    local lines
    lines="$(count_plugin_lines)"
    ((lines >= 1 && lines <= 20)) ||
        die "stand ${STAND}: ${lines} plugin lines over the restart scenario, expected 1..20 (throttling)"
    summary "  ${lines} plugin lines over the restart scenario (bounded)"
}

# ---------------------------------------------------------------------------
# 4. Reload storm
# ---------------------------------------------------------------------------

scenario_reload_storm() {
    summary "the dynamic configuration is rewritten fifteen times under load"
    reset_traefik_log

    local out stop
    out="$(tmp_file "requests-reload-storm.txt")"
    stop="$(tmp_file ".stop-load-reload-storm")"
    rm -f "${stop}"

    LOAD_WORKERS="${LOAD_WORKERS}" background_load "${out}" "${stop}" "$(backend_url)chaos" -H "$(cookie_arg)" &
    LOAD_PID=$!

    local i level
    for i in $(seq 1 15); do
        if ((i % 2)); then level="off"; else level="debug"; fi
        write_dynamic "${level}"
        sleep 0.4
    done

    # The last configuration wins: wait for the instance it built.
    write_dynamic debug
    wait_middleware_rebuilt "r-chaos@file" 60
    wait_ready "$(backend_url)chaos" 30 -H "$(cookie_arg)"

    : >"${stop}"
    wait "${LOAD_PID}" 2>/dev/null || true
    LOAD_PID=""
    show_histogram "${out}" "reload storm (fault window, not asserted)"

    local lines
    lines="$(count_plugin_lines)"
    ((lines <= 60)) || die "stand ${STAND}: ${lines} plugin lines after 15 reloads, expected at most 60 (one instance at a time)"

    run_phase "reload-recovered" 3 true -H "$(cookie_arg)"
    assert_backend_header "$(http_body "$(backend_url)chaos" -H "$(cookie_arg)")" \
        Authorization "Bearer ${COOKIE_VALUE}" "the header is still set after the reload storm"
    assert_no_panic "after the reload storm"
    summary "  ${lines} plugin lines over the storm (bounded, 15 instances)"
}

# ---------------------------------------------------------------------------
# 5. Hostile requests
# ---------------------------------------------------------------------------

scenario_hostile_requests() {
    summary "hostile cookie values are always served, never injected"
    reset_traefik_log

    local big code body
    big="$(printf 'a%.0s' $(seq 1 8192))"
    code="$(http_code "$(backend_url)chaos" -H "Cookie: ${COOKIE_NAME}=${big}")"
    ((code == 200)) || die "stand ${STAND}: an 8 KiB cookie must be served, got ${code}"
    assert_backend_header "$(http_body "$(backend_url)chaos" -H "Cookie: ${COOKIE_NAME}=${big}")" \
        Authorization "Bearer a{20,}" "an 8 KiB value is translated"
    assert_no_value_leak "${big}" "the 8 KiB value is not logged"

    local cookies="" i
    for i in $(seq 1 120); do cookies+="c${i}=v${i}; "; done
    code="$(http_code "$(backend_url)chaos" -H "Cookie: ${cookies}${COOKIE_NAME}=${COOKIE_VALUE}")"
    ((code == 200)) || die "stand ${STAND}: a request with 120 cookies must be served, got ${code}"
    assert_backend_header "$(http_body "$(backend_url)chaos" -H "Cookie: ${cookies}${COOKIE_NAME}=${COOKIE_VALUE}")" \
        Authorization "Bearer ${COOKIE_VALUE}" "the cookie is found among 120 others"

    summary "an empty cookie value is handled like a missing cookie"
    assert_backend_header_absent "$(http_body "$(backend_url)chaos" -H "Cookie: ${COOKIE_NAME}=")" \
        Authorization "an empty value does not set the header"

    body="$(http_body "$(backend_url)chaos" -H "Cookie: ${COOKIE_NAME}=x%0D%0AX-Evil:1")"
    assert_backend_header_absent "${body}" X-Evil "a percent sequence does not create a header"

    # An invalid byte in the cookie value: the HTTP layer drops the cookie, the
    # plugin must simply pass the request through.
    code="$(http_code "$(backend_url)chaos" -H "$(printf 'Cookie: %s=\xff' "${COOKIE_NAME}")")"
    ((code == 200 || code == 400)) || die "stand ${STAND}: an invalid cookie byte must be dropped or rejected, got ${code}"
    summary "  an invalid cookie byte -> HTTP ${code}"

    assert_no_panic "after the hostile requests"
}

# ---------------------------------------------------------------------------
# 6. Spam under load
# ---------------------------------------------------------------------------

scenario_spam_under_load() {
    summary "thousands of requests without the cookie stay quiet in the log"
    reset_traefik_log

    LOAD_WORKERS="${LOAD_WORKERS}" run_phase "spam" 8 true

    local requests lines
    requests="$(grep -c . "$(tmp_file "requests-spam.txt")" || printf 0)"
    lines="$(count_plugin_lines)"

    ((requests >= 500)) || die "stand ${STAND}: only ${requests} requests in the spam phase, expected at least 500"
    ((lines >= 1 && lines <= 10)) ||
        die "stand ${STAND}: ${lines} plugin lines for ${requests} requests without the cookie, expected 1..10 (throttling + one warning)"

    summary "  ${requests} requests without the cookie -> ${lines} plugin line(s)"
    assert_no_panic "after the spam phase"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    require_cmd docker
    require_cmd curl

    reset_logs
    prepare_plugin
    write_dynamic debug
    stand_up
    wait_ready "$(backend_url)chaos" 60 -H "$(cookie_arg)"
    init_summary

    summary "stand=${STAND} project=${COMPOSE_PROJECT} http=${HTTP_PORT} api=${API_PORT} traefik=${TRAEFIK_VERSION}"
    summary "load: ${LOAD_WORKERS} workers"

    run_scenario "baseline" scenario_baseline
    run_scenario "backend restart under load" scenario_backend_restart
    run_scenario "traefik restart under load" scenario_traefik_restart
    run_scenario "reload storm" scenario_reload_storm
    run_scenario "hostile requests" scenario_hostile_requests
    run_scenario "spam under load" scenario_spam_under_load

    assert_no_panic "the whole run"

    summary ""
    summary "scenarios failed: ${FAILURES}"
}

main "$@"
