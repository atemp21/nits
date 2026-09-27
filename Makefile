.PHONY: help build test probe probe-write clean gen

help:
	@echo "nits — targets:"
	@echo "  make build        build NitsCore + nitsprobe"
	@echo "  make test         run unit tests (no hardware needed)"
	@echo "  make probe        hardware diagnostics, read-only"
	@echo "  make probe-write  diagnostics + a test brightness write (B=50)"
	@echo "  make clean        remove build artifacts"

build:
	swift build

test:
	swift test

probe: build
	@./.build/debug/nitsprobe

B ?= 50
probe-write: build
	@./.build/debug/nitsprobe --set-brightness $(B)

clean:
	swift package clean
	rm -rf .build

# Generates the app-bundle Xcode project (needed from M3 onward, not before).
gen:
	@command -v xcodegen >/dev/null 2>&1 || { echo "xcodegen missing: brew install xcodegen"; exit 1; }
	xcodegen generate
