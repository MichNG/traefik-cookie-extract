// Package traefik_cookie_extract implements the cookieExtract middleware: it
// takes the value of a cookie (typically an access token) and puts it in a
// header (Authorization by default), with an optional value prefix, so that a
// downstream service or another middleware can consume it as a regular header.
//
// A request that does not carry the cookie is an expected case: the header is
// left untouched and the request reaches the backend unchanged. Such a request
// is not warned about on every occurrence (see logMissingCookie), and the plugin
// never writes to the process output: its messages go to the Traefik log.
package traefik_cookie_extract

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"sync"
)

const (
	defaultHeaderName  = "Authorization"
	defaultValuePrefix = "Bearer "
)

// Config is the plugin configuration. The defaults are set by CreateConfig, so
// an absent field keeps its default value and a field set to an empty string
// means an empty value.
type Config struct {
	// CookieName is the name of the cookie whose value is extracted. It is
	// required: an empty name, or a name that can never match a cookie,
	// disables the middleware with an explicit error.
	CookieName string `json:"cookieName,omitempty" toml:"cookieName,omitempty" yaml:"cookieName,omitempty" mapstructure:"cookieName"`
	// HeaderNameForCookieValue is the header the cookie value is written to.
	// It defaults to Authorization.
	HeaderNameForCookieValue string `json:"headerNameForCookieValue,omitempty" toml:"headerNameForCookieValue,omitempty" yaml:"headerNameForCookieValue,omitempty" mapstructure:"headerNameForCookieValue"`
	// CookieValuePrefix is prepended to the cookie value. It defaults to
	// "Bearer " and may be set to an empty string.
	CookieValuePrefix string `json:"cookieValuePrefix,omitempty" toml:"cookieValuePrefix,omitempty" yaml:"cookieValuePrefix,omitempty" mapstructure:"cookieValuePrefix"`
	// LogLevel is the verbosity of the plugin: off, warn, info (default) or
	// debug. See the README: the messages are reported in the Traefik log, and
	// `off` silences the plugin completely.
	LogLevel string `json:"logLevel,omitempty" toml:"logLevel,omitempty" yaml:"logLevel,omitempty" mapstructure:"logLevel"`
}

// CreateConfig creates the default plugin configuration.
func CreateConfig() *Config {
	return &Config{
		HeaderNameForCookieValue: defaultHeaderName,
		CookieValuePrefix:        defaultValuePrefix,
		LogLevel:                 LogLevelInfo,
	}
}

// CookieExtract is the middleware handler.
type CookieExtract struct {
	next   http.Handler
	name   string
	logger *pluginLogger

	cookieName  string
	headerName  string
	valuePrefix string

	// missingCookieWarned limits the warning of a request without the cookie
	// to the first occurrence of the middleware instance.
	missingCookieWarned sync.Once
}

// New creates a new cookieExtract middleware.
//
// The results are returned explicitly, and not by forwarding the call
// (`return newCookieExtract(...)`): yaegi loses the error of a forwarded
// multi-value call crossing the host/interpreted boundary, so Traefik would
// report a nil handler with a nil error ("invalid handler type: <nil>") and the
// operator would never see the configuration error. `make yaegi-check` guards
// this.
func New(ctx context.Context, next http.Handler, config *Config, name string) (http.Handler, error) {
	handler, err := newCookieExtract(ctx, next, config, name)
	if err != nil {
		return nil, err
	}

	return handler, nil
}

// newCookieExtract is the testable constructor.
func newCookieExtract(_ context.Context, next http.Handler, config *Config, name string) (*CookieExtract, error) {
	if config == nil {
		return nil, errors.New("empty configuration")
	}

	level, err := parseLogLevel(config.LogLevel)
	if err != nil {
		return nil, err
	}

	if err := config.validate(); err != nil {
		return nil, err
	}

	return &CookieExtract{
		next:        next,
		name:        name,
		logger:      newPluginLogger(name, level),
		cookieName:  config.CookieName,
		headerName:  config.HeaderNameForCookieValue,
		valuePrefix: config.CookieValuePrefix,
	}, nil
}

// ServeHTTP implements http.Handler.
func (ce *CookieExtract) ServeHTTP(rw http.ResponseWriter, req *http.Request) {
	ce.logger.debugf("serving %s %s", req.Method, req.URL.Path)

	cookie, err := req.Cookie(ce.cookieName)
	if err != nil {
		ce.logMissingCookie()
		ce.next.ServeHTTP(rw, req)

		return
	}

	// The value is never logged: it is a credential, and the Traefik log may be
	// shipped to an aggregator.
	req.Header.Set(ce.headerName, ce.valuePrefix+cookie.Value)
	ce.logger.infof("set the %s header from the %q cookie", ce.headerName, ce.cookieName)

	ce.next.ServeHTTP(rw, req)
}

// logMissingCookie reports a request without the configured cookie.
//
// A missing cookie is an expected case (the client is not authenticated yet,
// the request is a health check, an asset, ...): the header is simply not set.
// Reporting it at the warn level on every request floods the logs of a service
// whose requests do not all carry the cookie, hence:
//
//   - the detail goes to the debug level, throttled like the other messages
//     (logLevel: debug shows it);
//   - a single warning is emitted per middleware instance, so that a wrong
//     cookieName stays visible at the warn level without flooding the log.
func (ce *CookieExtract) logMissingCookie() {
	ce.missingCookieWarned.Do(func() {
		ce.logger.warnf("no %q cookie in the request", ce.cookieName)
	})

	ce.logger.debugf("no %q cookie in the request", ce.cookieName)
}

// validate checks the configuration, so that mistakes are reported when the
// middleware is created rather than on the first request.
func (c *Config) validate() error {
	if c.CookieName == "" {
		return errors.New("cookieName is required")
	}

	if err := validateCookieName(c.CookieName); err != nil {
		return err
	}

	if c.HeaderNameForCookieValue == "" {
		return errors.New("headerNameForCookieValue must not be empty")
	}

	return nil
}

// validateCookieName rejects the names that can never match a cookie: reading a
// cookie whose name contains a space, a separator or a control character always
// fails, so the header would silently never be set.
func validateCookieName(name string) error {
	if strings.ContainsAny(name, " \t;,=") {
		return fmt.Errorf("invalid cookieName %q: a cookie name cannot contain a space, a tab, ';', ',' or '='", name)
	}

	for _, r := range name {
		if r < 0x20 || r == 0x7f {
			return fmt.Errorf("invalid cookieName %q: a cookie name cannot contain control characters", name)
		}
	}

	return nil
}
