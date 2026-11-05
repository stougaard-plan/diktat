#!/bin/zsh
# Tester teksterne om sprogets låsestyrke og mode-overstyring. Ingen model, ingen lyd.
set -e
ROOT="${0:A:h:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
T=$(mktemp -d)
cp "$ROOT/scripts/tests/language_lock_test.swift" "$T/main.swift"
swiftc -Onone -o "$T/t" "$T/main.swift" "$ROOT/VoiceInk/Features/ModelLibrary/Models/TranscriptionLanguageLock.swift"
"$T/t"
