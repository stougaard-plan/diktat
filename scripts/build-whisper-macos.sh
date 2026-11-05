#!/bin/zsh
# Bygger whisper.xcframework KUN til macOS. whisper.cpps eget build-xcframework.sh bygger også iOS, tvOS og visionOS,
# og dem skal Diktat ikke bruge. I Xcode 26 er de platforme ikke altid hentet, og bygningen fejler da midt i forløbet.
#
# Scriptet tager whisper.cpps eget script, fjerner trinene til de andre platforme og kører resten. Det virker kun
# på præcis den version, Makefile låser til (kontrolleres med en tjekssum). Ved en anden version stopper det.
#
# Brug:  scripts/build-whisper-macos.sh <sti til whisper.cpp>          (genererer og kører)
#        scripts/build-whisper-macos.sh --generate <sti> <udfil>       (genererer kun, til test)
# Kræver: Xcode (DEVELOPER_DIR), cmake, macOS-SDK og Metal-komponenten. Hentes intet af dette script.
set -e
EXPECTED_SHA256="da19bce95895d70352a4a82c44e02d87e4939a66cf47352f5b735bc9f77174fd"   # build-xcframework.sh i whisper.cpp 482279b8

GENERATE_ONLY=0
if [[ "${1:-}" == "--generate" ]]; then GENERATE_ONLY=1; shift; fi
SRC_ARG="${1:?Brug: build-whisper-macos.sh <sti til whisper.cpp>}"
OUT_ARG="${2:-}"
# Alle stier gøres absolutte FØR der skiftes mappe (scriptet cd'er til whisper.cpp under bygningen).
SRC="${SRC_ARG:A}"
ORIGINAL="$SRC/build-xcframework.sh"
[[ -f "$ORIGINAL" ]] || { echo "FEJL: $ORIGINAL findes ikke." >&2; exit 3; }

# Udfilen (kun ved --generate): må ikke findes i forvejen, ikke være et symlink og ikke være whisper.cpps eget script.
if (( GENERATE_ONLY )); then
  [[ -n "$OUT_ARG" ]] || { echo "FEJL: --generate kræver en udfil." >&2; exit 2; }
  if [[ -e "$OUT_ARG" || -L "$OUT_ARG" ]]; then
    echo "FEJL: $OUT_ARG findes allerede (fil eller symlink). Scriptet overskriver ingenting. Vælg en ny sti." >&2
    exit 2
  fi
  OUT="${OUT_ARG:A}"
  if [[ "$OUT" == "${ORIGINAL:A}" ]]; then
    echo "FEJL: udfilen er det samme som whisper.cpps eget build-xcframework.sh. Det overskrives aldrig." >&2
    exit 2
  fi
  [[ -d "${OUT:h}" ]] || { echo "FEJL: mappen ${OUT:h} findes ikke." >&2; exit 2; }
fi

ACTUAL=$(shasum -a 256 "$ORIGINAL" | awk '{ print $1 }')
if [[ "$ACTUAL" != "$EXPECTED_SHA256" ]]; then
  echo "FEJL: build-xcframework.sh er ikke den version, dette script er lavet til." >&2
  echo "      Forventet $EXPECTED_SHA256" >&2
  echo "      Fundet    $ACTUAL" >&2
  echo "      Brug Makefilens version af whisper.cpp (WHISPER_CPP_REF) eller byg i hånden." >&2
  exit 3
fi

# 1. Generér til en midlertidig fil (ny, tom mappe). Droppet: trinene til iOS, visionOS og tvOS (et trin starter med
#    echo "Building for ..." og slutter med "cmake --build") og oprydningen af DERES buildmapper (rm -rf build-ios-* osv.).
#    Andre platformes mapper hører ikke til dette script og røres ikke.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/diktat-whisper.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
GEN="$WORK/build-xcframework-macos.sh"
awk '
  /^echo "Building for / { skip = ($0 !~ /macOS/) }
  skip { if ($0 ~ /^cmake --build /) skip = 0; next }
  { print }
' "$ORIGINAL" \
  | sed -E \
      -e '/^rm -rf build-(ios|visionos|tvos)/d' \
      -e '/^setup_framework_structure "build-(ios|visionos|tvos)/d' \
      -e '/^combine_static_libraries "build-(ios|visionos|tvos)/d' \
      -e '/^ *-framework .*build-(ios|visionos|tvos)/d' \
      -e '/^ *-debug-symbols .*build-(ios|visionos|tvos)/d' \
  > "$GEN"
chmod +x "$GEN"

if (( GENERATE_ONLY )); then
  # mv -n overskriver aldrig, selv hvis en fil dukkede op siden tjekket.
  mv -n "$GEN" "$OUT"
  [[ -f "$OUT" && ! -e "$GEN" ]] || { echo "FEJL: $OUT blev ikke skrevet." >&2; exit 2; }
  echo "Genereret: $OUT"
  exit 0
fi

# 2. Tjek det, bygningen skal bruge, FØR den starter.
command -v cmake >/dev/null || { echo "FEJL: cmake ikke fundet i PATH. Installér med: brew install cmake (Homebrews mapper /opt/homebrew/bin og /usr/local/bin skal være i PATH)." >&2; exit 3; }
xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1 || { echo "FEJL: macOS-SDK mangler i Xcode." >&2; exit 3; }
if ! xcrun --find metal >/dev/null 2>&1; then
  echo "FEJL: Metal-komponenten mangler. Den hentes med samme Xcode som bygningen:" >&2
  echo "      DEVELOPER_DIR=\"${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}\" xcodebuild -downloadComponent MetalToolchain (ca. 700 MB)." >&2
  echo "      Det gøres ikke automatisk. Kør kommandoen selv, og kør derefter make whisper igen." >&2
  exit 3
fi

# 3. Byg. (Fra en midlertidig fil. Intet nyt ligger tilbage i whisper.cpp-mappen.)
cd "$SRC"
echo "Bygger whisper.xcframework til macOS (kun macOS)."
bash "$GEN"
[[ -d "$SRC/build-apple/whisper.xcframework" ]] || { echo "FEJL: whisper.xcframework blev ikke lavet." >&2; exit 4; }
echo "Færdig: $SRC/build-apple/whisper.xcframework"
