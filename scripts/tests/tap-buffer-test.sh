#!/bin/zsh
# Tester TapBufferConverter + sporfejl uden mikrofon/systemlyd: syntetiske AudioBufferList med 1 og 2 buffere.
set -e
ROOT="${0:A:h:h:h}"
T=$(mktemp -d)
cp "$ROOT/scripts/tests/tap_buffer_test.swift" "$T/main.swift"
swiftc -Onone -o "$T/t" "$T/main.swift" "$ROOT/VoiceInk/Features/Meeting/MeetingAudio.swift"
"$T/t"
