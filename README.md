# cookieExtract

[![CI](https://github.com/MichNG/traefik-cookie-extract/actions/workflows/ci.yml/badge.svg)](https://github.com/MichNG/traefik-cookie-extract/actions/workflows/ci.yml)

`github.com/MichNG/traefik-cookie-extract` - a Traefik middleware plugin that
takes the value of a cookie and puts it in a header. Standalone project: no
upstream fork history, module path and plugin name are its own.

Applications usually keep their access token in a cookie, while the backend (or
an upstream middleware, an identity-aware gateway, a service mesh sidecar, ...)
expects it as a header. Traefik has no built-in middleware for that
translation: this plugin reads the cookie (`cookieName`), prepends an optional
prefix (`cookieValuePrefix`, `Bearer ` by default) and sets the header
(`headerNameForCookieValue`, `Authorization` by default).

A request that does not carry the cookie is an **expected** case (the client is
not authenticated yet, the request is a health check, an asset, a redirect...):
the header is left untouched and the request reaches the backend unchanged.
Nothing is logged on that path in a way that could flood the logs, and the
plugin never writes to the process output: see [Logs](#logs).

## Installation

```yaml
# Static configuration
experimental:
  plugins:
    cookieExtract:
      moduleName: "github.com/MichNG/traefik-cookie-extract"
      version: "v1.0.0"
```

> **Versioning.** The module path carries no `/v2` suffix, so the Go module rules
> allow only `v0.x` and `v1.x` tags: a `v2.x` tag is rejected by the module proxy
> (`module path must match major version`), the Traefik plugin catalog never sees
> it, and `version: "v2.x.y"` cannot be installed. Breaking changes therefore stay
> inside the `v1.x` line, or need the module path to be renamed to `.../v2`.

For local development, mount the plugin directory and use `localPlugins`:

```yaml
experimental:
  localPlugins:
    cookieExtract:
      moduleName: github.com/MichNG/traefik-cookie-extract
```

## Configuration

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: cookie-extract
  namespace: traefik
spec:
  plugin:
    cookieExtract:
      cookieName: access_token
      headerNameForCookieValue: Authorization
      cookieValuePrefix: "Bearer "
      logLevel: info
```

File provider equivalent:

```yaml
http:
  middlewares:
    cookie-extract:
      plugin:
        cookieExtract:
          cookieName: access_token
```

### Options

| Field | Description | Default |
| :--- | :--- | :--- |
| `cookieName` | Name of the cookie whose value is extracted. Required: an empty name, or a name that can never match a cookie (space, tab, `;`, `,`, `=`, control character), disables the middleware with an explicit error. | — (required) |
| `headerNameForCookieValue` | Header the cookie value is written to. Must not be empty. | `Authorization` |
| `cookieValuePrefix` | String prepended to the cookie value. Set it to `""` to write the raw value. | `Bearer ` |
| `logLevel` | Verbosity of the plugin: `off`, `warn`, `info` or `debug` (case insensitive). See [Logs](#logs). | `info` |

The plugin only reads the request: it never modifies the cookie, and it never
touches a request that does not carry the configured cookie.

## Logs

What is logged, depending on `logLevel`:

| Event | Level |
| :--- | :--- |
| a request without the configured cookie (expected, the header is not set) | `debug` |
| the first request without the configured cookie, per middleware instance | `warn` |
| the header set from the cookie value (the value itself is never logged) | `info` |
| request details (method, path) | `debug` |

A request without the cookie is not warned about on every occurrence: a missing
cookie used to be reported at the `warn` level on each request, which spammed the
system logs of a service whose requests do not all carry the cookie. The first
occurrence is still warned, so that a wrong `cookieName` stays visible at the
`warn` level, and the per-request detail is reported at the `debug` level only.
Identical messages are throttled to one occurrence per template per 5 seconds, so
that a busy service cannot flood the log.

The messages go through the interpreter channel Traefik redirects into its own
logger, so they appear in the Traefik log with the plugin fields (`module`,
`plugin`, `runtime`) at **debug** level - set `log.level: DEBUG` to see them:

```
2026-11-26T20:41:31Z DBG [cookie-extract cookie-extract@file] WARN  no "access_token" cookie in the request module=github.com/MichNG/traefik-cookie-extract plugin=plugin-cookieExtract runtime=
```

The plugin never writes to the process stdout/stderr directly: such writes bypass
the Traefik log level, format and `log.filePath`, and land in the system logs
(journald, `/var/log/messages` on systemd hosts). `logLevel: off` makes the
plugin completely silent.

## Examples

`example/` holds the configuration used by the Docker stand:

* `traefik.yaml`: static configuration (the plugin mounted as a local plugin, in
  DEBUG so that the plugin messages are visible);
* `dynamic.yaml`: three routers: the default `Authorization: Bearer <cookie>`,
  a custom header with an empty prefix, and a middleware set to `logLevel: off`.

## Troubleshooting

### The header is not set

| In the log | Cause | Fix |
| :--- | :--- | :--- |
| `no "access_token" cookie in the request` | the request carries no such cookie (expected case), or the cookie name is wrong | check the cookie name sent by the client (`curl -v`, the browser devtools), and `logLevel: debug` to see the detail |
| the middleware is disabled with `invalid cookieName ...` | the configured name can never match (space, `;`, `,`, `=`, control character) | fix the name: Traefik reports the reason in the middleware status |
| nothing at all, `logLevel: off` | the plugin is silent by design | set `logLevel: info` or `debug` |
| `no "..." cookie` while the client does send it | the cookie belongs to another domain/path, or is `Secure`/`SameSite` filtered | check the `Set-Cookie` attributes of the application |

### The plugin messages are not visible

They are reported at Traefik **debug** level: set `log.level: DEBUG`. Look for the
`[cookie-extract <middleware>]` prefix, and remember that the request detail is
throttled (one identical message per 5 seconds).

## Yaegi constraints

The plugin is interpreted by Traefik, and the interpreter is old on supported
Traefik releases (3.5 ships yaegi v0.16.1). Two rules follow:

* the runtime code may **only import the Go standard library** (the tests use
  `testify` and `mapstructure`, which are test-only dependencies);
* some constructs that compile with `go build` crash the interpreter, or lose
  information across the host/interpreted boundary. Known cases covered here:
  * **forwarding a multi-value call** out of the exported `New`
    (`return newCookieExtract(...)`) drops the error, so Traefik reports
    `invalid handler type: <nil>` instead of the configuration error. `New`
    therefore builds its results explicitly;
  * the synchronisation primitives used by the plugin (`sync.Once` for the
    warning of a missing cookie, `sync.Mutex` for the log throttling) must behave
    inside the interpreter.

`make yaegi-check` compiles the plugin with yaegi v0.16.1 and drives requests
through it (configuration errors, cookie extraction, missing cookie, log
routing): run it before every release, it catches this class of incompatibility
in seconds.

## Development

Examples (`example/`): the Docker stand (`docker-compose.yaml`) mounts the plugin
as a local plugin and serves three routers (`/bearer`, `/custom`, `/quiet`).

```bash
./run-tests.sh -race      # gofmt + go vet + go test (works inside restricted sandboxes)
make yaegi-check          # loads the plugin with yaegi v0.16.1 (as Traefik does)
./e2e.sh                  # end to end check of the logging behaviour on a real Traefik
TRAEFIK_VERSION=v3.6 ./e2e.sh   # against another release (CI runs the v3.5-v3.8 matrix)
docker compose up -d      # the stand of example/
```

Manual check of the translation:

```bash
curl -s -H 'Cookie: access_token=secret' http://localhost:8000/bearer | grep -i authorization
```
