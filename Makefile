.PHONY: help build test probe probe-write clean gen app run run-panel stop shots signing-cert \
	release release-cert dmg install uninstall

help:
	@echo "nits — targets:"
	@echo "  make build        build NitsCore + nitsprobe"
	@echo "  make test         run unit tests (no hardware needed)"
	@echo "  make probe        hardware diagnostics, read-only"
	@echo "  make probe-write  diagnostics + a test brightness write (B=50)"
	@echo "  make app          generate the Xcode project and build nits.app"
	@echo "  make signing-cert create the local signing identity (once per machine)"
	@echo "  make run          build and launch the menu-bar app"
	@echo "  make stop         quit a running instance"
	@echo "  make install      build a Release nits.app and copy it to /Applications"
	@echo "  make uninstall    quit nits and remove it from /Applications"
	@echo "  make dmg          build a Release nits.app and package it as build/nits-VERSION.dmg"
	@echo "  make release-cert create the release signing identity (once, ever)"
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

# Accessibility grants are tied to the code signature. Ad-hoc signatures change on
# every build, which silently revokes the grant, so re-sign with a stable local
# identity when one exists. `make signing-cert` creates it.
SIGN_IDENTITY ?= nits Local Signing

# TCC keys grants on the bundle id, so a fork building alongside an installed copy
# should pick its own: `make run BUNDLE_ID=com.example.nits`.
BUNDLE_ID ?= com.aarontempleton.nits

app: gen
	@xcodebuild -project nits.xcodeproj -scheme nits -configuration Debug \
		PRODUCT_BUNDLE_IDENTIFIER=$(BUNDLE_ID) build \
		| grep -E 'error:|BUILD' || true
	@if security find-identity -p codesigning | grep -q "$(SIGN_IDENTITY)"; then \
		codesign -f -s "$(SIGN_IDENTITY)" "$(APP_PATH)" 2>/dev/null \
			&& echo "signed with $(SIGN_IDENTITY)"; \
	else \
		echo "warning: no '$(SIGN_IDENTITY)' identity; ad-hoc signed, so Accessibility resets each build (run: make signing-cert)"; \
	fi

# One-off: a self-signed code-signing identity in the login keychain.
signing-cert:
	@scripts/signing-cert.sh "$(SIGN_IDENTITY)"

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

# --- Releases ---------------------------------------------------------------------
#
# No paid Apple Developer account, so no Developer ID and no notarisation: Gatekeeper
# warns on first open whatever we do. Signing every release with one long-lived
# self-signed certificate still matters, because the Accessibility grant is keyed on
# it. Ad-hoc releases would silently lose the grant on every update.

RELEASE_IDENTITY ?= nits Release Signing
RELEASE_DIR = build/release
RELEASE_APP = $(RELEASE_DIR)/DerivedData/Build/Products/Release/nits.app
# From the latest tag, so CI building v0.2.0 ships 0.2.0.
VERSION ?= $(shell git describe --tags --abbrev=0 --match 'v*' 2>/dev/null | sed 's/^v//' || true)
BUILD_NUMBER ?= $(shell git rev-list --count HEAD)
# CI sets this so a missing certificate fails the release instead of shipping ad-hoc.
REQUIRE_SIGNED ?=

release-cert:
	@scripts/signing-cert.sh "$(RELEASE_IDENTITY)" build/release-cert/nits-release.p12

release: gen
	@test -n "$(VERSION)" || { echo "no version: tag a release (git tag v0.1.0) or pass VERSION=x.y.z"; exit 1; }
	@rm -rf $(RELEASE_DIR) && mkdir -p $(RELEASE_DIR)
	@xcodebuild -project nits.xcodeproj -scheme nits -configuration Release \
		-derivedDataPath $(RELEASE_DIR)/DerivedData \
		PRODUCT_BUNDLE_IDENTIFIER=$(BUNDLE_ID) \
		MARKETING_VERSION=$(VERSION) CURRENT_PROJECT_VERSION=$(BUILD_NUMBER) \
		build > $(RELEASE_DIR)/build.log 2>&1 \
		|| { grep -E 'error:' $(RELEASE_DIR)/build.log || tail -30 $(RELEASE_DIR)/build.log; exit 1; }
	@if security find-identity -p codesigning | grep -q "\"$(RELEASE_IDENTITY)\""; then \
		codesign -f -s "$(RELEASE_IDENTITY)" "$(RELEASE_APP)" && echo "signed with $(RELEASE_IDENTITY)"; \
	elif [ -n "$(REQUIRE_SIGNED)" ]; then \
		echo "error: no '$(RELEASE_IDENTITY)' identity"; exit 1; \
	else \
		echo "warning: no '$(RELEASE_IDENTITY)' identity; ad-hoc signed, not fit to publish (run: make release-cert)"; \
	fi
	@codesign --verify --strict "$(RELEASE_APP)"
	@echo "built $(RELEASE_APP) ($(VERSION), build $(BUILD_NUMBER))"

# Plain hdiutil rather than create-dmg: one less dependency, and the Applications
# symlink is all the drag-to-install layout needs.
DMG = build/nits-$(VERSION).dmg
dmg: release
	@rm -rf $(RELEASE_DIR)/dmg $(DMG)
	@mkdir -p $(RELEASE_DIR)/dmg
	@ditto "$(RELEASE_APP)" $(RELEASE_DIR)/dmg/nits.app
	@ln -s /Applications $(RELEASE_DIR)/dmg/Applications
	@hdiutil create -volname "nits $(VERSION)" -srcfolder $(RELEASE_DIR)/dmg \
		-fs HFS+ -format UDZO -ov -quiet $(DMG)
	@cd build && shasum -a 256 nits-$(VERSION).dmg > nits-$(VERSION).dmg.sha256
	@echo "packaged $(DMG)"

# --- Installing from source -------------------------------------------------------
#
# A Release build signed with the local identity. Built on this machine, so it never
# gets the quarantine flag and Gatekeeper does not get involved. The version falls
# back to 0.0.0 in a clone without tags.

INSTALL_DIR ?= /Applications

install: signing-cert
	@$(MAKE) --no-print-directory release RELEASE_IDENTITY="$(SIGN_IDENTITY)" \
		VERSION="$(or $(VERSION),0.0.0)" REQUIRE_SIGNED=1
	@$(MAKE) --no-print-directory stop
	@rm -rf "$(INSTALL_DIR)/nits.app"
	@ditto "$(RELEASE_APP)" "$(INSTALL_DIR)/nits.app"
	@echo "installed $(INSTALL_DIR)/nits.app"
	@open "$(INSTALL_DIR)/nits.app"

uninstall: stop
	@rm -rf "$(INSTALL_DIR)/nits.app"
	@echo "removed $(INSTALL_DIR)/nits.app"

clean:
	swift package clean
	rm -rf .build nits.xcodeproj
