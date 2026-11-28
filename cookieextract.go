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
	"net/url"
	"strings"
	"sync"
)

const (
	defaultHeaderName  = "Authorization"
	defaultValuePrefix = "Bearer "
)

// Values accepted by the missingCookiePolicy option.
const (
	// MissingCookieKeep leaves the target header untouched: a client-supplied
	// header of the same name reaches the backend (historical behaviour).
	MissingCookieKeep = "keep"
	// MissingCookieStrip removes the target header, so that a client cannot
	// smuggle its own value past the middleware.
	MissingCookieStrip = "strip"
	// MissingCookieDeny rejects the request with 401 before the backend is
	// reached.
	MissingCookieDeny = "deny"
)

// Config is the plugin configuration. The defaults are set by CreateConfig, so
// an absent field keeps its default value and a field set to an empty string
// means an empty value.
type Config struct {
	// CookieName is the name of the cookie whose value is extracted. It is
	// required: an empty name, or a name that can never match a cookie,
	// disables the middleware with an explicit error.
	CookieName string `json:"cookieName,omitempty" toml:"cookieName,omitempty" yaml:"cookieName,omitempty" mapstructure:"cookieName"`
	// CookieField selects a field of a JSON cookie value instead of the whole
	// value: dot paths ("user.id"), array indexes ("users.0.id", "items[0].id")
	// and scalars (string, number, boolean) are supported. The value is tried as
	// is, then percent-decoded, because a JSON payload cannot be sent raw inside
	// a cookie. Empty means the whole cookie value.
	CookieField string `json:"cookieField,omitempty" toml:"cookieField,omitempty" yaml:"cookieField,omitempty" mapstructure:"cookieField"`
	// HeaderNameForCookieValue is the header the cookie value is written to.
	// It defaults to Authorization.
	HeaderNameForCookieValue string `json:"headerNameForCookieValue,omitempty" toml:"headerNameForCookieValue,omitempty" yaml:"headerNameForCookieValue,omitempty" mapstructure:"headerNameForCookieValue"`
	// CookieValuePrefix is prepended to the cookie value. It defaults to
	// "Bearer " and may be set to an empty string.
	CookieValuePrefix string `json:"cookieValuePrefix,omitempty" toml:"cookieValuePrefix,omitempty" yaml:"cookieValuePrefix,omitempty" mapstructure:"cookieValuePrefix"`
	// MissingCookiePolicy defines what happens when there is no value to write: a
	// request without the cookie, without the configured field, with an empty
	// cookie value, or with a value carrying control characters.
	//   keep  - the target header is left untouched (default);
	//   strip - the target header is removed, so that a client cannot smuggle its
	//           own value past the middleware;
	//   deny  - the request is rejected with 401.
	MissingCookiePolicy string `json:"missingCookiePolicy,omitempty" toml:"missingCookiePolicy,omitempty" yaml:"missingCookiePolicy,omitempty" mapstructure:"missingCookiePolicy"`
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
		MissingCookiePolicy:      MissingCookieKeep,
		LogLevel:                 LogLevelInfo,
	}
}

// CookieExtract is the middleware handler.
type CookieExtract struct {
	next   http.Handler
	name   string
	logger *pluginLogger

	cookieName    string
	cookieField   string
	headerName    string
	valuePrefix   string
	missingPolicy string

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

	policy, err := parseMissingCookiePolicy(config.MissingCookiePolicy)
	if err != nil {
		return nil, err
	}

	return &CookieExtract{
		next:          next,
		name:          name,
		logger:        newPluginLogger(name, level),
		cookieName:    config.CookieName,
		cookieField:   config.CookieField,
		headerName:    config.HeaderNameForCookieValue,
		valuePrefix:   config.CookieValuePrefix,
		missingPolicy: policy,
	}, nil
}

// ServeHTTP implements http.Handler.
func (ce *CookieExtract) ServeHTTP(rw http.ResponseWriter, req *http.Request) {
	ce.logger.debugf("serving %s %s", req.Method, req.URL.Path)

	value, reason := ce.cookieHeaderValue(req)
	if reason != "" {
		ce.handleMissingValue(rw, req, reason)

		return
	}

	// The value is never logged: it is a credential, and the Traefik log may be
	// shipped to an aggregator.
	req.Header.Set(ce.headerName, ce.valuePrefix+value)
	ce.logger.infof("set the %s header from the %q cookie", ce.headerName, ce.cookieName)

	ce.next.ServeHTTP(rw, req)
}

// cookieHeaderValue returns the value to write into the header, and a non-empty
// reason when there is none (the missing cookie policy then applies).
//
// A missing cookie, an absent field, an empty value and a value carrying control
// characters are all "no value": they are the cases the policy exists for.
func (ce *CookieExtract) cookieHeaderValue(req *http.Request) (string, string) {
	cookie, err := req.Cookie(ce.cookieName)
	if err != nil {
		return "", fmt.Sprintf("no %q cookie in the request", ce.cookieName)
	}

	value := cookie.Value
	if ce.cookieField != "" {
		// A JSON payload cannot be sent raw inside a cookie (the quotes are not
		// valid in a cookie value, and Go drops such a cookie): the raw value is
		// tried first, then the percent-decoded one.
		field, ok := jsonField(value, ce.cookieField)
		if !ok {
			if decoded, decodeErr := url.QueryUnescape(value); decodeErr == nil {
				field, ok = jsonField(decoded, ce.cookieField)
			}
		}
		if !ok {
			return "", fmt.Sprintf("no %q field in the %q cookie", ce.cookieField, ce.cookieName)
		}

		value = field
	}

	if value == "" {
		return "", fmt.Sprintf("the %q cookie is empty", ce.cookieName)
	}

	if hasControlChars(value) {
		return "", fmt.Sprintf("the %q cookie carries control characters", ce.cookieName)
	}

	return value, ""
}

// handleMissingValue applies the configured missingCookiePolicy.
//
// A request without the cookie is an expected case (the client is not
// authenticated yet, the request is a health check, an asset, ...), which is why
// the detail is reported at the debug level and the warning once per middleware
// instance: reporting it at the warn level on every request floods the logs of a
// service whose requests do not all carry the cookie.
func (ce *CookieExtract) handleMissingValue(rw http.ResponseWriter, req *http.Request, reason string) {
	switch ce.missingPolicy {
	case MissingCookieDeny:
		// Every rejection is reported (the logger throttles the message).
		ce.logger.warnf("rejecting the request: %s", reason)
		http.Error(rw, http.StatusText(http.StatusUnauthorized), http.StatusUnauthorized)

	case MissingCookieStrip:
		// A client-supplied header of the same name must not reach the backend.
		ce.missingCookieWarned.Do(func() { ce.logger.warnf("%s", reason) })
		ce.logger.debugf("%s; the %s header was removed", reason, ce.headerName)
		req.Header.Del(ce.headerName)
		ce.next.ServeHTTP(rw, req)

	default:
		ce.missingCookieWarned.Do(func() { ce.logger.warnf("%s", reason) })
		ce.logger.debugf("%s; the %s header is left untouched", reason, ce.headerName)
		ce.next.ServeHTTP(rw, req)
	}
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

	if c.CookieField != "" {
		if err := validateFieldPath("cookieField", c.CookieField); err != nil {
			return err
		}
	}

	return nil
}

// parseMissingCookiePolicy maps the missingCookiePolicy configuration value to
// one of the accepted policies. An empty value means the default (keep).
// It is called by the constructor, so that an unsupported policy fails the
// middleware creation with the list of the accepted values.
func parseMissingCookiePolicy(value string) (string, error) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "", MissingCookieKeep:
		return MissingCookieKeep, nil
	case MissingCookieStrip:
		return MissingCookieStrip, nil
	case MissingCookieDeny:
		return MissingCookieDeny, nil
	default:
		return "", fmt.Errorf("unsupported missingCookiePolicy %q, expected one of: %s, %s, %s",
			value, MissingCookieKeep, MissingCookieStrip, MissingCookieDeny)
	}
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
