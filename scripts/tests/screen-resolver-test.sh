#!/bin/zsh
# Tester at paneler placeres på skærmen under musen (rene rammer + de rigtige skærme). Åbner ingen vinduer.
set -e
ROOT="${0:A:h:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
T=$(mktemp -d)
cp "$ROOT/scripts/tests/screen_resolver_test.swift" "$T/main.swift"
swiftc -Onone -o "$T/t" "$T/main.swift" "$ROOT/VoiceInk/Features/Recording/Presentation/RecorderScreenResolver.swift"
"$T/t"
