package traefik_cookie_extract

// Field extraction from a JSON cookie value, and the hygiene of the value that
// ends up in the header.
//
// The field grammar and the percent-decoding fallback are adapted from the
// internal/utils package of the author's other plugin,
// github.com/MichNG/traefik-distributed-rate-limit: a JSON payload cannot be sent
// raw inside a cookie (the quotes are not valid in a cookie value, and Go drops
// such a cookie before the plugin sees the request), so clients percent-encode
// it, and the raw value is tried first, then the decoded one.

import (
	"encoding/json"
	"fmt"
	"io"
	"strconv"
	"strings"
)

// jsonField returns a field of a JSON payload as a header value. The field may
// be a dot path ("user.id"), address array elements by index ("users.0.id",
// "items[0].id", "a[0][1]"), or mix both. Scalars (string, number, boolean) are
// accepted, so that a numeric or boolean field can be used directly; numbers
// keep the exact text of the payload. ok is false when the payload is not a
// single JSON value, when a path element is missing, or when the value is null,
// an object or an array.
func jsonField(payload, field string) (string, bool) {
	decoder := json.NewDecoder(strings.NewReader(payload))
	decoder.UseNumber()

	var document interface{}
	if err := decoder.Decode(&document); err != nil {
		return "", false
	}

	// Reject trailing content: "{} garbage" is not a JSON payload.
	if err := decoder.Decode(new(interface{})); err != io.EOF {
		return "", false
	}

	parts := strings.Split(normalizeFieldPath(field), ".")

	current := document
	for _, part := range parts {
		if part == "" {
			return "", false
		}

		switch node := current.(type) {
		case map[string]interface{}:
			value, ok := node[part]
			if !ok {
				return "", false
			}
			current = value

		case []interface{}:
			index, err := strconv.Atoi(part)
			if err != nil || index < 0 || index >= len(node) {
				return "", false
			}
			current = node[index]

		default:
			// A scalar or null cannot be traversed any further.
			return "", false
		}
	}

	return scalarString(current)
}

// scalarString renders a JSON scalar as a header value. Numbers keep the exact
// text of the payload, which matters for identifiers that do not fit a float64
// (snowflake ids, for instance).
func scalarString(value interface{}) (string, bool) {
	switch scalar := value.(type) {
	case string:
		return scalar, true
	case json.Number:
		return scalar.String(), true
	case bool:
		return strconv.FormatBool(scalar), true
	default:
		// null, an object or an array: not a usable value on its own.
		return "", false
	}
}

// normalizeFieldPath turns the bracket form into the dot form, so that
// "items[0].id" and "items.0.id" are the same path. Index segments also resolve
// against objects, so a payload with numeric keys still works.
func normalizeFieldPath(field string) string {
	return strings.ReplaceAll(strings.ReplaceAll(field, "[", "."), "]", "")
}

// validateFieldPath rejects paths that can never resolve, so that a
// configuration typo fails at creation instead of silently producing no value.
// Both the dot form ("user.id", "users.0.id") and the bracket form
// ("items[0].id") are accepted.
func validateFieldPath(kind, field string) error {
	if strings.ContainsAny(field, " \t\r\n") {
		return fmt.Errorf("invalid %s %q: it must not contain spaces or control characters", kind, field)
	}

	for i := 0; i < len(field); i++ {
		switch field[i] {
		case '[':
			end := strings.IndexByte(field[i:], ']')
			if end < 0 {
				return fmt.Errorf("invalid %s %q: unbalanced array brackets", kind, field)
			}

			index := field[i+1 : i+end]
			if index == "" {
				return fmt.Errorf("invalid %s %q: empty array index", kind, field)
			}

			for j := 0; j < len(index); j++ {
				if index[j] < '0' || index[j] > '9' {
					return fmt.Errorf("invalid %s %q: array index %q is not a number", kind, field, index)
				}
			}

			i += end

		case ']':
			return fmt.Errorf("invalid %s %q: unbalanced array brackets", kind, field)
		}
	}

	for _, part := range strings.Split(normalizeFieldPath(field), ".") {
		if part == "" {
			return fmt.Errorf("invalid %s %q: empty path element", kind, field)
		}
	}

	return nil
}

// hasControlChars reports whether the value carries a byte that must never reach
// a header: a CR or a LF (header injection), a NUL, a DEL, or any other control
// character. The cookie parser already rejects them in a raw cookie value, but a
// field decoded from a JSON payload can legitimately contain an escaped newline.
func hasControlChars(value string) bool {
	for i := 0; i < len(value); i++ {
		if value[i] < 0x20 || value[i] == 0x7f {
			return true
		}
	}

	return false
}
