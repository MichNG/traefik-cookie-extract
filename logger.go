package traefik_cookie_extract

// Plugin logging.
//
// A Yaegi plugin cannot use the Traefik logger directly. Traefik configures the
// interpreter with interp.Options{Stdout: logs.NoLevel(..., DebugLevel),
// Stderr: logs.NoLevel(..., ErrorLevel)}: writes to the interpreted os.Stdout
// land in the Traefik log at debug level, writes to the interpreted os.Stderr at
// error level. Verified against Traefik 3.8.0:
//
//	fmt.Println(...)  -> plugin logger, DBG
//	log.Println(...)  -> plugin logger, ERR   (the std logger writes to stderr)
//
// The plugin messages are informational, so they are written to stdout: they
// appear in the Traefik log with the plugin fields (module, plugin, runtime) at
// debug level, i.e. `log.level: DEBUG` shows them. Writing to an explicit
// *os.File instead (log.New(os.Stdout, ...)) bypasses the redirection entirely:
// the output goes to the process stdout/stderr, ignoring the Traefik log level,
// format and log.filePath, and lands in the system logs (journald,
// /var/log/messages on systemd hosts).
//
// Messages are throttled per template, so that a busy service does not flood the
// Traefik log with the detail of the requests that do not carry the cookie.

import (
	"fmt"
	"strings"
	"sync"
	"time"
)

// logThrottleInterval is the minimum delay between two identical messages.
const logThrottleInterval = 5 * time.Second

// Values accepted by the logLevel configuration option.
const (
	// LogLevelOff disables all the logs of the plugin.
	LogLevelOff = "off"
	// LogLevelWarn logs the warnings and the higher levels.
	LogLevelWarn = "warn"
	// LogLevelInfo logs the information and the higher levels, it is the default.
	LogLevelInfo = "info"
	// LogLevelDebug logs everything.
	LogLevelDebug = "debug"
)

// logLevel is the verbosity of the plugin logger, ordered from the quietest to
// the noisiest one.
type logLevel int

const (
	levelOff logLevel = iota
	levelWarn
	levelInfo
	levelDebug
)

// parseLogLevel maps the logLevel configuration value to a logLevel. An empty
// value is accepted and means the default (info).
func parseLogLevel(value string) (logLevel, error) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "", LogLevelInfo:
		return levelInfo, nil
	case LogLevelOff:
		return levelOff, nil
	case LogLevelWarn:
		return levelWarn, nil
	case LogLevelDebug:
		return levelDebug, nil
	default:
		return levelOff, fmt.Errorf("unsupported logLevel %q, expected one of: %s, %s, %s, %s",
			value, LogLevelOff, LogLevelWarn, LogLevelInfo, LogLevelDebug)
	}
}

// pluginLogger is the levelled logger of the plugin. Unlike a package level
// logger, it is bound to a single middleware instance, so the logLevel of a
// middleware never leaks to the other instances.
type pluginLogger struct {
	prefix string
	level  logLevel

	mu     sync.Mutex
	lastAt map[string]time.Time
}

// newPluginLogger creates the logger of a middleware instance.
func newPluginLogger(name string, level logLevel) *pluginLogger {
	return &pluginLogger{
		prefix: fmt.Sprintf("[cookie-extract %s] ", name),
		level:  level,
		lastAt: make(map[string]time.Time),
	}
}

// debugf logs a request detail.
func (l *pluginLogger) debugf(format string, args ...interface{}) {
	l.write(levelDebug, "DEBUG", format, args...)
}

// infof logs an extracted cookie.
func (l *pluginLogger) infof(format string, args ...interface{}) {
	l.write(levelInfo, "INFO ", format, args...)
}

// warnf logs a warning.
func (l *pluginLogger) warnf(format string, args ...interface{}) {
	l.write(levelWarn, "WARN ", format, args...)
}

// write reports a message through the interpreter stdout (Traefik debug level),
// unless the level is disabled or the same message was reported less than
// logThrottleInterval ago.
func (l *pluginLogger) write(level logLevel, tag, format string, args ...interface{}) {
	if l == nil || l.level < level {
		return
	}

	if !l.shouldLog(tag + format) {
		return
	}

	fmt.Println(l.prefix + tag + " " + fmt.Sprintf(format, args...))
}

// shouldLog implements the per-template throttling: the first occurrence of a
// message is reported, the next ones are dropped during logThrottleInterval.
func (l *pluginLogger) shouldLog(key string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()

	if last, ok := l.lastAt[key]; ok && time.Since(last) < logThrottleInterval {
		return false
	}

	l.lastAt[key] = time.Now()

	return true
}
