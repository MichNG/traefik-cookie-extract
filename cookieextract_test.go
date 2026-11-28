package traefik_cookie_extract

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/mitchellh/mapstructure"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const (
	testCookieName  = "test_access_token"
	testCookieValue = "pretend_to_be_auth_token"
	testHeaderName  = "Authorization"
	testValuePrefix = "Bearer "
)

var (
	minCookie = http.Cookie{Name: testCookieName, Value: testCookieValue}
	maxCookie = http.Cookie{
		Name:     testCookieName,
		Value:    testCookieValue,
		Path:     "/path/to",
		Domain:   "example.com",
		Expires:  time.Now(),
		MaxAge:   5,
		Secure:   true,
		HttpOnly: true,
		SameSite: http.SameSiteNoneMode,
	}
	expiredCookie  = http.Cookie{Name: testCookieName, Value: testCookieValue, MaxAge: 0}
	garbageCookie  = http.Cookie{Name: "some_cookie_garbage", Value: "bla bla foo bar"}
	anotherCookie  = http.Cookie{Name: "session", Value: "abc123"}
	emptyValue     = http.Cookie{Name: testCookieName, Value: ""}
	wantHeaderLine = testValuePrefix + testCookieValue
)

func TestCreateConfig(t *testing.T) {
	cfg := CreateConfig()

	require.NotNil(t, cfg)
	assert.Empty(t, cfg.CookieName)
	assert.Empty(t, cfg.CookieField)
	assert.Equal(t, defaultHeaderName, cfg.HeaderNameForCookieValue)
	assert.Equal(t, defaultValuePrefix, cfg.CookieValuePrefix)
	assert.Equal(t, MissingCookieKeep, cfg.MissingCookiePolicy)
	assert.Equal(t, LogLevelInfo, cfg.LogLevel)
}

// TestConfigDecoding decodes the configuration exactly like the Traefik plugin
// loader does (mapstructure with WeaklyTypedInput over the CreateConfig result),
// so that a decoder tag or a default value mistake is caught by the tests.
func TestConfigDecoding(t *testing.T) {
	t.Run("the defaults are kept for the absent fields", func(t *testing.T) {
		cfg := decodeConfig(t, map[string]interface{}{"cookieName": testCookieName})

		assert.Equal(t, testCookieName, cfg.CookieName)
		assert.Equal(t, defaultHeaderName, cfg.HeaderNameForCookieValue)
		assert.Equal(t, defaultValuePrefix, cfg.CookieValuePrefix)
		assert.Equal(t, LogLevelInfo, cfg.LogLevel)
	})

	t.Run("the JSON field and the missing cookie policy are decoded", func(t *testing.T) {
		cfg := decodeConfig(t, map[string]interface{}{
			"cookieName":          testCookieName,
			"cookieField":         "user.id",
			"missingCookiePolicy": MissingCookieStrip,
		})

		assert.Equal(t, "user.id", cfg.CookieField)
		assert.Equal(t, MissingCookieStrip, cfg.MissingCookiePolicy)
	})

	t.Run("every field is decoded", func(t *testing.T) {
		cfg := decodeConfig(t, map[string]interface{}{
			"cookieName":               testCookieName,
			"headerNameForCookieValue": "X-Access-Token",
			"cookieValuePrefix":        "",
			"logLevel":                 LogLevelDebug,
		})

		assert.Equal(t, testCookieName, cfg.CookieName)
		assert.Equal(t, "X-Access-Token", cfg.HeaderNameForCookieValue)
		assert.Empty(t, cfg.CookieValuePrefix, "an explicit empty prefix must be preserved")
		assert.Equal(t, LogLevelDebug, cfg.LogLevel)
	})
}

func TestNewRejectsAnInvalidConfiguration(t *testing.T) {
	tests := []struct {
		name string
		cfg  *Config
		want string
	}{
		{name: "nil configuration", cfg: nil, want: "empty configuration"},
		{name: "missing cookieName", cfg: &Config{}, want: "cookieName is required"},
		{
			name: "cookieName with a space",
			cfg:  &Config{CookieName: "bad name"},
			want: `invalid cookieName "bad name"`,
		},
		{
			name: "cookieName with a separator",
			cfg:  &Config{CookieName: "bad;name"},
			want: "invalid cookieName",
		},
		{
			name: "cookieName with a control character",
			cfg:  &Config{CookieName: "bad\x7fname"},
			want: "control characters",
		},
		{
			name: "empty headerNameForCookieValue",
			cfg:  &Config{CookieName: testCookieName, HeaderNameForCookieValue: ""},
			want: "headerNameForCookieValue must not be empty",
		},
		{
			name: "unsupported logLevel",
			cfg:  &Config{CookieName: testCookieName, LogLevel: "verbose"},
			want: `unsupported logLevel "verbose", expected one of: off, warn, info, debug`,
		},
		{
			name: "unsupported missingCookiePolicy",
			cfg:  &Config{CookieName: testCookieName, HeaderNameForCookieValue: testHeaderName, MissingCookiePolicy: "drop"},
			want: `unsupported missingCookiePolicy "drop", expected one of: keep, strip, deny`,
		},
		{
			name: "invalid cookieField",
			cfg:  &Config{CookieName: testCookieName, HeaderNameForCookieValue: testHeaderName, CookieField: "user..id"},
			want: "invalid cookieField",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			handler, err := New(context.Background(), nextHandler(&http.Header{}), test.cfg, "test")

			require.Error(t, err)
			assert.Nil(t, handler)
			assert.Contains(t, err.Error(), test.want)
		})
	}
}

func TestNewAcceptsTheValidLogLevels(t *testing.T) {
	for _, level := range []string{"", LogLevelOff, LogLevelWarn, LogLevelInfo, LogLevelDebug, "DEBUG", " Info "} {
		t.Run(level, func(t *testing.T) {
			cfg := testConfig()
			cfg.LogLevel = level

			handler, err := New(context.Background(), nextHandler(&http.Header{}), cfg, "test")

			require.NoError(t, err)
			assert.NotNil(t, handler)
		})
	}
}

func TestServeHTTPSetsTheHeaderFromTheCookie(t *testing.T) {
	tests := []struct {
		name    string
		cfg     func(*Config)
		cookies []*http.Cookie
		want    string
	}{
		{
			name:    "the minimal cookie",
			cookies: []*http.Cookie{&minCookie},
			want:    wantHeaderLine,
		},
		{
			name:    "the full cookie",
			cookies: []*http.Cookie{&maxCookie},
			want:    wantHeaderLine,
		},
		{
			name:    "an expired cookie",
			cookies: []*http.Cookie{&expiredCookie},
			want:    wantHeaderLine,
		},
		{
			// An empty cookie value is handled like a missing cookie: the missing
			// cookie policy applies and the header is left untouched by default.
			name:    "an empty value",
			cookies: []*http.Cookie{&emptyValue},
			want:    "",
		},
		{
			name:    "no cookie",
			cookies: nil,
			want:    "",
		},
		{
			name:    "another cookie only",
			cookies: []*http.Cookie{&anotherCookie, &garbageCookie},
			want:    "",
		},
		{
			name:    "the cookie next to others",
			cookies: []*http.Cookie{&anotherCookie, &minCookie, &garbageCookie},
			want:    wantHeaderLine,
		},
		{
			name:    "a custom header name",
			cfg:     func(c *Config) { c.HeaderNameForCookieValue = "X-Access-Token" },
			cookies: []*http.Cookie{&minCookie},
			want:    wantHeaderLine,
		},
		{
			name:    "an empty prefix",
			cfg:     func(c *Config) { c.CookieValuePrefix = "" },
			cookies: []*http.Cookie{&minCookie},
			want:    testCookieValue,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			cfg := testConfig()
			if test.cfg != nil {
				test.cfg(cfg)
			}

			// The request messages are not asserted here: they are dropped to
			// keep the test output clean.
			captureStdout(t)

			handler, seen := newMiddleware(t, cfg)
			rec := send(handler, test.cookies...)

			require.Equal(t, http.StatusOK, rec.Code)
			assert.Equal(t, test.want, (*seen).Get(cfg.HeaderNameForCookieValue))
		})
	}
}

// TestMissingCookieIsNotSpammed is the regression test of the reported issue: a
// request without the cookie is an expected case, it must not be warned about on
// every request, while a wrong cookieName must stay visible.
func TestMissingCookieIsNotSpammed(t *testing.T) {
	const requests = 10

	t.Run("a single warning per middleware instance", func(t *testing.T) {
		cfg := testConfig()
		cfg.LogLevel = LogLevelWarn

		handler, seen := newMiddleware(t, cfg)
		stdout := captureStdout(t)

		for i := 0; i < requests; i++ {
			send(handler)
		}

		assert.Equal(t, 1, strings.Count(stdout(), "WARN  no"), "expected a single warning for %d requests", requests)
		assert.Empty(t, (*seen).Get(testHeaderName))
	})

	t.Run("the debug detail is throttled", func(t *testing.T) {
		cfg := testConfig()
		cfg.LogLevel = LogLevelDebug

		handler, _ := newMiddleware(t, cfg)
		stdout := captureStdout(t)

		for i := 0; i < requests; i++ {
			send(handler)
		}

		out := stdout()
		assert.Equal(t, 1, strings.Count(out, "WARN  no"), "expected a single warning for %d requests", requests)
		assert.Equal(t, 1, strings.Count(out, "DEBUG no"), "expected the throttled debug detail, got: %q", out)
	})
}

func TestLogLevelsOnRequests(t *testing.T) {
	tests := []struct {
		name       string
		level      string
		withCookie bool
		want       []string
		wantAbsent []string
	}{
		{
			name:       "off logs nothing",
			level:      LogLevelOff,
			withCookie: true,
			wantAbsent: []string{"DEBUG", "INFO ", "WARN "},
		},
		{
			name:       "off logs nothing without the cookie either",
			level:      LogLevelOff,
			wantAbsent: []string{"DEBUG", "INFO ", "WARN "},
		},
		{
			name:       "warn logs the missing cookie",
			level:      LogLevelWarn,
			want:       []string{`WARN  no "test_access_token" cookie in the request`},
			wantAbsent: []string{"DEBUG", "INFO "},
		},
		{
			name:       "warn does not log an extracted cookie",
			level:      LogLevelWarn,
			withCookie: true,
			wantAbsent: []string{"DEBUG", "INFO ", "WARN "},
		},
		{
			name:       "info logs the extracted cookie",
			level:      LogLevelInfo,
			withCookie: true,
			want:       []string{"INFO  set the Authorization header from the \"test_access_token\" cookie"},
			wantAbsent: []string{"DEBUG", "WARN "},
		},
		{
			name:       "debug logs the extraction and the detail",
			level:      LogLevelDebug,
			withCookie: true,
			want: []string{
				"DEBUG serving GET /",
				"INFO  set the Authorization header",
			},
			wantAbsent: []string{"WARN "},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			cfg := testConfig()
			cfg.LogLevel = test.level

			handler, _ := newMiddleware(t, cfg)
			stdout := captureStdout(t)

			if test.withCookie {
				send(handler, &minCookie)
			} else {
				send(handler)
			}

			out := stdout()
			for _, want := range test.want {
				assert.Contains(t, out, want)
			}

			for _, unwanted := range test.wantAbsent {
				assert.NotContains(t, out, unwanted)
			}
		})
	}
}

// TestLogLevelDoesNotLeakBetweenInstances checks that a verbose middleware does
// not turn on the logs of the other middleware instances.
func TestLogLevelDoesNotLeakBetweenInstances(t *testing.T) {
	verboseCfg := testConfig()
	verboseCfg.LogLevel = LogLevelDebug
	quietCfg := testConfig()
	quietCfg.LogLevel = LogLevelInfo

	verbose, _ := newMiddleware(t, verboseCfg)
	verboseOut := captureStdout(t)

	send(verbose, &minCookie)
	assert.Contains(t, verboseOut(), "DEBUG serving GET /")

	quiet, _ := newMiddleware(t, quietCfg)
	quietOut := captureStdout(t)

	send(quiet, &minCookie)
	out := quietOut()
	assert.Contains(t, out, "INFO  set the Authorization header")
	assert.NotContains(t, out, "DEBUG", "the quiet middleware must not log the debug messages")
}

// TestTheCookieValueIsNeverLogged keeps a credential out of the Traefik log.
func TestTheCookieValueIsNeverLogged(t *testing.T) {
	cfg := testConfig()
	cfg.LogLevel = LogLevelDebug

	handler, _ := newMiddleware(t, cfg)
	stdout := captureStdout(t)

	send(handler, &minCookie)

	assert.NotContains(t, stdout(), testCookieValue)
}

// TestNothingIsWrittenToTheErrorLevel checks that the informational messages are
// not reported at the Traefik error level: the configuration errors are returned
// to Traefik, which reports them itself.
func TestNothingIsWrittenToTheErrorLevel(t *testing.T) {
	cfg := testConfig()
	cfg.LogLevel = LogLevelDebug

	handler, _ := newMiddleware(t, cfg)
	stderr := captureStderr(t)

	send(handler, &minCookie)
	send(handler)

	assert.Empty(t, stderr())
}

// testConfig is a valid configuration with a small log level.
func testConfig() *Config {
	cfg := CreateConfig()
	cfg.CookieName = testCookieName

	return cfg
}

// decodeConfig decodes a raw configuration like the Traefik plugin loader does.
func decodeConfig(t *testing.T, raw map[string]interface{}) *Config {
	t.Helper()

	cfg := CreateConfig()

	decoder, err := mapstructure.NewDecoder(&mapstructure.DecoderConfig{
		DecodeHook:       mapstructure.StringToSliceHookFunc(","),
		WeaklyTypedInput: true,
		Result:           cfg,
	})
	require.NoError(t, err)
	require.NoError(t, decoder.Decode(raw))

	return cfg
}

// newMiddleware creates the middleware under test, with a backend recording the
// headers it receives.
func newMiddleware(t *testing.T, cfg *Config) (http.Handler, *http.Header) {
	t.Helper()

	seen := &http.Header{}

	handler, err := New(context.Background(), nextHandler(seen), cfg, "test-middleware")
	require.NoError(t, err)

	return handler, seen
}

// nextHandler returns the backend, recording the headers of the requests it sees.
func nextHandler(seen *http.Header) http.Handler {
	return http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		*seen = req.Header.Clone()
		rw.WriteHeader(http.StatusOK)
	})
}

// send drives one request carrying the given cookies through the middleware.
func send(handler http.Handler, cookies ...*http.Cookie) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodGet, "http://localhost/", nil)
	for _, cookie := range cookies {
		req.AddCookie(cookie)
	}

	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	return rec
}

// TestCookieFieldExtraction covers the field of a JSON cookie value, including
// the percent-encoded form clients really send (a raw JSON cookie is dropped by
// Go's HTTP server before the plugin sees it).
func TestCookieFieldExtraction(t *testing.T) {
	tests := []struct {
		name   string
		cookie string
		field  string
		prefix string
		want   string
	}{
		{
			name:   "percent-encoded JSON, top level field",
			cookie: "session=%7B%22tenant%22%3A%22acme%22%7D",
			field:  "tenant", prefix: testValuePrefix, want: "Bearer acme",
		},
		{
			// A raw JSON cookie is dropped by Go's HTTP server (the quotes are not
			// valid in a cookie value): a client can never send it and the plugin
			// only sees the percent-encoded form. jsonField has direct unit tests.
			name:   "raw JSON is dropped by the cookie parser",
			cookie: `session={"tenant":"acme"}`,
			field:  "tenant", prefix: testValuePrefix, want: "",
		},
		{
			// A payload that is both valid JSON and a valid cookie value exercises
			// the raw form of the field extraction.
			name:   "a JSON array is read without decoding",
			cookie: "session=[1,2]",
			field:  "0", prefix: testValuePrefix, want: "Bearer 1",
		},
		{
			name:   "nested field",
			cookie: "session=%7B%22user%22%3A%7B%22id%22%3A%22u1%22%7D%7D",
			field:  "user.id", prefix: testValuePrefix, want: "Bearer u1",
		},
		{
			name:   "array element, bracket form",
			cookie: "session=%7B%22items%22%3A%5B%7B%22id%22%3A%22x%22%7D%5D%7D",
			field:  "items[0].id", prefix: testValuePrefix, want: "Bearer x",
		},
		{
			name:   "a number keeps the exact text of the payload",
			cookie: "session=%7B%22sub%22%3A12345678901234567890%7D",
			field:  "sub", prefix: testValuePrefix, want: "Bearer 12345678901234567890",
		},
		{
			name:   "an empty prefix writes the raw field",
			cookie: "session=%7B%22t%22%3A%22tok%22%7D",
			field:  "t", prefix: "", want: "tok",
		},
		{
			name:   "a missing field leaves the header untouched (policy keep)",
			cookie: "session=%7B%22other%22%3A%22x%22%7D",
			field:  "tenant", prefix: testValuePrefix, want: "",
		},
		{
			name:   "a payload that is not JSON",
			cookie: "session=plain-token",
			field:  "tenant", prefix: testValuePrefix, want: "",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			cfg := testConfig()
			cfg.CookieName = "session"
			cfg.CookieField = test.field
			cfg.CookieValuePrefix = test.prefix

			handler, seen := newMiddleware(t, cfg)
			rec := sendHeader(handler, test.cookie)

			require.Equal(t, http.StatusOK, rec.Code)
			assert.Equal(t, test.want, (*seen).Get(testHeaderName))
		})
	}
}

// TestMissingCookiePolicies covers the three policies on the cases that carry no
// value: no cookie at all and an empty cookie value.
func TestMissingCookiePolicies(t *testing.T) {
	tests := []struct {
		name       string
		policy     string
		cookie     string
		wantCode   int
		wantHeader string
	}{
		{name: "keep, no cookie: the client header survives", policy: MissingCookieKeep, wantCode: http.StatusOK, wantHeader: "Bearer client"},
		{name: "strip, no cookie: the client header is removed", policy: MissingCookieStrip, wantCode: http.StatusOK, wantHeader: ""},
		{name: "deny, no cookie: 401", policy: MissingCookieDeny, wantCode: http.StatusUnauthorized, wantHeader: ""},
		{name: "keep, empty value: the client header survives", policy: MissingCookieKeep, cookie: testCookieName + "=", wantCode: http.StatusOK, wantHeader: "Bearer client"},
		{name: "strip, empty value: the client header is removed", policy: MissingCookieStrip, cookie: testCookieName + "=", wantCode: http.StatusOK, wantHeader: ""},
		{name: "deny, empty value: 401", policy: MissingCookieDeny, cookie: testCookieName + "=", wantCode: http.StatusUnauthorized, wantHeader: ""},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			captureStdout(t)

			cfg := testConfig()
			cfg.MissingCookiePolicy = test.policy

			handler, seen := newMiddleware(t, cfg)

			req := httptest.NewRequest(http.MethodGet, "http://localhost/", nil)
			req.Header.Set(testHeaderName, "Bearer client")
			if test.cookie != "" {
				req.Header.Set("Cookie", test.cookie)
			}

			rec := httptest.NewRecorder()
			handler.ServeHTTP(rec, req)

			require.Equal(t, test.wantCode, rec.Code)
			assert.Equal(t, test.wantHeader, (*seen).Get(testHeaderName))
		})
	}
}

// TestControlCharactersAreRefused checks that a field decoded from a JSON payload
// (which can legitimately contain an escaped newline) never reaches the header.
func TestControlCharactersAreRefused(t *testing.T) {
	captureStdout(t)

	cfg := testConfig()
	cfg.CookieName = "session"
	cfg.CookieField = "t"
	cfg.MissingCookiePolicy = MissingCookieStrip

	handler, seen := newMiddleware(t, cfg)

	// The percent-encoded form of a payload whose field carries an escaped
	// newline: the escape decodes to a real newline, which must never reach a
	// header.
	rec := sendHeader(handler, "session=%7B%22t%22%3A%22a%5Cnb%22%7D")

	require.Equal(t, http.StatusOK, rec.Code)
	assert.Empty(t, (*seen).Get(testHeaderName), "a value with a control character must not be written")
}

// sendHeader drives a request whose Cookie header is set verbatim: the raw form
// is needed for a JSON payload and for the invalid values (AddCookie would
// sanitize the value).
func sendHeader(handler http.Handler, cookie string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodGet, "http://localhost/", nil)
	if cookie != "" {
		req.Header.Set("Cookie", cookie)
	}

	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	return rec
}
