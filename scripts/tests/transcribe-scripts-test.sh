#!/bin/zsh
# Tester mødescripts (scripts/transcribe) uden app og uden netværk:
#  - manglende model, manglende tilladelse til talerseparation og at HF_TOKEN aldrig havner i en fil eller i output
#  - en rigtig kørsel på syntetisk tale (macOS `say`, stemmen Sara) hvis whisper-cli, ffmpeg og modellen findes
# Rører ikke ~/Moeder, kun en midlertidig mappe. Kør med: scripts/tests/transcribe-scripts-test.sh [python3]
ROOT="${0:A:h:h:h}"
PY="${1:-/usr/bin/python3}"
SCRIPT="$ROOT/scripts/transcribe/moede_transcribe.py"
T=$(mktemp -d)
FAILS=0
check() { if [ "$1" = "0" ]; then echo "OK   $2"; else echo "FEJL $2"; FAILS=$((FAILS+1)); fi; }

echo "Python: $($PY --version 2>&1)"
# 0. Ingen personlige stier eller navne i scripts. Generisk: ingen hjemmemappe, brugernavn, maskinnavn eller sky-drev-sti.
#    Navnene hentes fra den Mac, testen kører på, så testen selv ikke rummer noget navn.
PATHS="/Users/|/home/|GoogleDrive|CloudStorage|Mit drev"
NAMES=""
for n in "$(id -un)" "$(hostname -s)"; do [ ${#n} -ge 4 ] && NAMES="${NAMES:+$NAMES|}$n"; done
FILES=("$ROOT"/scripts/transcribe/*.py "$ROOT"/scripts/transcribe/*.sh "$ROOT"/scripts/transcribe/*.md "$ROOT"/scripts/transcribe/*.txt)
HIT=0
grep -n -i -E "$PATHS" "${FILES[@]}" && HIT=1
[ -n "$NAMES" ] && grep -n -i -w -E "$NAMES" "${FILES[@]}" && HIT=1
if [ $HIT -ne 0 ]; then check 1 "scripts indeholder personlige stier eller navne"; else check 0 "scripts indeholder ingen personlige stier eller navne"; fi

# 1. Mødemappe med syntetisk tale
M="$T/Moeder/test"; mkdir -p "$M"
say -v Sara -o "$T/s1.aiff" "Hej, jeg ringer angående fristen for høringssvaret til lokalplanen. Kan vi tale om det i morgen?" 2>/dev/null
afconvert -f caff -d LEI16@16000 -c 1 "$T/s1.aiff" "$M/mik_0001.caf" 2>/dev/null
say -v Sara -o "$T/s2.aiff" "Ja, fristen er den fjerde december. Du kan sende et kort svar nu." 2>/dev/null
afconvert -f caff -d LEI16@16000 -c 1 "$T/s2.aiff" "$M/computer_0001.caf" 2>/dev/null
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat > "$M/meta.json" <<J
{"title":"Møde","startedAt":"$NOW","status":"stopped","sources":{},"events":[],
 "segments":[{"track":"mik","file":"mik_0001.caf","startedAt":"$NOW"},{"track":"computer","file":"computer_0001.caf","startedAt":"$NOW"}]}
J
[ -s "$M/mik_0001.caf" ]; check $? "testlyd lavet med say og afconvert"

# 2. Modelmappen findes ikke: tydelig dansk fejl, exitkode 3, intet transskript
mkdir -p "$T/tomt-hjem"
OUT=$(HOME="$T/tomt-hjem" DIKTAT_WHISPER_MODELS="$T/ingen-modeller" $PY "$SCRIPT" "$M" 2>&1); RC=$?
[ $RC -eq 3 ] && [[ "$OUT" == *"Whisper-modellen"* && "$OUT" == *"huggingface.co/ggerganov/whisper.cpp"* ]]; check $? "manglende model: exit 3 og besked med hentelink"
[ ! -e "$M/transskript.txt" ]; check $? "manglende model: intet transskript skrevet"

# 3. Rigtig kørsel, hvis værktøjer og model findes
MODELS="${DIKTAT_WHISPER_MODELS:-$HOME/.whisper-models}"
if command -v whisper-cli >/dev/null || [ -x /opt/homebrew/bin/whisper-cli ]; then
  if [ -f "$MODELS/ggml-large-v3-turbo-q5_0.bin" ] && { command -v ffmpeg >/dev/null || [ -x /opt/homebrew/bin/ffmpeg ]; }; then
    unset HF_TOKEN
    OUT=$($PY "$SCRIPT" "$M" 2>&1); RC=$?
    [ $RC -eq 0 ] && [ -s "$M/transskript.txt" ]; check $? "rigtig kørsel uden HF_TOKEN: exit 0 og transskript skrevet (exit $RC)"
    grep -q -i "lokalplan" "$M/transskript.txt"; check $? "rigtig kørsel: ordet 'lokalplan' står i transskriptet"
    grep -q "Mig:" "$M/transskript.txt"; check $? "rigtig kørsel: mikrofonen står som Mig"
    grep -q "De:" "$M/transskript.txt"; check $? "rigtig kørsel: computerlyden står som De"
    grep -q "HF_TOKEN er ikke sat" "$M/transskript.txt"; check $? "uden HF_TOKEN: tydelig bemærkning i transskriptet"
    echo "$OUT" | grep -q "ADVARSEL: HF_TOKEN er ikke sat"; check $? "uden HF_TOKEN: tydelig advarsel på skærmen (stderr)"
    # 4. HF_TOKEN sat, men pyannote findes ikke i denne Python: kører videre uden, og tokenet ses ingen steder
    rm -f "$M/transskript.txt"
    FAKE="TESTTOKEN_NOT_REAL_0123456789abcdef"
    OUT=$(HF_TOKEN="$FAKE" DIKTAT_PYTHON="/findes/ikke" $PY "$SCRIPT" "$M" 2>&1); RC=$?
    [ $RC -eq 0 ] && [ -s "$M/transskript.txt" ]; check $? "HF_TOKEN uden pyannote: kører videre (exit $RC)"
    grep -q "pyannote er ikke installeret" "$M/transskript.txt"; check $? "HF_TOKEN uden pyannote: bemærkning om at pyannote mangler"
    if grep -rq "$FAKE" "$M" || echo "$OUT" | grep -q "$FAKE"; then check 1 "tokenet er ikke i nogen fil eller i output"; else check 0 "tokenet er ikke i nogen fil eller i output"; fi
  else
    echo "SPRUNGET OVER rigtig kørsel: modellen ggml-large-v3-turbo-q5_0.bin eller ffmpeg mangler"
  fi
else
  echo "SPRUNGET OVER rigtig kørsel: whisper-cli mangler"
fi
rm -rf "$T"
[ $FAILS -eq 0 ] && echo "ALLE TESTS BESTÅET" || echo "$FAILS FEJL"
exit $FAILS
