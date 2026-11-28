#!/usr/bin/env bash
#
# Integration stand: a real Traefik with the cookieExtract plugin in front of
# traefik/whoami.
#
# Every scenario gets its own middleware instance, and empties the Traefik log
# before the requests it asserts on: the plugin lines are then counted without
# any assumption on the write ordering (see hack/ci/lib.sh).
#
# Scenarios:
#
#   1. translation       cookie -> Authorization: Bearer <value>, a custom header
#                        and an empty prefix, next to other cookies
#   2. spoofing          no cookie + a client-sent Authorization header: with the
#                        default policy (keep) the value reaches the backend, with
#                        strip it is removed and with deny the request is a 401
#   3. log levels        warn / debug / off, the single warning per middleware
#                        instance and the throttled per-request detail
#   4. isolation         two middlewares with different levels in one Traefik
#   5. reload            the middleware instance is rebuilt on a configuration
#                        change and the new log level applies
#   6. JSON cookie       a JSON cookie is forwarded verbatim without cookieField,
#                        and the configured field is extracted with it
#   7. hostile values    a 4 KiB value, sixty cookies, an empty value, percent
#                        sequences (no decoding, so no CRLF injection)
#   8. invalid configs   the middleware is disabled with an explicit error
#
# The summary of a run (checks and evidence) lands in
# artifacts/integration/summary.txt, the Traefik log in artifacts/integration/
# traefik.log (and traefik-full.log for the whole run).
#
#   HTTP_PORT=28100 API_PORT=28180 hack/ci/integration.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAND="integration"
COMPOSE_FILE="${HERE}/docker-compose.stand.yaml"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-cookie-extract-integration}"
# shellcheck source=hack/ci/lib.sh
source "${HERE}/lib.sh"

FAILURES=0

on_exit() {
    local status=$?
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

# write_dynamic <r-reload log level>
#
# One middleware instance per scenario, so that a log assertion is unambiguous.
# r-json reads a JSON session cookie; the three r-bad-* middlewares are disabled
# by the plugin validation (the routers referencing them are dropped).
write_dynamic() {
    local reload_level="${1:-debug}"

    cat >"${DYNAMIC_FILE}" <<YAML
http:
  routers:
    trans:
      rule: "PathPrefix(\`/trans\`)"
      entryPoints: [web]
      middlewares: [r-trans]
      service: target
    custom:
      rule: "PathPrefix(\`/custom\`)"
      entryPoints: [web]
      middlewares: [r-custom]
      service: target
    spoof:
      rule: "PathPrefix(\`/spoof\`)"
      entryPoints: [web]
      middlewares: [r-spoof]
      service: target
    lvl-warn:
      rule: "PathPrefix(\`/lvl-warn\`)"
      entryPoints: [web]
      middlewares: [r-warn]
      service: target
    lvl-debug:
      rule: "PathPrefix(\`/lvl-debug\`)"
      entryPoints: [web]
      middlewares: [r-debug]
      service: target
    lvl-off:
      rule: "PathPrefix(\`/lvl-off\`)"
      entryPoints: [web]
      middlewares: [r-off]
      service: target
    iso:
      rule: "PathPrefix(\`/iso\`)"
      entryPoints: [web]
      middlewares: [r-iso]
      service: target
    iso-off:
      rule: "PathPrefix(\`/iso-off\`)"
      entryPoints: [web]
      middlewares: [r-iso-off]
      service: target
    reload:
      rule: "PathPrefix(\`/reload\`)"
      entryPoints: [web]
      middlewares: [r-reload]
      service: target
    json:
      rule: "PathPrefix(\`/json\`)"
      entryPoints: [web]
      middlewares: [r-json]
      service: target
    field:
      rule: "PathPrefix(\`/field\`)"
      entryPoints: [web]
      middlewares: [r-field]
      service: target
    strip:
      rule: "PathPrefix(\`/strip\`)"
      entryPoints: [web]
      middlewares: [r-strip]
      service: target
    deny:
      rule: "PathPrefix(\`/deny\`)"
      entryPoints: [web]
      middlewares: [r-deny]
      service: target
    hostile:
      rule: "PathPrefix(\`/hostile\`)"
      entryPoints: [web]
      middlewares: [r-hostile]
      service: target
    bad-name:
      rule: "PathPrefix(\`/bad-name\`)"
      entryPoints: [web]
      middlewares: [r-bad-name]
      service: target
    bad-level:
      rule: "PathPrefix(\`/bad-level\`)"
      entryPoints: [web]
      middlewares: [r-bad-level]
      service: target
    bad-header:
      rule: "PathPrefix(\`/bad-header\`)"
      entryPoints: [web]
      middlewares: [r-bad-header]
      service: target

  middlewares:
    r-trans:
      plugin:
        cookieExtract:
          cookieName: access_token
          logLevel: debug

    r-custom:
      plugin:
        cookieExtract:
          cookieName: access_token
          headerNameForCookieValue: X-Access-Token
          cookieValuePrefix: ""
          logLevel: info

    r-spoof:
      plugin:
        cookieExtract:
          cookieName: access_token
          logLevel: debug

    r-warn:
      plugin:
        cookieExtract:
          cookieName: access_token
          logLevel: warn

    r-debug:
      plugin:
        cookieExtract:
          cookieName: access_token
          logLevel: debug

    r-off:
      plugin:
        cookieExtract:
          cookieName: access_token
          logLevel: off

    r-iso:
      plugin:
        cookieExtract:
          cookieName: access_token
          logLevel: debug

    r-iso-off:
      plugin:
        cookieExtract:
          cookieName: access_token
          logLevel: off

    r-reload:
      plugin:
        cookieExtract:
          cookieName: access_token
          logLevel: ${reload_level}

    r-json:
      plugin:
        cookieExtract:
          cookieName: session
          headerNameForCookieValue: X-Session
          cookieValuePrefix: ""
          logLevel: debug

    r-hostile:
      plugin:
        cookieExtract:
          cookieName: access_token
          logLevel: debug

    # The field of a JSON cookie value: the plugin writes the field, not the
    # whole (percent-encoded) payload.
    r-field:
      plugin:
        cookieExtract:
          cookieName: session
          cookieField: user.id
          headerNameForCookieValue: X-Tenant
          cookieValuePrefix: ""
          logLevel: debug

    # A client-supplied header of the same name must not reach the backend.
    r-strip:
      plugin:
        cookieExtract:
          cookieName: access_token
          missingCookiePolicy: strip
          logLevel: debug

    # No cookie: 401 before the backend.
    r-deny:
      plugin:
        cookieExtract:
          cookieName: access_token
          missingCookiePolicy: deny
          logLevel: warn

    r-bad-name:
      plugin:
        cookieExtract:
          cookieName: "bad name"
    r-bad-level:
      plugin:
        cookieExtract:
          cookieName: access_token
          logLevel: verbose
    r-bad-header:
      plugin:
        cookieExtract:
          cookieName: access_token
          headerNameForCookieValue: ""

  services:
    target:
      loadBalancer:
        servers:
          - url: http://target
YAML
}

# run_scenario NAME FUNCTION: a failure is recorded and the run continues, so one
# stand gives the full picture.
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

# ---------------------------------------------------------------------------
# 1. Translation
# ---------------------------------------------------------------------------

scenario_translation() {
    summary "the default middleware turns the cookie into Authorization: Bearer <value>"
    reset_traefik_log

    assert_backend_header "$(http_body "$(backend_url)trans" -H "$(cookie_arg)")" \
        Authorization "Bearer ${COOKIE_VALUE}" "cookie -> Authorization (default header and prefix)"
    wait_plugin_lines 1 'r-trans@file\] INFO  set the Authorization header from the "access_token" cookie' 5 "the extraction is reported at the info level"
    drain_plugin_log
    assert_plugin_lines_exactly 1 'r-trans@file\] INFO  set the Authorization header from the "access_token" cookie' "the extraction is reported once at the info level"

    # The token is a credential: it must not show up in the Traefik log.
    assert_no_value_leak "${COOKIE_VALUE}" "the cookie value is not logged"
    assert_no_process_output "the plugin output stays in the Traefik log file"

    summary "a custom header name and an empty prefix"
    assert_backend_header "$(http_body "$(backend_url)custom" -H "$(cookie_arg)")" \
        X-Access-Token "${COOKIE_VALUE}$" "cookie -> X-Access-Token, verbatim (empty prefix)"
    wait_plugin_lines 1 'r-custom@file\] INFO  set the X-Access-Token header' 5 "the custom header is reported"
    drain_plugin_log
    assert_plugin_lines_exactly 1 'r-custom@file\] INFO  set the X-Access-Token header' "the custom header is reported once"
    assert_backend_header_absent "$(http_body "$(backend_url)custom" -H "$(cookie_arg)")" \
        Authorization "the Authorization header is left untouched by r-custom"

    summary "the cookie is found next to other cookies"
    assert_backend_header "$(http_body "$(backend_url)trans" -H "Cookie: sid=abc; ${COOKIE_NAME}=${COOKIE_VALUE}; theme=dark")" \
        Authorization "Bearer ${COOKIE_VALUE}" "cookie -> Authorization with other cookies present"
}

# ---------------------------------------------------------------------------
# 2. Spoofing (current contract, recorded as a limitation)
# ---------------------------------------------------------------------------

scenario_spoofing() {
    summary "no cookie: the client header is left untouched (LIMITATION, see the README)"
    reset_traefik_log

    assert_backend_header "$(http_body "$(backend_url)spoof" -H "Authorization: Bearer client-supplied")" \
        Authorization "Bearer client-supplied" "a client-sent Authorization survives when the cookie is absent"
    wait_plugin_lines 1 'r-spoof@file\] DEBUG no "access_token" cookie in the request' 5 "the missing cookie detail is reported"
    drain_plugin_log
    assert_plugin_lines_at_most 1 'r-spoof@file\] WARN  no "access_token" cookie in the request' "the missing cookie is warned at most once per instance"
    assert_plugin_lines_exactly 1 'r-spoof@file\] DEBUG no "access_token" cookie in the request' "the missing cookie detail is reported once (throttled)"

    summary "no cookie at all: no header at the backend"
    assert_backend_header_absent "$(http_body "$(backend_url)spoof")" Authorization "no cookie, no client header"

    summary "missingCookiePolicy: strip - the client header never reaches the backend"
    reset_traefik_log
    assert_backend_header_absent "$(http_body "$(backend_url)strip" -H "Authorization: Bearer client-supplied")" \
        Authorization "the client-supplied header was removed by the strip policy"
    wait_plugin_lines 1 'r-strip@file\]' 5 "the strip policy reports the missing value"
    drain_plugin_log
    assert_plugin_lines_at_most 1 'r-strip@file\] WARN  no' "the strip instance warned at most once per instance"

    summary "missingCookiePolicy: deny - 401 before the backend"
    reset_traefik_log
    local deny_code
    deny_code="$(http_code "$(backend_url)deny")"
    ((deny_code == 401)) || die "stand ${STAND}: missingCookiePolicy deny must answer 401, got ${deny_code}"
    assert_backend_header_absent "$(http_body "$(backend_url)deny")" Authorization "the denied request never reached the backend"
    wait_plugin_lines 1 'r-deny@file\] WARN  rejecting the request' 5 "the deny policy reports the rejection"
    summary "  /deny -> HTTP ${deny_code}, no backend call"
}

# ---------------------------------------------------------------------------
# 3. Log levels
# ---------------------------------------------------------------------------

scenario_log_levels() {
    summary "logLevel: warn - ten requests without the cookie produce a single warning"
    reset_traefik_log
    for _ in $(seq 1 10); do http_code "$(backend_url)lvl-warn" >/dev/null; done
    wait_plugin_lines 1 'r-warn@file\] WARN  no "access_token" cookie in the request' 5 "a warning is reported for the requests without the cookie"
    drain_plugin_log
    assert_plugin_lines_exactly 1 'r-warn@file\] WARN  no "access_token" cookie in the request' "one warning for ten requests without the cookie"
    assert_plugin_lines_exactly 0 'r-warn@file\] INFO ' "the warn level does not log the extractions"
    assert_plugin_lines_exactly 0 'r-warn@file\] DEBUG ' "the warn level does not log the detail"

    summary "logLevel: warn - the extractions are not logged either"
    reset_traefik_log
    for _ in $(seq 1 3); do http_code "$(backend_url)lvl-warn" -H "$(cookie_arg)" >/dev/null; done
    drain_plugin_log
    assert_no_plugin_lines_matching 'r-warn@file\]' "the warn level stays silent when the cookie is extracted"

    summary "logLevel: debug - the detail of the missing cookie is throttled"
    reset_traefik_log
    for _ in $(seq 1 10); do http_code "$(backend_url)lvl-debug" >/dev/null; done
    wait_plugin_lines 1 'r-debug@file\] DEBUG no "access_token" cookie in the request' 5 "the per-request detail is reported"
    drain_plugin_log
    assert_plugin_lines_exactly 1 'r-debug@file\] DEBUG no "access_token" cookie in the request' "the per-request detail is throttled (one line per template)"
    assert_plugin_lines_exactly 1 'r-debug@file\] WARN  no "access_token" cookie in the request' "the instance warned once"

    summary "logLevel: off - nothing is logged, the translation still happens"
    reset_traefik_log
    assert_backend_header "$(http_body "$(backend_url)lvl-off" -H "$(cookie_arg)")" \
        Authorization "Bearer ${COOKIE_VALUE}" "logLevel off: the header is still set"
    http_code "$(backend_url)lvl-off" >/dev/null
    drain_plugin_log
    assert_no_plugin_lines_matching 'r-off@file\]' "logLevel off is silent"
    assert_no_process_output "logLevel off writes nothing to the process output"
}

# ---------------------------------------------------------------------------
# 4. Isolation between the middleware instances
# ---------------------------------------------------------------------------

scenario_isolation() {
    summary "per-instance log levels: the debug middleware does not turn on the logs of the others"
    reset_traefik_log

    local code iso_code off_code
    iso_code="$(http_code "$(backend_url)iso" -H "$(cookie_arg)")"
    off_code="$(http_code "$(backend_url)iso-off" -H "$(cookie_arg)")"
    summary "  /iso -> HTTP ${iso_code}, /iso-off -> HTTP ${off_code}"
    ((iso_code == 200)) || die "stand ${STAND}: /iso must answer 200, got ${iso_code}"
    ((off_code == 200)) || die "stand ${STAND}: /iso-off must answer 200, got ${off_code}"

    wait_plugin_lines 1 'r-iso@file\]' 5 "the debug middleware logs its requests"
    drain_plugin_log
    assert_no_plugin_lines_matching 'r-iso-off@file\]' "the off middleware logs nothing, even while a debug instance exists"
}

# ---------------------------------------------------------------------------
# 5. Reload
# ---------------------------------------------------------------------------

scenario_reload() {
    summary "a configuration reload rebuilds the middleware instance and applies the new log level"

    write_dynamic off
    wait_middleware_rebuilt "r-reload@file" 30
    reset_traefik_log

    assert_backend_header "$(http_body "$(backend_url)reload" -H "$(cookie_arg)")" \
        Authorization "Bearer ${COOKIE_VALUE}" "after the reload (logLevel off): the header is still set"
    drain_plugin_log
    assert_no_plugin_lines_matching 'r-reload@file\]' "after the reload to logLevel off: the new instance is silent"

    write_dynamic debug
    wait_middleware_rebuilt "r-reload@file" 30
    reset_traefik_log

    assert_backend_header "$(http_body "$(backend_url)reload" -H "$(cookie_arg)")" \
        Authorization "Bearer ${COOKIE_VALUE}" "after the reload back to debug: the header is still set"
    wait_plugin_lines 1 'r-reload@file\] INFO  set the Authorization header' 5 "after the reload to debug the instance logs again"
    drain_plugin_log
    assert_plugin_lines_exactly 1 'r-reload@file\] INFO  set the Authorization header' "after the reload to debug: the new instance logs once"

    summary "the fresh instance warns once for ten requests without the cookie"
    reset_traefik_log
    for _ in $(seq 1 10); do http_code "$(backend_url)reload" >/dev/null; done
    wait_plugin_lines 1 'r-reload@file\] WARN  no "access_token" cookie in the request' 5 "the fresh instance warns for the first request without the cookie"
    drain_plugin_log
    assert_plugin_lines_exactly 1 'r-reload@file\] WARN  no "access_token" cookie in the request' "one warning for ten requests without the cookie"
    assert_plugin_lines_exactly 1 'r-reload@file\] DEBUG no "access_token" cookie in the request' "the per-request detail is throttled"
}

# ---------------------------------------------------------------------------
# 6. JSON cookie (current contract)
# ---------------------------------------------------------------------------

scenario_json_cookie() {
    summary "a JSON cookie is forwarded verbatim: the plugin has no field support (LIMITATION)"
    reset_traefik_log

    # JSON inside a cookie must be percent-encoded: the quotes are not valid in a
    # cookie value, and Go drops such a cookie before the plugin sees it.
    assert_backend_header "$(http_body "$(backend_url)json" -H 'Cookie: session=%7B%22tenant%22%3A%22acme%22%7D')" \
        X-Session '%7B%22tenant%22%3A%22acme%22%7D$' "the encoded JSON value is forwarded verbatim"

    assert_backend_header_absent "$(http_body "$(backend_url)json" -H 'Cookie: other=1')" \
        X-Session "no session cookie: the header is not set"

    summary "cookieField: the field of the percent-encoded JSON reaches the header"
    reset_traefik_log
    assert_backend_header "$(http_body "$(backend_url)field" -H 'Cookie: session=%7B%22user%22%3A%7B%22id%22%3A%22acme%22%7D%7D')" \
        X-Tenant "acme$" "cookieField extracts a nested field"
    assert_backend_header_absent "$(http_body "$(backend_url)field" -H 'Cookie: session=%7B%22user%22%3A%7B%22name%22%3A%22acme%22%7D%7D')" \
        X-Tenant "cookieField: a missing field leaves the header unset"
    assert_backend_header_absent "$(http_body "$(backend_url)field" -H 'Cookie: session=%7B%22user%22%3A%7B%22id%22%3A%22a%5Cnb%22%7D%7D')" \
        X-Tenant "cookieField: a field carrying a control character is refused"

    summary "a raw JSON cookie is dropped by the HTTP layer before the plugin sees it"
    local code body
    code="$(http_code "$(backend_url)json" -H 'Cookie: session={"tenant":"acme"}')"
    ((code == 200)) || die "stand ${STAND}: a request carrying a raw JSON cookie must still be served, got ${code}"
    body="$(http_body "$(backend_url)json" -H 'Cookie: session={"tenant":"acme"}')"
    assert_backend_header_absent "${body}" X-Session "the invalid cookie is skipped, the header is not set"
    summary "  raw JSON cookie -> HTTP ${code}, no X-Session header (Go drops the invalid cookie)"
}

# ---------------------------------------------------------------------------
# 7. Hostile values
# ---------------------------------------------------------------------------

scenario_hostile_values() {
    summary "a 4 KiB cookie value"
    reset_traefik_log
    local big
    big="$(printf 'a%.0s' $(seq 1 4096))"
    assert_backend_header "$(http_body "$(backend_url)hostile" -H "Cookie: ${COOKIE_NAME}=${big}")" \
        Authorization "Bearer a{20,}" "a 4 KiB value is translated"
    assert_no_value_leak "${big}" "the 4 KiB value is not logged"

    summary "sixty cookies on one request"
    local cookies="" i
    for i in $(seq 1 60); do cookies+="c${i}=v${i}; "; done
    assert_backend_header "$(http_body "$(backend_url)hostile" -H "Cookie: ${cookies}${COOKIE_NAME}=${COOKIE_VALUE}")" \
        Authorization "Bearer ${COOKIE_VALUE}" "the cookie is found among sixty others"

    summary "an empty cookie value is handled like a missing cookie"
    assert_backend_header_absent "$(http_body "$(backend_url)hostile" -H "Cookie: ${COOKIE_NAME}=")" \
        Authorization "an empty value does not set the header"
    assert_backend_header_absent "$(http_body "$(backend_url)strip" -H "Cookie: ${COOKIE_NAME}=" -H "Authorization: Bearer client")" \
        Authorization "strip also removes the client header on an empty value"

    summary "percent sequences are not decoded: no CRLF injection"
    local body
    body="$(http_body "$(backend_url)hostile" -H "Cookie: ${COOKIE_NAME}=x%0D%0AX-Evil:1")"
    assert_backend_header "${body}" Authorization 'Bearer x%0D%0AX-Evil:1$' "the percent sequence is forwarded verbatim"
    assert_backend_header_absent "${body}" X-Evil "the percent sequence did not create a header"
}

# ---------------------------------------------------------------------------
# 8. Invalid configurations
# ---------------------------------------------------------------------------

scenario_invalid_configs() {
    summary "an invalid configuration disables the middleware with an explicit error"

    assert_middleware_disabled "r-bad-name@file" "invalid cookieName" "cookieName that can never match"
    assert_middleware_disabled "r-bad-level@file" "unsupported logLevel" "unsupported logLevel"
    assert_middleware_disabled "r-bad-header@file" "headerNameForCookieValue must not be empty" "empty header name"

    local code
    code="$(http_code "$(backend_url)bad-name")"
    ((code == 404)) || die "stand ${STAND}: the router of a disabled middleware must be dropped (404), got ${code}"
    summary "  the router of a disabled middleware answers 404"
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
    wait_ready "$(backend_url)lvl-off" 60
    init_summary

    summary "stand=${STAND} project=${COMPOSE_PROJECT} http=${HTTP_PORT} api=${API_PORT} traefik=${TRAEFIK_VERSION}"
    summary "plugin sources: ${PLUGIN_DIR}"

    run_scenario "translation" scenario_translation
    run_scenario "spoofing" scenario_spoofing
    run_scenario "log levels" scenario_log_levels
    run_scenario "isolation" scenario_isolation
    run_scenario "reload" scenario_reload
    run_scenario "JSON cookie" scenario_json_cookie
    run_scenario "hostile values" scenario_hostile_values
    run_scenario "invalid configs" scenario_invalid_configs

    assert_no_panic "the whole run"

    summary ""
    summary "scenarios failed: ${FAILURES}"
}

main "$@"
