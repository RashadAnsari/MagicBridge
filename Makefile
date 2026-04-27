APP_NAME = MagicBridge
APP_BUNDLE_IDENTIFIER = me.ansarihamedani.magicbridge.app
DERIVED_DATA = $(HOME)/Library/Developer/Xcode/DerivedData
BUILD_DIR = $(shell find $(DERIVED_DATA) -name "$(APP_NAME).app" -path "*/Debug/*" 2>/dev/null | head -1 | xargs dirname 2>/dev/null)
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/{print $$2; exit} /Apple Development/{print $$2; exit}')

.PHONY: deps install uninstall clean release test format lint

deps:
	@which xcodegen > /dev/null || brew install xcodegen

install: deps
	xcodegen generate
	xcodebuild -scheme $(APP_NAME) -configuration Debug build \
		CODE_SIGNING_ALLOWED=NO \
		CODE_SIGNING_REQUIRED=NO
	cp -R "$(BUILD_DIR)/$(APP_NAME).app" /Applications/
	xattr -dr com.apple.quarantine /Applications/$(APP_NAME).app
	open /Applications/$(APP_NAME).app

uninstall: deps
	rm -rf /Applications/$(APP_NAME).app
	defaults delete $(APP_BUNDLE_IDENTIFIER)

clean: deps
	xcodebuild -scheme $(APP_NAME) clean 2>/dev/null || true
	rm -rf $(APP_NAME).xcodeproj

release: deps
	@if [ -z "$(SIGN_IDENTITY)" ]; then \
		echo "No code signing identity found. Run: security find-identity -v -p codesigning"; \
		exit 1; \
	fi
	@echo "Signing with: $(SIGN_IDENTITY)"
	xcodegen generate
	xcodebuild -scheme $(APP_NAME) -configuration Release build \
		CODE_SIGN_STYLE=Manual \
		CODE_SIGN_IDENTITY="$(SIGN_IDENTITY)" \
		CODE_SIGN_ENTITLEMENTS=MagicBridge/MagicBridge.entitlements \
		ENABLE_HARDENED_RUNTIME=YES
	@RELEASE_DIR=$$(find $(DERIVED_DATA) -name "$(APP_NAME).app" -path "*/Release/*" 2>/dev/null | head -1 | xargs dirname 2>/dev/null) && \
	APP_PATH="$$RELEASE_DIR/$(APP_NAME).app" && \
	if [ -d "$$APP_PATH" ]; then \
		rm -rf "./$(APP_NAME).app" "./$(APP_NAME).zip"; \
		cp -R "$$APP_PATH" "./$(APP_NAME).app"; \
		xattr -dr com.apple.quarantine "./$(APP_NAME).app"; \
		codesign --verify --deep --strict "./$(APP_NAME).app" && echo "Signature verified"; \
		ditto -c -k --keepParent "./$(APP_NAME).app" "./$(APP_NAME).zip"; \
		echo ""; \
		echo "Done: $(APP_NAME).app  $(APP_NAME).zip"; \
	else \
		echo "Release build not found"; \
		exit 1; \
	fi

test: deps
	xcodegen generate
	xcodebuild -scheme $(APP_NAME) -configuration Debug test \
		-destination 'platform=macOS' \
		CODE_SIGNING_ALLOWED=NO \
		CODE_SIGNING_REQUIRED=NO

format: deps
	xcrun swift-format format --in-place --recursive $(APP_NAME)

lint: deps
	xcrun swift-format lint --recursive $(APP_NAME)
