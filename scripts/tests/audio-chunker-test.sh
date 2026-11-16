#!/bin/zsh
# Tester AudioChunker (deling af lang lyd ved stilleste punkt). Ingen model, ingen lyd.
set -e
ROOT="${0:A:h:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
T=$(mktemp -d)
cp "$ROOT/scripts/tests/audio_chunker_test.swift" "$T/main.swift"
swiftc -Onone -o "$T/t" "$T/main.swift" "$ROOT/VoiceInk/Infrastructure/Providers/Transcription/Whisper/AudioChunker.swift"
"$T/t"
