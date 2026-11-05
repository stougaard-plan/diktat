#!/bin/zsh
# Tester kø, fejl, afbrudt kørsel, manglende script/python, HF_TOKEN og parser med konstruerede mapper og falske scripts.
# Tester også mødetitlen (titel skrevet, server nede, timeout, genforsøg, gamle møder urørt, manuel titel bevares,
# meningsløst giver Møde, FRA som standard) mod en falsk Ollama på 127.0.0.1. Ingen lyd, ingen rigtig transskription, ingen rigtig model.
set -e
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ROOT="${0:A:h:h:h}"
M="$ROOT/VoiceInk/Features/Meeting"
# Netværkskode må kun findes i MeetingTitleModel.swift. Adressen kommer fra en indstilling og OllamaHostPolicy.
# Eneste faste adresse i filen er standardadressen 127.0.0.1:11434.
if grep -nE "URLSession|https?://|NWConnection|NWPath|CFSocket|Socket\(|localhost|Process\(\)|ssh " "$M/MeetingTitle.swift" "$M/MeetingTitler.swift"; then
  echo "FEJL titellogikken indeholder netværks- eller procesbrug"; exit 1
fi
BAD=$(grep -nE "https?://" "$M/MeetingTitleModel.swift" | grep -vE 'defaultURL = "http://127\.0\.0\.1:11434"|^\s*[0-9]+:\s*///' || true)
if [ -n "$BAD" ]; then echo "FEJL MeetingTitleModel indeholder en anden fast adresse end 127.0.0.1:11434:"; echo "$BAD"; exit 1; fi
if ! grep -q "OllamaHostPolicy.validate" "$M/MeetingTitleModel.swift"; then echo "FEJL MeetingTitleModel bruger ikke OllamaHostPolicy"; exit 1; fi
echo "OK   netværkskode kun i MeetingTitleModel.swift, fast adresse kun 127.0.0.1:11434, adressepolitik brugt"
T=$(mktemp -d)
PIDS=()
trap 'kill "${PIDS[@]}" 2>/dev/null; true' EXIT
# Ledige porte vælges ved hver kørsel, så to testkørsler samtidig ikke støder sammen. Offset 99 skal være lukket.
PB=$(python3 "$ROOT/scripts/tests/pick_port_base.py" 1 2 3 4 5 6 7 8 9 99)
export DIKTAT_TEST_PORT_BASE="$PB"
for pair in ok:1 think:2 hang:3 err500:4 garbage:5 empty:6 redirect:7:1 notdone:8 nothink:9; do
  mode="${pair%%:*}"; rest="${pair#*:}"
  if [[ "$mode" == "redirect" ]]; then port=$((PB + ${rest%%:*})); arg="redirect:$((PB + ${rest#*:}))"; else port=$((PB + rest)); arg="$mode"; fi
  python3 "$ROOT/scripts/tests/title_fake_ollama.py" "$arg" "$port" "$T/req_$port.log" & PIDS+=($!)
done
export TITLE_TEST_DIR="$T"
cp "$ROOT/scripts/tests/meeting_transcriber_test.swift" "$T/main.swift"
swiftc -Onone -o "$T/t" "$T/main.swift" \
  "$M/MeetingTranscript.swift" "$M/MeetingTranscriber.swift" "$M/MeetingTitle.swift" "$M/MeetingTitler.swift" "$M/MeetingTitleModel.swift" \
  "$ROOT/VoiceInk/Infrastructure/Providers/Enhancement/Ollama/OllamaService.swift" \
  "$ROOT/VoiceInk/Features/Enhancement/Workflows/CleanupFallback.swift"
sleep 1
"$T/t"
