#!/bin/zsh
# D3: konverteringsfejl i lydskriveren registreres i status, og vagthundens ur kræver en vellykket skrivning.
set -e
ROOT="${0:A:h:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
T=$(mktemp -d)
cp "$ROOT/scripts/tests/meeting_audio_conversion_test.swift" "$T/main.swift"
swiftc -Onone -D HAS_CONVERSION_STATUS -o "$T/t" "$T/main.swift" "$ROOT/VoiceInk/Features/Meeting/MeetingAudio.swift"
"$T/t"
