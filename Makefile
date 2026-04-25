APP_NAME = MagicBridge
APP_BUNDLE_IDENTIFIER = me.ansarihamedani.magicbridge.app
DERIVED_DATA = $(HOME)/Library/Developer/Xcode/DerivedData
BUILD_DIR = $(shell find $(DERIVED_DATA) -name "$(APP_NAME).app" -path "*/Debug/*" 2>/dev/null | head -1 | xargs dirname 2>/dev/null)

.PHONY: deps build release install uninstall clean format lint

deps:
	@which xcodegen > /dev/null || brew install xcodegen

install:
	xcodegen generate
	xcodebuild -scheme $(APP_NAME) -configuration Debug build \
		CODE_SIGNING_ALLOWED=NO \
		CODE_SIGNING_REQUIRED=NO
	cp -R "$(BUILD_DIR)/$(APP_NAME).app" /Applications/
	xattr -dr com.apple.quarantine /Applications/$(APP_NAME).app
	open /Applications/$(APP_NAME).app

uninstall:
	rm -rf /Applications/$(APP_NAME).app
	defaults delete $(APP_BUNDLE_IDENTIFIER)

clean:
	xcodebuild -scheme $(APP_NAME) clean 2>/dev/null || true
	rm -rf $(APP_NAME).xcodeproj

release: deps
	xcodegen generate
	xcodebuild -scheme $(APP_NAME) -configuration Release build \
		CODE_SIGNING_ALLOWED=NO \
		CODE_SIGNING_REQUIRED=NO
	@RELEASE_DIR=$$(find $(DERIVED_DATA) -name "$(APP_NAME).app" -path "*/Release/*" 2>/dev/null | head -1 | xargs dirname 2>/dev/null) && \
	APP_PATH="$$RELEASE_DIR/$(APP_NAME).app" && \
	if [ -d "$$APP_PATH" ]; then \
		cp -R "$$APP_PATH" "./$(APP_NAME).app"; \
		echo "Created $(APP_NAME).app"; \
	else \
		echo "Release build not found"; \
	fi

format:
	xcrun swift-format format --in-place --recursive $(APP_NAME)

lint:
	xcrun swift-format lint --recursive $(APP_NAME)
