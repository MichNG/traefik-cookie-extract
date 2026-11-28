package traefik_cookie_extract

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// FuzzJSONField checks the invariants of the field extraction on arbitrary
// payloads and paths: it never panics, and it is deterministic.
func FuzzJSONField(f *testing.F) {
	escapedNewline := `{"t":"a` + `\` + `nb"}`

	seeds := []struct {
		payload string
		field   string
	}{
		{`{"tenant":"acme"}`, "tenant"},
		{`{"user":{"id":"u1"}}`, "user.id"},
		{`{"items":[{"id":"x"},{"id":"y"}]}`, "items[1].id"},
		{`{"a":[[1,2],[3]]}`, "a[1][0]"},
		{escapedNewline, "t"},
		{`{"t":12345678901234567890}`, "t"},
		{`["a","b"]`, "0"},
		{`null`, "t"},
		{`{"t":"a"} garbage`, "t"},
		{``, ""},
		{`{"t":"a"}`, "t..a"},
		{`{"t":"a"}`, "t[0]"},
		{`{"t":"a"}`, strings.Repeat("a.", 50) + "b"},
	}

	for _, seed := range seeds {
		f.Add(seed.payload, seed.field)
	}

	f.Fuzz(func(t *testing.T, payload, field string) {
		first, ok := jsonField(payload, field)
		second, okAgain := jsonField(payload, field)

		if ok != okAgain || first != second {
			t.Fatalf("jsonField is not deterministic for payload %q field %q", payload, field)
		}

		// A path with an empty element can never resolve.
		if strings.Contains(field, "..") && ok {
			t.Fatalf("a path with an empty element resolved: payload %q field %q -> %q", payload, field, first)
		}
	})
}

// FuzzCookieHeaderValue checks the security invariant of the middleware: a value
// that reaches the header never carries a control character (a CR or a LF would
// be a header injection), whatever the cookie value and the field path are.
func FuzzCookieHeaderValue(f *testing.F) {
	seeds := []struct {
		headerValue string
		field       string
	}{
		{`{"tenant":"acme"}`, "tenant"},
		{`%7B%22tenant%22%3A%22acme%22%7D`, "tenant"},
		{`%7B%22user%22%3A%7B%22id%22%3A%22u1%22%7D%7D`, "user.id"},
		{`{"t":"a` + `\` + `nb"}`, "t"},
		{`{"t":"a%0D%0AX-Evil:1"}`, "t"},
		{`{"t":"a%250Ab"}`, "t"},
		{`plain-token`, "t"},
		{``, ""},
		{`%zz`, "t"},
		{`{"t":["a"]}`, "t"},
	}

	for _, seed := range seeds {
		f.Add(seed.headerValue, seed.field)
	}

	f.Fuzz(func(t *testing.T, headerValue, field string) {
		cfg := CreateConfig()
		cfg.CookieName = "session"
		cfg.CookieField = field
		cfg.MissingCookiePolicy = MissingCookieKeep
		cfg.LogLevel = LogLevelOff

		ce, err := newCookieExtract(nil, nextHandler(&http.Header{}), cfg, "fuzz")
		if err != nil {
			// An invalid field path is a configuration error: nothing to check.
			return
		}

		req := httptest.NewRequest(http.MethodGet, "http://localhost/", nil)
		req.Header.Set("Cookie", "session="+headerValue)

		value, reason := ce.cookieHeaderValue(req)
		if reason != "" {
			return
		}

		if hasControlChars(value) {
			t.Fatalf("a control character reached the header value %q (cookie %q, field %q)", value, headerValue, field)
		}
	})
}
