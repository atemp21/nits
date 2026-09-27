.PHONY: help build test probe probe-write clean gen app run run-panel stop shots

help:
	@echo "nits — targets:"
	@echo "  make build        build NitsCore + nitsprobe"
	@echo "  make test         run unit tests (no hardware needed)"
	@echo "  make probe        hardware diagnostics, read-only"
	@echo "  make probe-write  diagnostics + a test brightness write (B=50)"
	@echo "  make app          generate the Xcode project and build nits.app"
	@echo "  make run          build and launch the menu-bar app"
	@echo "  make stop         quit a running instance"
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

# The Xcode project is generated from project.yml and is not checked in.
gen:
	@command -v xcodegen >/dev/null 2>&1 || { echo "xcodegen missing: brew install xcodegen"; exit 1; }
	@xcodegen generate

app: gen
	@xcodebuild -project nits.xcodeproj -scheme nits -configuration Debug build \
		| grep -E 'error:|BUILD' || true

APP_PATH = $(shell xcodebuild -project nits.xcodeproj -scheme nits -configuration Debug \
	-showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/{print $$3}')/nits.app

run: app stop
	@echo "launching $(APP_PATH)"
	@open -a "$(APP_PATH)"

# --show-panel opens the panel immediately, for screenshots and manual checks.
run-panel: app stop
	@open -a "$(APP_PATH)" --args --show-panel

stop:
	@pkill -f 'nits.app/Contents/MacOS/nits' 2>/dev/null || true

# Offscreen renders for design review; needs no Screen Recording permission.
SHOT_DIR ?= build/shots
shots: app
	@mkdir -p $(SHOT_DIR)
	@"$(APP_PATH)/Contents/MacOS/nits" --render-panel $(SHOT_DIR)/panel.png
	@"$(APP_PATH)/Contents/MacOS/nits" --render-hud $(SHOT_DIR)/hud.png

clean:
	swift package clean
	rm -rf .build nits.xcodeproj
