package traefik_cookie_extract

import (
	"bytes"
	"io"
	"log"
	"os"
	"strings"
	"testing"
)

// The plugin logs through the channel Traefik redirects into its own logger: the
// interpreted os.Stdout (debug level in Traefik). The interpreted os.Stderr
// (error level) is never used: the configuration errors are returned to Traefik,
// which reports them itself.
func TestLoggerLevels(t *testing.T) {
	stdout := captureStdout(t)
	stderr := captureStderr(t)

	logger := newPluginLogger("my-middleware", levelDebug)

	logger.debugf("serving GET /")
	logger.infof("set the Authorization header from the %q cookie", "access_token")
	logger.warnf("no %q cookie in the request", "access_token")

	got := stdout()
	for _, want := range []string{
		`[cookie-extract my-middleware] DEBUG serving GET /`,
		`[cookie-extract my-middleware] INFO  set the Authorization header from the "access_token" cookie`,
		`[cookie-extract my-middleware] WARN  no "access_token" cookie in the request`,
	} {
		if !strings.Contains(got, want) {
			t.Errorf("message %q not found on stdout (Traefik debug level): %q", want, got)
		}
	}

	if errorsOut := stderr(); errorsOut != "" {
		t.Errorf("the plugin must not write to the error level: %q", errorsOut)
	}
}

func TestLoggerFiltersTheLevels(t *testing.T) {
	tests := []struct {
		name  string
		level logLevel
		want  []string
	}{
		{name: "off logs nothing", level: levelOff},
		{name: "warn logs the warnings only", level: levelWarn, want: []string{"WARN  warn message"}},
		{
			name:  "info logs the warnings and the information",
			level: levelInfo,
			want:  []string{"WARN  warn message", "INFO  info message"},
		},
		{
			name:  "debug logs everything",
			level: levelDebug,
			want:  []string{"WARN  warn message", "INFO  info message", "DEBUG debug message"},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			stdout := captureStdout(t)

			logger := newPluginLogger("my-middleware", test.level)
			logger.warnf("warn message")
			logger.infof("info message")
			logger.debugf("debug message")

			if got, want := lines(stdout()), test.want; !equalLines(got, want) {
				t.Errorf("expected the logs %v, got %v", want, got)
			}
		})
	}
}

// Identical messages are throttled, so that a service whose requests do not carry
// the cookie does not flood the Traefik log.
func TestLoggerThrottlesIdenticalMessages(t *testing.T) {
	stdout := captureStdout(t)

	logger := newPluginLogger("my-middleware", levelDebug)

	for i := 0; i < 5; i++ {
		logger.debugf("no %q cookie in the request", "access_token")
	}

	logger.debugf("serving GET /")

	out := stdout()
	if got, want := len(lines(out)), 2; got != want {
		t.Fatalf("expected %d lines (one per template), got %d: %q", want, got, out)
	}
}

func TestLoggerIsNilSafe(t *testing.T) {
	var logger *pluginLogger

	logger.debugf("no panic")
	logger.infof("no panic")
	logger.warnf("no panic")
}

func parseLines(out string) []string {
	var parsed []string

	for _, line := range strings.Split(strings.TrimSuffix(out, "\n"), "\n") {
		if line != "" {
			parsed = append(parsed, line)
		}
	}

	return parsed
}

// lines returns the messages of the captured output, without the logger prefix.
func lines(out string) []string {
	var messages []string

	for _, line := range parseLines(out) {
		if idx := strings.Index(line, "] "); idx >= 0 {
			messages = append(messages, line[idx+2:])
		}
	}

	return messages
}

func equalLines(got, want []string) bool {
	if len(got) != len(want) {
		return false
	}

	for i := range want {
		if got[i] != want[i] {
			return false
		}
	}

	return true
}

// captureStdout captures the interpreted os.Stdout, the channel the plugin logs
// to. It is read once, after the writes: the pipe buffer (64 KiB) is enough for
// the few short messages of these tests.
func captureStdout(t *testing.T) func() string {
	t.Helper()

	previous := os.Stdout

	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("creating the pipe: %v", err)
	}
	os.Stdout = w

	t.Cleanup(func() {
		os.Stdout = previous
		_ = r.Close()
	})

	return func() string {
		_ = w.Close()
		out, _ := io.ReadAll(r)

		return string(out)
	}
}

// captureStderr captures the interpreted os.Stderr, to check that the plugin
// never reports an informational message at the error level.
func captureStderr(t *testing.T) func() string {
	t.Helper()

	var buf bytes.Buffer

	previous := log.Writer()
	log.SetOutput(&buf)
	t.Cleanup(func() { log.SetOutput(previous) })

	return buf.String
}
