// Command yaegicheck loads the plugin with the Yaegi interpreter and the symbol
// table used by Traefik, then drives a few requests through the middleware.
//
// It is a regression guard for interpreter incompatibilities: Yaegi versions pin
// down what the plugin sources may contain (see the README), and a construct
// accepted by the Go compiler can crash the interpreter, or lose information
// across the host/interpreted boundary, while Traefik loads the plugin. Run it
// before every release:
//
//	make yaegi-check
//
// The check is self-contained: it needs neither Traefik nor a network.
package main

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"

	"github.com/traefik/yaegi/interp"
	"github.com/traefik/yaegi/stdlib"
)

const pluginImport = "github.com/MichNG/traefik-cookie-extract"

const (
	cookieName  = "access_token"
	cookieValue = "secret-token"
)

func main() {
	root, err := repoRoot()
	if err != nil {
		fail("locating the repository root: %v", err)
	}

	gopath, err := os.MkdirTemp("", "yaegicheck-gopath")
	if err != nil {
		fail("creating the temporary GOPATH: %v", err)
	}
	defer func() { _ = os.RemoveAll(gopath) }()

	if err := copyTree(root, filepath.Join(gopath, "src", pluginImport)); err != nil {
		fail("copying the plugin sources: %v", err)
	}

	var stdout, stderr bytes.Buffer

	i := newInterpreter(gopath, io.MultiWriter(os.Stdout, &stdout), io.MultiWriter(os.Stderr, &stderr))

	checkConfigurationErrors(i)
	checkExtraction(i, &stdout)
	checkMissingCookie(i, &stdout, &stderr)
	checkCookieFieldAndPolicies(i, &stdout)

	fmt.Println("OK: the plugin compiles and behaves correctly under yaegi")
}

// newInterpreter loads the plugin package with the same interpreter options
// Traefik uses. The given stdout/stderr receive the plugin log lines.
func newInterpreter(gopath string, stdout, stderr io.Writer) *interp.Interpreter {
	i := interp.New(interp.Options{GoPath: gopath, Env: os.Environ(), Stdout: stdout, Stderr: stderr})
	if err := i.Use(stdlib.Symbols); err != nil {
		fail("loading the stdlib symbols: %v", err)
	}

	fmt.Println("=== compiling the plugin with yaegi ===")
	if _, err := i.Eval(fmt.Sprintf("import %q", pluginImport)); err != nil {
		fail("the plugin does not compile under yaegi: %v", err)
	}

	return i
}

// checkConfigurationErrors makes sure that an invalid configuration is rejected
// with an error Traefik can report. This is not a formality: yaegi loses the
// error of a multi-value call forwarded from the exported New, so the plugin
// must build its results explicitly (otherwise Traefik only sees a nil handler
// and reports "invalid handler type: <nil>").
func checkConfigurationErrors(i *interp.Interpreter) {
	fmt.Println("=== configuration errors must reach the caller with their message ===")

	newFn, err := i.Eval("traefik_cookie_extract.New")
	if err != nil {
		fail("looking up New: %v", err)
	}

	cases := []struct {
		name   string
		mutate func(value reflect.Value)
		want   string
	}{
		{
			name:   "missing cookieName",
			mutate: func(value reflect.Value) {},
			want:   "cookieName is required",
		},
		{
			name: "unmatchable cookieName",
			mutate: func(value reflect.Value) {
				value.FieldByName("CookieName").SetString("bad name")
			},
			want: "invalid cookieName",
		},
		{
			name: "unsupported logLevel",
			mutate: func(value reflect.Value) {
				value.FieldByName("CookieName").SetString(cookieName)
				value.FieldByName("LogLevel").SetString("verbose")
			},
			want: "unsupported logLevel",
		},
	}

	next := http.HandlerFunc(func(rw http.ResponseWriter, _ *http.Request) { rw.WriteHeader(http.StatusOK) })

	for _, tc := range cases {
		cfg, err := i.Eval("traefik_cookie_extract.CreateConfig()")
		if err != nil {
			fail("CreateConfig: %v", err)
		}

		tc.mutate(cfg.Elem())

		results := newFn.Call([]reflect.Value{
			reflect.ValueOf(context.Background()),
			reflect.ValueOf(next),
			cfg,
			reflect.ValueOf("yaegicheck-error"),
		})

		if len(results) < 2 || results[1].IsNil() {
			fail("%s: New returned no error (handler nil: %v): Traefik would report a nil handler", tc.name, results[0].IsNil())
		}

		message := fmt.Sprintf("%v", results[1].Interface())
		if !strings.Contains(message, tc.want) {
			fail("%s: error = %q, want it to contain %q", tc.name, message, tc.want)
		}

		fmt.Printf("%-24s -> error surfaced: %s\n", tc.name, message)
	}

	fmt.Println("OK: configuration errors reach the caller with their message")
}

// checkExtraction drives the cookie -> header translation under the interpreter,
// and checks that the messages land on the interpreter stdout (Traefik debug
// level), without the cookie value.
func checkExtraction(i *interp.Interpreter, stdout *bytes.Buffer) {
	fmt.Println("=== cookie -> header translation ===")

	stdout.Reset()

	var seen http.Header

	handler := runMiddleware(i, "yaegicheck-extract", func(value reflect.Value) {
		value.FieldByName("CookieName").SetString(cookieName)
		value.FieldByName("HeaderNameForCookieValue").SetString("Authorization")
		value.FieldByName("CookieValuePrefix").SetString("Bearer ")
		value.FieldByName("LogLevel").SetString("debug")
	}, &seen)

	req := httptest.NewRequest(http.MethodGet, "http://localhost/", nil)
	req.AddCookie(&http.Cookie{Name: cookieName, Value: cookieValue})

	rec := httptest.NewRecorder()
	callHandler(handler, rec, req)

	if rec.Code != http.StatusOK {
		fail("status = %d, want 200", rec.Code)
	}

	if got, want := seen.Get("Authorization"), "Bearer "+cookieValue; got != want {
		fail("the backend received Authorization=%q, want %q", got, want)
	}

	logs := stdout.String()
	if !strings.Contains(logs, `INFO  set the Authorization header from the "access_token" cookie`) {
		fail("the extraction is not reported on the interpreter stdout: %q", flat(logs))
	}

	if strings.Contains(logs, cookieValue) {
		fail("the cookie value must never be logged: %q", flat(logs))
	}

	fmt.Println("OK: the cookie value is translated into the header, and reported in the Traefik log")
}

// checkMissingCookie checks the behaviour this plugin was rewritten for: a
// request without the cookie must not be warned about on every occurrence, and
// the throttling (sync.Mutex) and the single warning (sync.Once) must work inside
// the interpreter.
func checkMissingCookie(i *interp.Interpreter, stdout, stderr *bytes.Buffer) {
	fmt.Println("=== a request without the cookie must not flood the logs ===")

	stdout.Reset()
	stderr.Reset()

	var seen http.Header

	handler := runMiddleware(i, "yaegicheck-missing", func(value reflect.Value) {
		value.FieldByName("CookieName").SetString(cookieName)
		value.FieldByName("LogLevel").SetString("debug")
	}, &seen)

	const requests = 10

	for n := 0; n < requests; n++ {
		req := httptest.NewRequest(http.MethodGet, "http://localhost/", nil)

		rec := httptest.NewRecorder()
		callHandler(handler, rec, req)

		if rec.Code != http.StatusOK {
			fail("request %d: status = %d, want 200", n, rec.Code)
		}
	}

	if got := seen.Get("Authorization"); got != "" {
		fail("the header must not be set without the cookie, got %q", got)
	}

	logs := stdout.String()
	if got, want := strings.Count(logs, `WARN  no "access_token" cookie in the request`), 1; got != want {
		fail("%d requests without the cookie produced %d warnings, want %d: %q", requests, got, want, flat(logs))
	}

	if got, want := strings.Count(logs, `DEBUG no "access_token" cookie in the request`), 1; got != want {
		fail("%d requests without the cookie produced %d debug lines, want %d (throttling)", requests, got, want)
	}

	if stderr.Len() != 0 {
		fail("the plugin must not report an informational message at the error level: %q", flat(stderr.String()))
	}

	fmt.Printf("%d requests without the cookie -> 1 warning, 1 throttled debug line\n", requests)
	fmt.Println("OK: the missing cookie does not flood the logs")
}

// checkCookieFieldAndPolicies exercises the JSON field extraction and the
// missing cookie policies under yaegi: encoding/json and net/url are called from
// interpreted code here, the strip policy must remove a client-supplied header,
// and the deny policy must answer 401.
func checkCookieFieldAndPolicies(i *interp.Interpreter, stdout *bytes.Buffer) {
	fmt.Println("=== a JSON cookie field, and the missing cookie policies ===")
	stdout.Reset()

	var seen http.Header

	handler := runMiddleware(i, "yaegicheck-field", func(value reflect.Value) {
		value.FieldByName("CookieName").SetString("session")
		value.FieldByName("CookieField").SetString("user.id")
		value.FieldByName("HeaderNameForCookieValue").SetString("X-Tenant")
		value.FieldByName("CookieValuePrefix").SetString("")
		value.FieldByName("LogLevel").SetString("debug")
	}, &seen)

	req := httptest.NewRequest(http.MethodGet, "http://localhost/", nil)
	req.Header.Set("Cookie", "session=%7B%22user%22%3A%7B%22id%22%3A%22acme%22%7D%7D")

	rec := httptest.NewRecorder()
	callHandler(handler, rec, req)

	if rec.Code != http.StatusOK {
		fail("cookieField: status = %d, want 200", rec.Code)
	}

	if got, want := seen.Get("X-Tenant"), "acme"; got != want {
		fail("cookieField: the header is %q, want %q", got, want)
	}

	fmt.Println("  cookieField: the percent-encoded JSON field reached the header")

	// strip: a client-supplied header of the same name must not survive.
	seen = http.Header{}

	handler = runMiddleware(i, "yaegicheck-strip", func(value reflect.Value) {
		value.FieldByName("CookieName").SetString(cookieName)
		value.FieldByName("MissingCookiePolicy").SetString("strip")
		value.FieldByName("LogLevel").SetString("off")
	}, &seen)

	req = httptest.NewRequest(http.MethodGet, "http://localhost/", nil)
	req.Header.Set("Authorization", "Bearer client")

	rec = httptest.NewRecorder()
	callHandler(handler, rec, req)

	if got := seen.Get("Authorization"); got != "" {
		fail("strip: the client header %q reached the backend", got)
	}

	fmt.Println("  strip: the client-supplied header was removed")

	// deny: 401 before the backend.
	seen = http.Header{}

	handler = runMiddleware(i, "yaegicheck-deny", func(value reflect.Value) {
		value.FieldByName("CookieName").SetString(cookieName)
		value.FieldByName("MissingCookiePolicy").SetString("deny")
		value.FieldByName("LogLevel").SetString("off")
	}, &seen)

	req = httptest.NewRequest(http.MethodGet, "http://localhost/", nil)

	rec = httptest.NewRecorder()
	callHandler(handler, rec, req)

	if rec.Code != http.StatusUnauthorized {
		fail("deny: status = %d, want 401", rec.Code)
	}

	if got := seen.Get("Authorization"); got != "" {
		fail("deny: the request reached the backend (header %q)", got)
	}

	fmt.Println("  deny: 401 without reaching the backend")
	fmt.Println("OK: the JSON cookie field and the missing cookie policies behave correctly under yaegi")
}

// runMiddleware creates the middleware under test with the given configuration,
// and returns the interpreted handler.
func runMiddleware(i *interp.Interpreter, name string, configure func(value reflect.Value), seen *http.Header) reflect.Value {
	newFn, err := i.Eval("traefik_cookie_extract.New")
	if err != nil {
		fail("looking up New: %v", err)
	}

	cfg, err := i.Eval("traefik_cookie_extract.CreateConfig()")
	if err != nil {
		fail("CreateConfig: %v", err)
	}

	configure(cfg.Elem())

	next := http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		*seen = req.Header.Clone()
		rw.WriteHeader(http.StatusOK)
	})

	results := newFn.Call([]reflect.Value{
		reflect.ValueOf(context.Background()),
		reflect.ValueOf(next),
		cfg,
		reflect.ValueOf(name),
	})

	if len(results) < 1 || results[0].IsNil() {
		fail("%s: New returned no handler (error: %v)", name, results[1].Interface())
	}

	return results[0]
}

func callHandler(handler reflect.Value, rec *httptest.ResponseRecorder, req *http.Request) {
	defer func() {
		if r := recover(); r != nil {
			fail("ServeHTTP panicked: %v", r)
		}
	}()

	handler.MethodByName("ServeHTTP").Call([]reflect.Value{reflect.ValueOf(rec), reflect.ValueOf(req)})
}

// repoRoot walks up from the working directory until the plugin manifest is found.
func repoRoot() (string, error) {
	dir, err := os.Getwd()
	if err != nil {
		return "", err
	}

	for {
		if _, err := os.Stat(filepath.Join(dir, ".traefik.yml")); err == nil {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", fmt.Errorf("no .traefik.yml found above the working directory")
		}
		dir = parent
	}
}

// copyTree copies the plugin sources, leaving out the directories that are not
// part of the module the interpreter compiles.
func copyTree(src, dst string) error {
	return filepath.Walk(src, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		if info.IsDir() {
			switch info.Name() {
			case ".git", ".gocache", ".gomodcache", ".gopath", ".gotmp", ".e2e", "example", "tools", "docs":
				return filepath.SkipDir
			}
			return os.MkdirAll(filepath.Join(dst, rel), 0o755)
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		return os.WriteFile(filepath.Join(dst, rel), data, 0o644)
	})
}

// flat renders captured logs on a single line, for the failure messages.
func flat(logs string) string {
	return strings.ReplaceAll(strings.TrimSpace(logs), "\n", " | ")
}

func fail(format string, args ...interface{}) {
	fmt.Printf("FAILED: "+format+"\n", args...)
	os.Exit(1)
}
