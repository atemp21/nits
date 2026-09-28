.PHONY: help build test probe probe-write clean gen app run run-panel stop shots signing-cert

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

app: gen
	@xcodebuild -project nits.xcodeproj -scheme nits -configuration Debug build \
		| grep -E 'error:|BUILD' || true
	@if security find-identity -p codesigning | grep -q "$(SIGN_IDENTITY)"; then \
		codesign -f -s "$(SIGN_IDENTITY)" "$(APP_PATH)" 2>/dev/null \
			&& echo "signed with $(SIGN_IDENTITY)"; \
	else \
		echo "warning: no '$(SIGN_IDENTITY)' identity; ad-hoc signed, so Accessibility resets each build (run: make signing-cert)"; \
	fi

# One-off: a self-signed code-signing identity in the login keychain. It need not be
# trusted; codesign only needs the key, and TCC matches on the certificate hash.
signing-cert:
	@if security find-identity -p codesigning | grep -q "$(SIGN_IDENTITY)"; then \
		echo "'$(SIGN_IDENTITY)' already exists"; exit 0; fi; \
	dir=$$(mktemp -d) && pass=$$(openssl rand -hex 12) && \
	printf '[req]\ndistinguished_name=dn\nprompt=no\nx509_extensions=ext\n[dn]\nCN=$(SIGN_IDENTITY)\n[ext]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n' > $$dir/cnf && \
	openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout $$dir/key.pem -out $$dir/cert.pem -config $$dir/cnf 2>/dev/null && \
	openssl pkcs12 -export -legacy -inkey $$dir/key.pem -in $$dir/cert.pem -name "$(SIGN_IDENTITY)" -out $$dir/id.p12 -passout pass:$$pass && \
	security import $$dir/id.p12 -k ~/Library/Keychains/login.keychain-db -P $$pass -T /usr/bin/codesign; \
	rm -rf $$dir

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
