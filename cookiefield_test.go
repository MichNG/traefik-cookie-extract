package traefik_cookie_extract

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestJSONField(t *testing.T) {
	escapedNewline := `{"t":"a` + `\` + `nb"}`

	tests := []struct {
		name    string
		payload string
		field   string
		want    string
		ok      bool
	}{
		{name: "top level string", payload: `{"tenant":"acme"}`, field: "tenant", want: "acme", ok: true},
		{name: "nested string", payload: `{"user":{"id":"u1"}}`, field: "user.id", want: "u1", ok: true},
		{name: "array index, dot form", payload: `{"users":[{"id":"a"},{"id":"b"}]}`, field: "users.1.id", want: "b", ok: true},
		{name: "array index, bracket form", payload: `{"items":[{"id":"x"}]}`, field: "items[0].id", want: "x", ok: true},
		{name: "nested arrays", payload: `{"a":[[1,2],[3]]}`, field: "a[1][0]", want: "3", ok: true},
		{name: "number keeps its text", payload: `{"id":12345678901234567890}`, field: "id", want: "12345678901234567890", ok: true},
		{name: "boolean", payload: `{"beta":true}`, field: "beta", want: "true", ok: true},
		{name: "empty string is a value", payload: `{"t":""}`, field: "t", want: "", ok: true},
		{name: "escaped newline is decoded", payload: escapedNewline, field: "t", want: "a" + "\n" + "b", ok: true},
		{name: "missing field", payload: `{"tenant":"acme"}`, field: "sub", ok: false},
		{name: "null value", payload: `{"t":null}`, field: "t", ok: false},
		{name: "object value", payload: `{"t":{"a":1}}`, field: "t", ok: false},
		{name: "array value", payload: `{"t":[1]}`, field: "t", ok: false},
		{name: "index out of range", payload: `{"users":[1]}`, field: "users.3", ok: false},
		{name: "index on an object", payload: `{"users":{"id":"a"}}`, field: "users.0.id", ok: false},
		{name: "not JSON", payload: `plain-token`, field: "t", ok: false},
		{name: "trailing garbage", payload: `{"t":"a"} garbage`, field: "t", ok: false},
		{name: "trailing second document", payload: `{"t":"a"}{"t":"b"}`, field: "t", ok: false},
		{name: "empty field path", payload: `{"t":"a"}`, field: "", ok: false},
		{name: "empty path element", payload: `{"t":"a"}`, field: "t..a", ok: false},
		{name: "empty payload", payload: ``, field: "t", ok: false},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, ok := jsonField(test.payload, test.field)

			assert.Equal(t, test.ok, ok)
			assert.Equal(t, test.want, got)
		})
	}
}

func TestNormalizeFieldPath(t *testing.T) {
	assert.Equal(t, "items.0.id", normalizeFieldPath("items[0].id"))
	assert.Equal(t, "a.1.0", normalizeFieldPath("a[1][0]"))
	assert.Equal(t, "user.id", normalizeFieldPath("user.id"))
}

func TestValidateFieldPath(t *testing.T) {
	valid := []string{"tenant", "user.id", "users.0.id", "items[0].id", "a[1][0]", "a-b_c"}
	for _, field := range valid {
		t.Run("valid "+field, func(t *testing.T) {
			require.NoError(t, validateFieldPath("cookieField", field))
		})
	}

	invalid := []string{"", "bad field", "a\tb", "items[0", "items]0[", "items[]", "items[x]", "user..id", ".user"}
	for _, field := range invalid {
		t.Run("invalid "+field, func(t *testing.T) {
			require.Error(t, validateFieldPath("cookieField", field))
		})
	}
}

func TestHasControlChars(t *testing.T) {
	assert.False(t, hasControlChars("Bearer abc-123"))
	assert.False(t, hasControlChars(""))
	assert.True(t, hasControlChars("a"+"\n"+"b"))
	assert.True(t, hasControlChars("a"+"\r"+"b"))
	assert.True(t, hasControlChars("a"+"\x00"+"b"))
	assert.True(t, hasControlChars("a"+"\x7f"+"b"))
}
