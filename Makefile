.PHONY: test test-race cover yaegi-check integration e2e

# Runs gofmt, go vet and the whole test suite. The Go caches are kept inside
# the repository so that the target also works in restricted environments.
test:
	@./run-tests.sh -count=1

test-race:
	@./run-tests.sh -race -count=1

cover:
	@./run-tests.sh -count=1 -covermode=atomic -coverprofile=coverage.txt
	@go tool cover -html=coverage.txt -o cover.html

# Loads the plugin with the same Yaegi interpreter as Traefik (v0.16.1) and
# drives a few requests through it. The Go caches of the tool are kept inside
# tools/yaegicheck, so that the target also works in restricted environments.
yaegi-check:
	@cd tools/yaegicheck && GOCACHE="$$PWD/.gocache" GOTMPDIR="$$PWD/.gotmp" \
		GOMODCACHE="$$PWD/.gomodcache" GOPATH="$$PWD/.gopath" GOFLAGS="-mod=mod" go run .

# Traefik + whoami stand, with the plugin mounted as a local plugin.
integration:
	@docker compose up -d

# End to end verification of the logging behaviour: the plugin logs into the
# Traefik log file, never into the process output, and logLevel: off is silent.
e2e:
	@./e2e.sh
