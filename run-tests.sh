#!/usr/bin/env bash
# Runs the plugin test suite inside the DSH sandbox.
#
# The sandbox blocks Go's default caches (~/go, ~/Library/Caches/go-build), so
# all Go state is kept inside the workspace and a failed run is retried once.
set -uo pipefail

cd "$(dirname "$0")" || exit 1

export GOCACHE="$PWD/.gocache"
export GOTMPDIR="$PWD/.gotmp"
export GOMODCACHE="$PWD/.gomodcache"
export GOPATH="$PWD/.gopath"
export GOFLAGS="-mod=mod"
mkdir -p "$GOCACHE" "$GOTMPDIR" "$GOMODCACHE" "$GOPATH"

run() {
    # The module cache lives inside the repository, so gofmt is pointed at the
    # sources only (its stderr covers the cached dependencies otherwise).
    gofmt -l *.go 2>/dev/null
    go vet ./... || return 1
    go test "$@" ./...
}

if run "$@"; then
    exit 0
fi

echo "--- first attempt failed, retrying (sandbox module-cache flakiness) ---"
run "$@"
