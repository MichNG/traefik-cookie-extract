# Changelog

## 1.1.0 (unreleased)

### Added

* the docker stands of the nightly pipeline: `hack/ci/integration.sh` (log
  routing and levels, spoofing, JSON cookie, hostile values, reload, invalid
  configurations), `hack/ci/chaos.sh` (backend and Traefik restarts, a reload
  storm, hostile requests and a spam phase, all under load) and
  `hack/bench/run.sh` (a stdlib load generator, throughput and latency
  percentiles per case, and the plugin log volume under load);
* `.github/workflows/nightly.yml`: unit + yaegi, the integration stand, the chaos
  stand and the load stand, with the stand logs uploaded on failure;
* the load stand measures the property this plugin was written for: thousands of
  requests without the cookie produce a handful of log lines (throttling and one
  warning per middleware instance), instead of one warning per request.

## 1.0.0 (2026-11-26)

Initial release of `traefik-cookie-extract`, a standalone Traefik middleware
plugin (the module path and the plugin name are its own).

* extracts the value of a cookie into a header: `cookieName`,
  `headerNameForCookieValue` (default `Authorization`), `cookieValuePrefix`
  (default `Bearer `, an explicit empty value is preserved);
* the configuration is validated when the middleware is created: a missing
  `cookieName`, an empty header name or a cookie name that can never match
  (space, tab, `;`, `,`, `=`, control character) disable the middleware with an
  explicit error instead of silently leaving the header unset;
* a request without the cookie is an expected case: it is reported at the debug
  level (throttled, one identical message per template per 5 seconds) and warned
  about once per middleware instance, so that a wrong `cookieName` stays visible
  without flooding the logs;
* the plugin logs into the Traefik log through the interpreter channel Traefik
  redirects (debug level, plugin fields `module`, `plugin`, `runtime`), and never
  writes to the process stdout/stderr: the messages no longer land in the system
  logs (journald, `/var/log/messages` on systemd hosts);
* `logLevel` accepts `off`, `warn`, `info` (default) and `debug`, and is bound to
  the middleware instance (a verbose middleware does not turn on the logs of the
  other instances);
* the cookie value is never logged: it is a credential, and the Traefik log may
  be shipped to an aggregator;
* test-only dependencies (`testify`, `mapstructure`), a `make yaegi-check`
  compatibility check against yaegi v0.16.1, an `example/` Docker stand and an
  end to end check of the logging behaviour (`./e2e.sh`).
