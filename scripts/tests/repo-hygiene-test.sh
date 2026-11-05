#!/bin/zsh
# Tester dokumentation, byggescripts og opsætning uden at bygge noget og uden netværk:
#  A  licens, NOTICE, README, projektfil (ingen fremmed team-id eller bundle-id)
#  B5 ingen personspor i tests og målescripts
#  C1 opsætningsprompten fejler ikke på manglende Xcode  C2 DEVELOPER_DIR eksporteres  C3 whisper bygges kun til macOS
#  C5 den valgte mappe bruges overalt  C6 intet udviklerteam  C8 startvinduets modelkrav
ROOT="${0:A:h:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
FAILS=0
check() { if [ "$1" = "0" ]; then echo "OK   $2"; else echo "FEJL $2"; FAILS=$((FAILS+1)); fi; }
cd "$ROOT" || exit 1

# ---- A: licens og kreditering ----
[ "$(wc -l < LICENSE)" -ge 600 ] && grep -q "END OF TERMS AND CONDITIONS" LICENSE && grep -q "How to Apply These Terms" LICENSE; check $? "A1 LICENSE er den fulde GPL v3-tekst"
! grep -q "For the complete license text, please visit" LICENSE; check $? "A1 LICENSE er ikke længere en stub med link"
grep -q "fulde tekst af GPL v3" README.md && ! grep -q "uændret fra VoiceInk" README.md; check $? "A1 README siger, at LICENSE er fuld tekst af GPL v3"
grep -q "Den fulde licenstekst står i filen LICENSE" NOTICE; check $? "A1 NOTICE henviser til LICENSE"
grep -q "kun v3" NOTICE && ! grep -q "eller senere" NOTICE; check $? "A2 NOTICE: kun GPL v3, ingen antagelse om «eller senere»"
grep -q "Ophav ikke undersøgt af Diktat" NOTICE && grep -q "Er du rettighedshaver" NOTICE; check $? "A3 NOTICE: lydfiler, ophav ikke undersøgt"
grep -q "Copyright (c) 2020-present Silero Team" NOTICE && grep -q "Permission is hereby granted, free of charge" NOTICE && grep -q "Silero VAD.*MIT" README.md; check $? "A4 Silero: MIT, ophavsret og licenstekst"
grep -q "G2P, NeMo Text Processing, fastcluster, vbx, KokoroANE" NOTICE && grep -q "Ikke gennemlæst. Ikke del af dette repo, hentes ved bygning" NOTICE; check $? "A5 FluidAudios tredjepartslicenser er beskrevet"
grep -q "Modstrid på modelkortet noteret 5/11-2026" NOTICE; check $? "A6 CoreML-rækken: modstrid noteret"
grep -q "SenseVoice Small" NOTICE && grep -q "SenseVoice Small (FunAudioLLM / Alibaba), FunASR Model Open Source License Agreement, https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE. Hentes af brugeren." README.md; check $? "A7 SenseVoice Small i NOTICE og README"
! grep -rIl -E "prakashjoshipax|V6J6A3VWY2" . --exclude-dir=.git --exclude=repo-hygiene-test.sh >/dev/null; check $? "A8/C6 intet fremmed bundle-id eller team-id i repoet"
! grep -q "VoiceInk Dev" VoiceInk.xcodeproj/project.pbxproj && grep -q "Diktat Dev" VoiceInk.xcodeproj/project.pbxproj; check $? "A8 Dev-målet hedder Diktat Dev"
! grep -rIl -i -E "discord|support\.voiceink|voiceink\.com" .github >/dev/null; check $? "A8 issue-skabeloner uden VoiceInks Discord eller support"
grep -q "GPL v3 §15" VoiceInk/Features/About/AboutView.swift; check $? "A9 Om-siden: ingen garanti, GPL v3 §15"
grep -q "^## Ansvar" README.md && grep -q "Udgiveren hæfter ikke for fejl i transskriptioner" README.md; check $? "A10 README: afsnittet Ansvar"
grep -q "Efter gennemgang af kildekoden sender appen ikke lyd eller tekst til nogen tjeneste. Trafikken er ikke målt under kørsel" README.md; check $? "A11 README: netværkspåstanden er afgrænset"
[ ! -e VoiceInkRefineXPC ] && [ ! -e Shared ] && ! grep -rIl -i "refine" VoiceInk VoiceInk.xcodeproj Tests scripts --exclude=repo-hygiene-test.sh >/dev/null; check $? "A12 VoiceInk-Refine er fjernet helt"
grep -q "Støtte for modellen VoiceInk-Refine-V1." NOTICE && ! grep -q "beingpax/VoiceInk-Refine-V1" NOTICE; check $? "A12 NOTICE: Fjernet-linje, ingen tabelrække"
[ ! -e VoiceInk/Assets.xcassets/nvidia-logo.imageset ]; check $? "A13 nvidia-logo er fjernet"
! grep -q '<UDGIVER>' NOTICE README.md && grep -q 'Udgivet af Stougaard Plan ApS (CVR 45908941)' NOTICE && grep -q 'Udgivet af Stougaard Plan ApS (CVR 45908941)' README.md; check $? "A14 udgiver er udfyldt i NOTICE og README"
plutil -lint VoiceInk.xcodeproj/project.pbxproj >/dev/null; check $? "projektfilen er gyldig"

# ---- B5: ingen personspor ----
! grep -n -E "[A-Z][a-zæøå]+ [A-Z][a-zæøå]+ (siger|sagde)" scripts/benchmark-sprog/refs.json >/dev/null; check $? "B5 refs.json: ingen konkrete personer (kontrolleres i øvrigt af den generiske scanning i transcribe-scripts-test.sh)"
grep -q "PATHS=" scripts/tests/transcribe-scripts-test.sh && grep -q "id -un" scripts/tests/transcribe-scripts-test.sh; check $? "B5 transcribe-scripts-test.sh scanner generisk efter stier, brugernavn og værtsnavn"

# ---- C1: opsætningsprompten ----
! grep -n 'ls -d /Applications/Xcode' OPSAETNING_PROMPT.txt >/dev/null; check $? "C1 ingen ls med stjerne på /Applications/Xcode*"
grep -q "find /Applications -maxdepth 1 -name 'Xcode\*.app'" OPSAETNING_PROMPT.txt && grep -q "FORVENTET og ikke en fejl" OPSAETNING_PROMPT.txt; check $? "C1 manglende Xcode er forventet, ikke STOP"
OUT=$(zsh -c "find /Applications -maxdepth 1 -name 'Xcode-findes-ikke*.app'" 2>&1); [ $? -eq 0 ] && [ -z "$OUT" ]; check $? "C1 find giver ingen zsh-fejl, når der ikke er noget Xcode"
zsh -c 'ls -d /Applications/Xcode-findes-ikke*.app' >/dev/null 2>&1; [ $? -ne 0 ]; check $? "C1 (baggrund) den gamle ls-form fejler i zsh uden Xcode"

# ---- C2: DEVELOPER_DIR eksporteres til underprocesser ----
EXPECT=/Applications/Xcode.app/Contents/Developer
if [ -d "$EXPECT" ]; then
  [ "$(env -u DEVELOPER_DIR make env 2>/dev/null)" = "$EXPECT" ]; check $? "C2 make: uden DEVELOPER_DIR eksporteres standard til underprocesser"
fi
[ "$(DEVELOPER_DIR=/Library/Developer/CommandLineTools make env 2>/dev/null)" = "/Library/Developer/CommandLineTools" ]; check $? "C2 make: sat DEVELOPER_DIR bevares og eksporteres"
grep -q "^export DEVELOPER_DIR" Makefile && grep -q "^export DEVELOPER_DIR" scripts/build-diktat.sh && grep -q 'xcodebuild" -version' scripts/build-diktat.sh; check $? "C2 Makefile og build-diktat.sh eksporterer DEVELOPER_DIR og kører xcodebuild -version"
grep -q "xcodebuild -version" OPSAETNING_PROMPT.txt && grep -q "export DEVELOPER_DIR=" OPSAETNING_PROMPT.txt; check $? "C2 opsætningsprompten eksporterer DEVELOPER_DIR i hver byggekommando"

# ---- C3: whisper kun til macOS ----
GEN=$(mktemp -d)/gen.sh
W="$HOME/VoiceInk-Dependencies/whisper.cpp"
if [ -f "$W/build-xcframework.sh" ]; then
  scripts/build-whisper-macos.sh --generate "$W" "$GEN" >/dev/null 2>&1; check $? "C3 genererer macOS-only byggescript fra whisper.cpps eget"
  bash -n "$GEN"; check $? "C3 det genererede script er gyldigt"
  [ "$(grep -c '^cmake -B ' "$GEN")" = 1 ] && grep -q "cmake -B build-macos" "$GEN"; check $? "C3 kun ét cmake-trin: macOS"
  ! grep -E "iphoneos|iphonesimulator|appletv|xros|xrsimulator" "$GEN" | grep -v -E "^\s*(local |case|#|echo)" | grep -q "SYSROOT\|framework\|combine_static"; check $? "C3 ingen iOS-, tvOS- eller visionOS-trin tilbage"
  [ "$(grep -c -- '-framework \$(pwd)/build-' "$GEN")" = 2 ]; check $? "C3 xcframework laves af kun én platform (to linjer, én i hver variant)"
  ! grep -q 'build-\(ios\|tvos\|visionos\)[a-z-]*/framework' "$GEN"; check $? "C3 ingen andre platforme i create-xcframework"
  cp "$W/build-xcframework.sh" "$(dirname "$GEN")/skrevet.sh"; echo "# ændret" >> "$(dirname "$GEN")/skrevet.sh"
  mkdir -p "$(dirname "$GEN")/w" && cp "$(dirname "$GEN")/skrevet.sh" "$(dirname "$GEN")/w/build-xcframework.sh"
  scripts/build-whisper-macos.sh --generate "$(dirname "$GEN")/w" "$(dirname "$GEN")/out.sh" >/dev/null 2>&1; [ $? -eq 3 ]; check $? "C3 en anden version af whisper-scriptet afvises (tjekssum)"
  # K2: afvis eksisterende filer, symlinks og ens input/output. K3: ingen oprydning af andre platformes mapper.
  # K4: relative stier virker fra en anden mappe.
  KD="$(dirname "$GEN")/k"; mkdir -p "$KD"
  echo "findes" > "$KD/findes.sh"; ln -s "$KD/findes.sh" "$KD/link.sh"
  scripts/build-whisper-macos.sh --generate "$W" "$KD/findes.sh" >/dev/null 2>&1; R1=$?
  [ $R1 -eq 2 ] && [ "$(cat "$KD/findes.sh")" = "findes" ]; check $? "K2 en eksisterende udfil afvises og røres ikke"
  scripts/build-whisper-macos.sh --generate "$W" "$KD/link.sh" >/dev/null 2>&1; [ $? -eq 2 ] && [ "$(cat "$KD/findes.sh")" = "findes" ]; check $? "K2 et symlink som udfil afvises og følges ikke"
  cp -R "$W" "$KD/src" 2>/dev/null || { mkdir -p "$KD/src"; cp "$W/build-xcframework.sh" "$KD/src/"; }
  scripts/build-whisper-macos.sh --generate "$KD/src" "$KD/src/build-xcframework.sh" >/dev/null 2>&1; R3=$?
  [ $R3 -eq 2 ] && cmp -s "$KD/src/build-xcframework.sh" "$W/build-xcframework.sh"; check $? "K2 ens input og output afvises, whisper.cpps eget script uændret"
  ls "${TMPDIR:-/tmp}"/diktat-whisper.* >/dev/null 2>&1; [ $? -ne 0 ]; check $? "K2 ingen midlertidige mapper ligger tilbage efter kørslerne"
  ! grep -E '^rm -rf build-(ios|visionos|tvos)' "$GEN"; check $? "K3 genereret script rydder ikke andre platformes buildmapper"
  grep -q '^rm -rf build-macos' "$GEN" && grep -q '^rm -rf build-apple' "$GEN"; check $? "K3 macOS-mapperne ryddes stadig (det er scriptets egne)"
  ( cd "$KD" && scripts_abs="$ROOT/scripts/build-whisper-macos.sh" && "$scripts_abs" --generate "src" "rel-ud.sh" >/dev/null 2>&1 ) && [ -x "$KD/rel-ud.sh" ]; check $? "K4 relative stier (kilde og udfil) virker fra en anden mappe"
else
  echo "SPRUNGET OVER C3-generering: whisper.cpp findes ikke i ~/VoiceInk-Dependencies"
fi
grep -q "build-whisper-macos.sh" Makefile && grep -q "xcrun --find metal" Makefile; check $? "C3 Makefile bygger kun macOS og tjekker Metal før bygningen"
grep -q "make check" OPSAETNING_PROMPT.txt && grep -q "SPØRG, før du kører den" OPSAETNING_PROMPT.txt; check $? "C3 opsætningsprompten tjekker Metal og spørger før download"

# ---- C4/C5: Homebrew og den valgte mappe ----
grep -q "GENOPTAGELSE efter samtykke" OPSAETNING_PROMPT.txt && grep -q "\[ -x /opt/homebrew/bin/brew \]" OPSAETNING_PROMPT.txt; check $? "C4 Homebrew tjekkes først, med PATH og genoptagelse"
LATER=$(sed -n '/^TRIN 5\./,$p' OPSAETNING_PROMPT.txt)
! echo "$LATER" | grep -q "~/diktat"; check $? "C5 efter Trin 4 bruges den valgte mappe, aldrig ~/diktat"
echo "$LATER" | grep -q "<DIKTAT_DIR>"; check $? "C5 den valgte mappe (<DIKTAT_DIR>) bruges i de senere trin"

# ---- C6: signering ----
! grep -q "DEVELOPMENT_TEAM = V" VoiceInk.xcodeproj/project.pbxproj && grep -q "Sign to Run Locally" BUILDING.md; check $? "C6 intet team-id i projektet, signering beskrevet i BUILDING.md"

# ---- S1 til S7: opsætningsprompten, README, BUILDING, Makefile ----
P=OPSAETNING_PROMPT.txt
grep -q "i Trin 3 er manglende værktøjer" $P && grep -q "ÉN ad gangen" $P && grep -q "command -v cmake" $P; check $? "S1 stopreglen undtager Trin 3, værktøjer tjekkes enkeltvis"
! grep -n "ls /opt/homebrew/bin/brew /usr/local/bin/brew" $P >/dev/null && grep -q '\[ -x /usr/local/bin/brew \]' $P; check $? "S1 Homebrew-stier tjekkes enkeltvis (ingen ls med flere stier)"
OUT=$(zsh -c 'command -v værktøj-findes-ikke-1; [ -x /findes/ikke/brew ] && echo ja; echo "slut"' 2>&1); [ "$OUT" = "slut" ]; check $? "S1 de enkelte tjek giver ingen fejlbesked, når værktøjet mangler"
[ "$(grep -c 'export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"' $P)" -ge 4 ]; check $? "S2 Homebrews PATH står i hver byggekommando i prompten (Trin 5 og 7)"
grep -q '^export PATH := /opt/homebrew/bin:/usr/local/bin' Makefile && grep -q 'command -v cmake' Makefile; check $? "S2 Makefile har Homebrews PATH og tjekker command -v cmake"
case "$(PATH=/usr/bin:/bin make envpath 2>/dev/null)" in /opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin) true;; *) false;; esac; check $? "S2 underprocesser får Homebrews mapper først i PATH, selv med et tomt skal-PATH"
grep -q "DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -downloadComponent MetalToolchain" README.md && grep -q "DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -downloadComponent MetalToolchain" BUILDING.md; check $? "S3 README og BUILDING henter Metal med samme DEVELOPER_DIR"
! grep -n "^ *xcodebuild -downloadComponent\|^    xcodebuild -downloadComponent\|: xcodebuild -downloadComponent" $P README.md BUILDING.md >/dev/null; check $? "S3 ingen Metal-hentning uden DEVELOPER_DIR i prompt, README og BUILDING"
grep -q "DIKTAT_CODESIGN_IDENTITY=- make local" $P && grep -q "DIKTAT_CODESIGN_IDENTITY=- make local" scripts/build-diktat.sh && grep -q "DIKTAT_CODESIGN_IDENTITY=- make local" README.md; check $? "S4 fortsættelse uden certifikat: DIKTAT_CODESIGN_IDENTITY=- make local"
grep -q "curl --fail --location" $P && grep -q "curl --fail --location" README.md && ! grep -n "curl -L" $P README.md >/dev/null; check $? "S5 curl --fail --location i prompt og README"
grep -q "574041195" $P && grep -q ".hentes" $P && grep -q "Tjek exitkoden" $P; check $? "S5 exitkode og størrelse tjekkes før kopiering"
grep -n -i "setup-signing.sh\" --remove" $P >/dev/null && awk '/Rækkefølge: FØRST certifikatet/{f=1} f{print}' $P | grep -q "SIDST repoet"; check $? "S7 afinstallation: certifikatet først med fuld sti, repoet sidst"
grep -q "SÆRSKILT ja" $P && grep -q "hent-modeller" scripts/transcribe/setup-diarization.sh; check $? "S6 stemmemodeller kræver særskilt samtykke"

# ---- P1, P2, P4: privatliv i koden ----
grep -q "prepareForNewContents(with: .currentHostOnly)" VoiceInk/Infrastructure/SystemIntegration/Paste/ClipboardManager.swift; check $? "P2 ClipboardManager skriver med .currentHostOnly (ikke Universal Clipboard)"
! grep -rn -E "pasteboard\.setString|NSPasteboard\.general\.(setString|setData|setPropertyList|writeObjects|declareTypes)" VoiceInk --include='*.swift' | grep -v "ClipboardManager.swift" >/dev/null; check $? "P2 ingen direkte skrivning til udklipsholderen uden om ClipboardManager"
! grep -rn "NSPasteboard.general.clearContents" VoiceInk --include='*.swift' >/dev/null; check $? "P2 ingen clearContents på den almindelige udklipsholder uden .currentHostOnly"
[ "$(grep -rln "clearContents()" VoiceInk --include='*.swift' | sort | tr '\n' ' ')" = "VoiceInk/Infrastructure/SystemIntegration/Accessibility/SelectedTextService.swift VoiceInk/Infrastructure/SystemIntegration/Paste/CursorPaster.swift " ]; check $? "P2 clearContents findes kun i de to gendannelser af brugerens egen udklipsholder"
grep -q "assistantSession.privacyKey == keyNow" VoiceInk/Features/Recording/Workflows/VoiceInkEngine+Assistant.swift && grep -q "assistantSession.reset()" VoiceInk/Features/Recording/Workflows/VoiceInkEngine+Assistant.swift; check $? "P1 opfølgning tjekker nøglen før kaldet og nulstiller samtalen ved ændring"
grep -q "privacyKey: self.currentAssistantPrivacyKey" VoiceInk/Features/Recording/Workflows/VoiceInkEngine.swift; check $? "P1 samtalen gemmer nøglen, da den startede"
grep -q "Prakash Joshi" Tests/VoiceInkUITests/VoiceInkUITests.swift && grep -q "Prakash Joshi" Tests/VoiceInkUITests/VoiceInkUITestsLaunchTests.swift; check $? "P4 forfatterkrediteringen til Prakash Joshi står i UI-testene"
grep -q 'os.environ\["PYANNOTE_METRICS_ENABLED"\] = "0"' scripts/transcribe/interview_transcribe.py && grep -q "PYANNOTE_METRICS_ENABLED" scripts/transcribe/requirements.txt; check $? "P3 pyannote-målinger slås fra i koden og er forklaret i requirements.txt"

# ---- C8: startvinduets modelkrav ----
T=$(mktemp -d)
cp scripts/tests/first_run_choice_test.swift "$T/main.swift"
swiftc -Onone -o "$T/t" "$T/main.swift" VoiceInk/Features/Onboarding/FirstRunModelChoice.swift 2>/dev/null && "$T/t" | sed 's/^/     /' | grep -v "^     OK"; [ "${pipestatus[1]:-0}" = 0 ]; check $? "C8 FirstRunModelChoice (Whisper tæller, Parakeet er valgfri)"
grep -q "disabled(!canFinish)" VoiceInk/Features/Onboarding/FirstRunView.swift && ! grep -q "disabled(!modelReady)" VoiceInk/Features/Onboarding/FirstRunView.swift; check $? "C8 Færdig-knappen afhænger af canFinish, ikke af Parakeet"

[ $FAILS -eq 0 ] && echo "ALLE TESTS BESTÅET" || echo "$FAILS FEJL"
exit $FAILS
