#!/usr/bin/env bash
#
# End to end verification of the logging behaviour of the plugin, with a real
# Traefik instance loading it from this repository (Traefik local plugins).
#
# It checks that:
#   - the plugin messages show up in the Traefik log file (log.filePath), with the
#     plugin fields, and that nothing leaks to the process output (stdout/stderr),
#     which is what lands in journald, i.e. /var/log/messages on systemd hosts;
#   - a request without the cookie is not warned about on every request (the
#     regression this plugin was rewritten for);
#   - logLevel: off silences the plugin completely;
#   - the translation itself still works: the backend receives the header;
#   - an invalid configuration is rejected with a message that lists the accepted
#     values, instead of silently doing nothing.
#
# Usage:
#   ./e2e.sh                 # runs all the scenarios
#   ./e2e.sh off_is_silent   # runs one scenario
#
# Environment:
#   TRAEFIK_VERSION   Traefik image tag, defaults to v3.8.0
#   PORT              host port published to the Traefik web entry point, defaults to 8099
#   PROJECT           docker compose project name, allows concurrent runs (CI matrix)
#   WORK              scratch directory, defaults to .e2e/<project>
set -euo pipefail

cd "$(dirname "$0")"

PROJECT=${PROJECT:-cookie-extract-e2e}
PORT=${PORT:-8099}
TRAEFIK_VERSION=${TRAEFIK_VERSION:-v3.8.0}
COMPOSE="docker compose -p ${PROJECT} -f docker-compose.e2e.yaml"
COOKIE_NAME=access_token
COOKIE_VALUE=secret-token
EXPECTED_HEADER="Authorization: Bearer ${COOKIE_VALUE}"
WORK=${WORK:-.e2e/${PROJECT}}

# The compose file mounts these three paths; exporting them allows several
# instances of the script to run at the same time (one scratch directory each).
export PLUGIN_DIR="$WORK/plugin"
export DYNAMIC_FILE="$WORK/dynamic.yaml"
export LOGS_DIR="$WORK/logs"

TRACEFILE="$WORK/logs/traefik.log"
OUTPUTFILE="$WORK/logs/process-output.log"
RESPONSEFILE="$WORK/responses.txt"

failures=0

cleanup() {
  ${COMPOSE} down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

log() { printf '\n\033[1m### %s\033[0m\n' "$*"; }
pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; failures=$((failures + 1)); }
info() { printf '  ..   %s\n' "$*"; }

check_contains() { # file pattern(ERE) description
  if grep -qE -- "$2" "$1" 2>/dev/null; then pass "$3"; else fail "$3 (no match for '$2' in $1)"; fi
}

check_not_contains() { # file pattern(ERE) description
  if grep -qE -- "$2" "$1" 2>/dev/null; then fail "$3 (found '$2' in $1)"; else pass "$3"; fi
}

check_count() { # file pattern(ERE) expected description
  local got
  got=$(grep -cE -- "$2" "$1" 2>/dev/null || true)
  got=${got:-0}
  if [[ "$got" == "$3" ]]; then pass "$4 ($got line(s))"; else fail "$4 (expected $3 line(s), got $got)"; fi
}

# prepare_plugin copies the runtime sources: the plugin must need nothing but the
# Go standard library, and the caches of the repository must not be shipped to the
# Docker daemon.
prepare_plugin() {
  rm -rf "$PLUGIN_DIR"
  mkdir -p "$PLUGIN_DIR"
  cp .traefik.yml go.mod "$PLUGIN_DIR/"

  # Every runtime source (the test files are not part of the plugin package): the
  # copy is explicit so that the stand proves the plugin needs nothing but the Go
  # standard library, and a glob so that a new file is never forgotten.
  local f
  for f in ./*.go; do
    case "${f}" in
    *_test.go) continue ;;
    esac
    cp "${f}" "$PLUGIN_DIR/"
  done
}

write_configs() { # plugin_log_level traefik_log_level
  local plugin_level=${1} traefik_level=${2}

  mkdir -p "$LOGS_DIR"

  # Every scenario gets a fresh Traefik: a running instance keeps writing to the
  # inode of a log file removed underneath it, and a configuration change is
  # applied without restarting the container.
  ${COMPOSE} down -v --remove-orphans >/dev/null 2>&1 || true
  rm -f "$TRACEFILE" "$OUTPUTFILE" "$RESPONSEFILE"

  cat >"$DYNAMIC_FILE" <<EOF
http:
  routers:
    extract:
      rule: Host(\`extract.localhost\`)
      entryPoints: [web]
      service: whoami
      middlewares: [cookie-extract]

  middlewares:
    cookie-extract:
      plugin:
        cookieExtract:
          cookieName: ${COOKIE_NAME}
          headerNameForCookieValue: Authorization
          cookieValuePrefix: 'Bearer '
          logLevel: ${plugin_level}

  services:
    whoami:
      loadBalancer:
        servers:
          - url: http://whoami:80
EOF

  TRAEFIK_VERSION="$TRAEFIK_VERSION" TRAEFIK_LOG_LEVEL="$traefik_level" HOST_PORT="$PORT" \
    ${COMPOSE} up -d >/dev/null
}

start_traefik() { # plugin_log_level traefik_log_level [expect_ready]
  local plugin_level=${1} traefik_level=${2} expect_ready=${3:-true}

  write_configs "$plugin_level" "$traefik_level"

  if [[ "$expect_ready" != true ]]; then
    sleep 8
    return 0
  fi

  for _ in $(seq 1 60); do
    if curl -fsS -o /dev/null -H 'Host: extract.localhost' "http://localhost:${PORT}/" 2>/dev/null; then
      return 0
    fi
    sleep 0.5
  done

  fail "Traefik did not become ready (plugin logLevel=${plugin_level}, traefik log level=${traefik_level})"
  ${COMPOSE} logs --no-color traefik | tail -20
  return 1
}

request() { # with_cookie(true|false)
  if [[ "$1" == true ]]; then
    curl -fsS -H 'Host: extract.localhost' -H "Cookie: ${COOKIE_NAME}=${COOKIE_VALUE}" \
      "http://localhost:${PORT}/" >>"$RESPONSEFILE"
  else
    curl -fsS -H 'Host: extract.localhost' "http://localhost:${PORT}/" >>"$RESPONSEFILE"
  fi
}

collect_output() {
  ${COMPOSE} logs --no-color traefik >"$OUTPUTFILE" 2>&1 || true
  info "process output: $(wc -c <"$OUTPUTFILE" | tr -d ' ') bytes, plugin lines in the Traefik log file: $(grep -c 'cookie-extract ' "$TRACEFILE" 2>/dev/null || echo 0)"
}

scenario_logs_in_traefik_logs() {
  log "scenario: plugin logLevel=debug, Traefik log level=DEBUG"
  start_traefik debug DEBUG || return
  request true
  request false
  sleep 1
  collect_output

  check_contains "$TRACEFILE" "cookie-extract .*DEBUG serving GET /" "the request detail is in the Traefik log file (debug)"
  check_contains "$TRACEFILE" 'cookie-extract .*INFO  set the Authorization header from the "access_token" cookie' "the extraction is in the Traefik log file (info)"
  check_contains "$TRACEFILE" 'cookie-extract .*WARN  no "access_token" cookie in the request' "the missing cookie is warned (once)"
  check_not_contains "$TRACEFILE" "$COOKIE_VALUE" "the cookie value is never logged"
  check_not_contains "$OUTPUTFILE" "cookie-extract " "the plugin does not write to the process output"
  check_contains "$RESPONSEFILE" "$EXPECTED_HEADER" "the backend received the header"
}

scenario_missing_cookie_is_not_spammed() {
  log "scenario: plugin logLevel=warn, Traefik log level=DEBUG, 10 requests without the cookie"
  start_traefik warn DEBUG || return
  for _ in $(seq 1 10); do request false; done
  sleep 1
  collect_output

  check_count "$TRACEFILE" 'WARN  no "access_token" cookie in the request' 1 "10 requests without the cookie produce a single warning"
  check_not_contains "$TRACEFILE" "INFO " "the warn level does not log the extractions"
  check_not_contains "$TRACEFILE" "DEBUG " "the warn level does not log the detail"
  check_not_contains "$OUTPUTFILE" "cookie-extract " "the plugin does not write to the process output"
}

scenario_debug_detail_is_throttled() {
  log "scenario: plugin logLevel=debug, Traefik log level=DEBUG, 10 requests without the cookie"
  start_traefik debug DEBUG || return
  for _ in $(seq 1 10); do request false; done
  sleep 1
  collect_output

  check_count "$TRACEFILE" 'DEBUG no "access_token" cookie in the request' 1 "the detail of the missing cookie is throttled"
  check_count "$TRACEFILE" 'WARN  no "access_token" cookie in the request' 1 "the missing cookie is warned once"
}

scenario_off_is_silent() {
  log "scenario: plugin logLevel=off, Traefik log level=DEBUG"
  start_traefik off DEBUG || return
  request true
  request false
  sleep 1
  collect_output

  check_not_contains "$TRACEFILE" "cookie-extract " "off silences the plugin in the Traefik logs"
  check_not_contains "$OUTPUTFILE" "cookie-extract " "off silences the plugin on the process output"
  check_contains "$RESPONSEFILE" "$EXPECTED_HEADER" "the backend still received the header"
}

scenario_default_traefik_level() {
  log "scenario: plugin logLevel=info (default), Traefik log level=ERROR (Traefik default)"
  start_traefik info ERROR || return
  request true
  sleep 1
  collect_output

  check_not_contains "$OUTPUTFILE" "cookie-extract " "no process output, whatever the Traefik log level"
  check_contains "$RESPONSEFILE" "$EXPECTED_HEADER" "the backend received the header"
}

scenario_invalid_configuration() {
  log "scenario: an invalid logLevel is rejected with a clear error"
  start_traefik verbose DEBUG false || return
  collect_output

  check_contains "$TRACEFILE" 'unsupported logLevel .*verbose.*expected one of: off, warn, info, debug' "the error lists the accepted log levels"
  check_not_contains "$OUTPUTFILE" "cookie-extract " "a rejected configuration does not write to the process output"

  log "scenario: an unmatchable cookieName is rejected with a clear error"
  start_traefik info DEBUG false || return
  sed -i.bak "s/cookieName: ${COOKIE_NAME}/cookieName: 'bad name'/" "$DYNAMIC_FILE" && rm -f "$DYNAMIC_FILE.bak"
  ${COMPOSE} restart traefik >/dev/null
  sleep 6
  collect_output

  check_contains "$TRACEFILE" "invalid cookieName" "the error explains why the cookie name can never match"
}

prepare_plugin

scenarios=${*:-"logs_in_traefik_logs missing_cookie_is_not_spammed debug_detail_is_throttled off_is_silent default_traefik_level invalid_configuration"}
for scenario in $scenarios; do
  "scenario_${scenario}"
done

log "summary"
if [[ $failures -eq 0 ]]; then
  printf '  \033[32mall the checks passed\033[0m\n'
else
  printf '  \033[31m%s check(s) failed\033[0m\n' "$failures"
  exit 1
fi
