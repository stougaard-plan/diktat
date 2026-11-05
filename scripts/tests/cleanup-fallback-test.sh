#!/bin/zsh
# Tester oprydningens fejlstier (lukket port, timeout, 500, tomt svar, ugyldigt svar) og adressepolitikken.
# Ingen sprogmodel og ingen optagelse. Bruger en lille lokal testserver og testprocessens egne UserDefaults.
set -e
ROOT="${0:A:h:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
T=$(mktemp -d)
LAN=$(ipconfig getifaddr en0 || echo 127.0.0.1)
PIDS=()
# Ledige porte vælges ved hver kørsel, så to testkørsler samtidig ikke støder sammen. Offset 99 skal være lukket.
PB=$(python3 "$ROOT/scripts/tests/pick_port_base.py" 1 2 3 4 5 99)
export DIKTAT_TEST_PORT_BASE="$PB"
for pair in ok:1 hang:2 err500:3 empty:4 garbage:5; do
  python3 "$ROOT/scripts/tests/cleanup_fallback_server.py" "${pair%%:*}" "$((PB + ${pair##*:}))" & PIDS+=($!)
done
trap 'kill "${PIDS[@]}" 2>/dev/null' EXIT
cp "$ROOT/scripts/tests/cleanup_fallback_test.swift" "$T/main.swift"
swiftc -Onone -parse-as-library -o "$T/t" "$T/main.swift" \
  "$ROOT/VoiceInk/Infrastructure/Providers/Enhancement/Ollama/OllamaService.swift" \
  "$ROOT/VoiceInk/Features/Enhancement/Workflows/CleanupFallback.swift"
sleep 1
"$T/t" "$LAN"
