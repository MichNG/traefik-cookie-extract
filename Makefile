.PHONY: test test-race cover fuzz yaegi-check integration e2e integration-nightly chaos bench-e2e nightly

# Runs gofmt, go vet and the whole test suite. The Go caches are kept inside
# the repository so that the target also works in restricted environments.
test:
	@./run-tests.sh -count=1

test-race:
	@./run-tests.sh -race -count=1

cover:
	@./run-tests.sh -count=1 -covermode=atomic -coverprofile=coverage.txt
	@go tool cover -html=coverage.txt -o cover.html

# Runs every fuzz target for a bounded time (the seed corpus also runs with the
# unit tests). Knob: FUZZTIME (20s per target).
FUZZ_TARGETS = FuzzJSONField FuzzCookieHeaderValue

fuzz:
	@for target in $(FUZZ_TARGETS); do \
		echo "--- $$target ---"; \
		GOCACHE="$$PWD/.gocache" GOTMPDIR="$$PWD/.gotmp" GOMODCACHE="$$PWD/.gomodcache" GOPATH="$$PWD/.gopath" \
			GOFLAGS="-mod=mod" go test -run '^$$' -fuzz="$$target" -fuzztime=$${FUZZTIME:-20s} . || exit 1; \
	done

# Loads the plugin with the same Yaegi interpreter as Traefik (v0.16.1) and
# drives a few requests through it. The Go caches of the tool are kept inside
# tools/yaegicheck, so that the target also works in restricted environments.
yaegi-check:
	@cd tools/yaegicheck && mkdir -p .gocache .gotmp .gomodcache .gopath && \
		GOCACHE="$$PWD/.gocache" GOTMPDIR="$$PWD/.gotmp" \
		GOMODCACHE="$$PWD/.gomodcache" GOPATH="$$PWD/.gopath" GOFLAGS="-mod=mod" go run .

# Traefik + whoami stand, with the plugin mounted as a local plugin.
integration:
	@docker compose up -d

# End to end verification of the logging behaviour: the plugin logs into the
# Traefik log file, never into the process output, and logLevel: off is silent.
e2e:
	@./e2e.sh

# The docker stands of the nightly pipeline (non-default host ports, every script
# brings its own stand up and down). See .github/workflows/nightly.yml.
integration-nightly:
	@./hack/ci/integration.sh

# Faults injected while the plugin serves traffic: backend and Traefik restarts,
# a reload storm, hostile requests, and a spam phase that must stay quiet.
chaos:
	@./hack/ci/chaos.sh

# End-to-end load: throughput and latency percentiles, and the log volume under
# load (the anti-spam property of the plugin).
bench-e2e:
	@./hack/bench/run.sh

nightly: integration-nightly chaos bench-e2e
