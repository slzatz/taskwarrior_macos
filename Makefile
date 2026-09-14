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

.PHONY: all app build run debug test clean

all: app

build:
	swift build -c $(CONFIG) --product $(PRODUCT)

app: build
	rm -rf "$(BUNDLE)"
	mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	cp "$(BINARY)" "$(CONTENTS)/MacOS/$(APP_NAME)"
	cp Resources/Info.plist "$(CONTENTS)/Info.plist"
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
