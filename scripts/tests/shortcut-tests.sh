#!/bin/zsh
# Tester mødegenvejens logik uden mikrofon, systemlyd eller tastetryk: controller (dobbelttryk, tryk under start/stop,
# diktering kører) og validator (enkelt modifikatortast afvist, kollisioner).
set -e
ROOT="${0:A:h:h:h}"
T=$(mktemp -d)
cp "$ROOT/scripts/tests/meeting_shortcut_controller_test.swift" "$T/main.swift"
swiftc -Onone -o "$T/ctl" "$T/main.swift" "$ROOT/VoiceInk/Features/Meeting/MeetingShortcutController.swift"
"$T/ctl"
mkdir "$T/v"; cp "$ROOT/scripts/tests/shortcut_validator_test.swift" "$T/v/main.swift"; cp "$ROOT/scripts/tests/shortcut_validator_stub.swift" "$T/v/stub.swift"
swiftc -Onone -o "$T/val" "$T/v/main.swift" "$T/v/stub.swift" "$ROOT/VoiceInk/Features/Shortcuts/Models/Shortcut.swift" \
  "$ROOT/VoiceInk/Features/Shortcuts/Models/ShortcutAction.swift" "$ROOT/VoiceInk/Features/Shortcuts/State/ShortcutValidator.swift"
"$T/val"
