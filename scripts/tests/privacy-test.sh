#!/bin/zsh
# B1 og B2: skærmlæsning kræver tilvalget «Skærm», og ordlisten forlader ikke denne Mac uden særskilt tilvalg.
set -e
ROOT="${0:A:h:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
V="$ROOT/VoiceInk"
T=$(mktemp -d)
cp "$ROOT/scripts/tests/privacy_test.swift" "$T/main.swift"
swiftc -Onone -o "$T/t" "$T/main.swift" \
  "$V/Features/Recording/Context/RecordingContextSnapshot.swift" \
  "$V/Features/Dictionary/Workflows/RecordingVocabularyPreparation.swift" \
  "$V/Features/Dictionary/Workflows/RecordingVocabulary.swift" \
  "$V/Features/Dictionary/Workflows/PhoneticVocabularyMatcher.swift" \
  "$V/Features/Dictionary/Workflows/VocabularyPhonetics.swift" \
  "$V/Infrastructure/SystemIntegration/ScreenCapture/ScreenCaptureService.swift" \
  "$V/Features/Assistant/State/AssistantPrivacyKey.swift" \
  "$V/Infrastructure/Providers/Enhancement/Ollama/OllamaService.swift"
"$T/t"
