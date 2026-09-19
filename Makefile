# Builds Taskwarrior.app from the Swift package.
#   make          - release build + .app bundle in build/
#   make run      - build and open the app
#   make debug    - debug build + bundle (faster compile)
#   make test     - run unit tests
#   make clean

APP_NAME   := Taskwarrior
PRODUCT    := TaskwarriorApp
CONFIG     ?= release
BUNDLE     := build/$(APP_NAME).app
CONTENTS   := $(BUNDLE)/Contents
BINARY     := .build/$(CONFIG)/$(PRODUCT)

# SwiftUI's @State is a macro in the macOS 27 SDK and the Command Line Tools
# toolchain ships no plugin to expand it, so building against that SDK fails.
# The probe prints a fallback SDK only when the default one cannot build
# SwiftUI; with Xcode installed it prints nothing and this goes dormant.
# Setting SDKROOT in the environment skips the probe entirely.
ifeq ($(origin SDKROOT),undefined)
SDKROOT := $(shell Scripts/swiftui-sdk.sh)
ifneq ($(SDKROOT),)
export SDKROOT
$(info note: default SDK cannot expand SwiftUI macros; building against $(notdir $(SDKROOT)))
endif
endif

.PHONY: all app build run debug test clean

all: app

build:
	swift build -c $(CONFIG) --product $(PRODUCT)

app: build
	rm -rf "$(BUNDLE)"
	mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	cp "$(BINARY)" "$(CONTENTS)/MacOS/$(APP_NAME)"
	cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	cp Resources/AppIcon.icns "$(CONTENTS)/Resources/AppIcon.icns"
	printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	codesign --force --sign - "$(BUNDLE)" >/dev/null 2>&1 || true
	@echo "Built $(BUNDLE)"

run: app
	open "$(BUNDLE)"

debug:
	$(MAKE) app CONFIG=debug

test:
	swift test

clean:
	rm -rf .build build
