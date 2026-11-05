# Diktat. Bygger en lokal udgave. Se README.md.
#
#   make check     tjekker Xcode (version), macOS-SDK, Metal-komponenten og værktøjerne. Henter intet.
#   make whisper   bygger whisper.xcframework (kun macOS) i ~/VoiceInk-Dependencies (kræver git og cmake)
#   make signing   opretter et lokalt selvsigneret certifikat, så tilladelserne består efter nye builds
#   make local     bygger appen: .local-build/Build/Products/Release/Diktat.app
#   make clean     fjerner ~/VoiceInk-Dependencies
#
# whisper.cpp hentes fra GitHub og låses til en bestemt version, så alle bygger det samme.
# Xcode: DEVELOPER_DIR fra miljøet, ellers /Applications/Xcode.app, ellers det Xcode, `xcode-select -p` peger på.
# Eksporteres, så ALLE trin (xcodebuild, xcrun, cmake, build-diktat.sh) bruger det samme Xcode.
ifeq ($(origin DEVELOPER_DIR),undefined)
  ifneq ($(wildcard /Applications/Xcode.app/Contents/Developer),)
    DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
  else
    DEVELOPER_DIR := $(shell xcode-select -p 2>/dev/null)
  endif
endif
export DEVELOPER_DIR
# Homebrews mapper (cmake, ffmpeg m.fl.) kommer med i PATH, også i en agents skal, der ikke har dem i forvejen.
export PATH := /opt/homebrew/bin:/usr/local/bin:$(PATH)

DEPS_DIR := $(HOME)/VoiceInk-Dependencies
WHISPER_CPP_DIR := $(DEPS_DIR)/whisper.cpp
WHISPER_CPP_REF := 482279b8a18855ba741d7b88c30fcb3874691f59
FRAMEWORK_PATH := $(WHISPER_CPP_DIR)/build-apple/whisper.xcframework

.PHONY: all check env envpath whisper signing local clean help

all: help

check:
	@echo "Tjekker værktøjer..."
	@command -v git >/dev/null 2>&1 || { echo "git mangler. Installér Xcode, så følger det med."; exit 1; }
	@test -x "$(DEVELOPER_DIR)/usr/bin/xcodebuild" || { echo "Xcode blev ikke fundet i '$(DEVELOPER_DIR)'. Installér Xcode fra developer.apple.com/download (gratis med Apple-id), eller sæt DEVELOPER_DIR."; exit 1; }
	@echo "Xcode: $(DEVELOPER_DIR)"
	@"$(DEVELOPER_DIR)/usr/bin/xcodebuild" -version || { echo "xcodebuild kan ikke køre. Åbn Xcode én gang og acceptér vilkårene."; exit 1; }
	@xcrun --find swift >/dev/null 2>&1 || { echo "swift mangler i Xcode."; exit 1; }
	@xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1 || { echo "macOS-SDK mangler i Xcode."; exit 1; }
	@xcrun --find metal >/dev/null 2>&1 || { echo "Metal-komponenten mangler. Den hentes med: DEVELOPER_DIR=\"$(DEVELOPER_DIR)\" xcodebuild -downloadComponent MetalToolchain (ca. 700 MB, samme Xcode som bygningen). Det gøres ikke automatisk. Kør den selv, og kør make igen."; exit 1; }
	@echo "Værktøjer OK"

# Viser, hvilket Xcode underprocesser får. Bruges af testen.
env:
	@sh -c 'echo "$$DEVELOPER_DIR"'

# Viser PATH, som underprocesser får. Bruges af testen.
envpath:
	@sh -c 'echo "$$PATH"'

whisper: check
	@mkdir -p $(DEPS_DIR)
	@if [ -d "$(FRAMEWORK_PATH)" ]; then \
		echo "whisper.xcframework findes allerede i $(DEPS_DIR), springer over"; \
	else \
		command -v cmake >/dev/null 2>&1 || { echo "cmake blev ikke fundet i PATH (Homebrews mapper /opt/homebrew/bin og /usr/local/bin er med). Installér med: brew install cmake"; exit 1; }; \
		if [ ! -d "$(WHISPER_CPP_DIR)/.git" ]; then git clone https://github.com/ggerganov/whisper.cpp.git $(WHISPER_CPP_DIR); fi; \
		cd $(WHISPER_CPP_DIR) && git fetch --quiet origin && git checkout --quiet $(WHISPER_CPP_REF) && cd - >/dev/null && \
		scripts/build-whisper-macos.sh $(WHISPER_CPP_DIR); \
	fi

signing:
	@scripts/setup-signing.sh

local: check whisper
	@scripts/build-diktat.sh

clean:
	@echo "Fjerner $(DEPS_DIR)"
	@rm -rf $(DEPS_DIR)

help:
	@echo "make check | whisper | signing | local | clean"
	@echo "Se README.md for hele forløbet."
