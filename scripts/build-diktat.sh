#!/bin/zsh
# Bygger Diktat (lokal udgave) og signerer den.
#
# Brug:  scripts/build-diktat.sh
# Miljø: DIKTAT_CODESIGN_IDENTITY   "-" = ad hoc. Ellers navn eller hash på en identitet.
#                                   Uden værdi bruges "Diktat Lokal Signering" (scripts/setup-signing.sh), ellers ad hoc.
#        DIKTAT_KEYCHAIN            anden nøglering end login-nøgleringen
#        DEVELOPER_DIR              Xcode. Uden værdi: /Applications/Xcode.app, ellers det Xcode `xcode-select -p` peger på.
#                                   Eksporteres, så alle byggetrin (xcodebuild, xcrun, codesign) bruger samme Xcode.
#        DIKTAT_DERIVED_DATA        bygge-mappe, standard <repo>/.local-build
#
# Resultat: <bygge-mappe>/Build/Products/Release/Diktat.app. Appen STARTES ikke af dette script.
set -o pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  else
    DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || true)"
  fi
fi
export DEVELOPER_DIR
DERIVED="${DIKTAT_DERIVED_DATA:-$ROOT/.local-build}"
KEYCHAIN="${DIKTAT_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
CERT_NAME="${DIKTAT_CERT_NAME:-Diktat Lokal Signering}"
APP="$DERIVED/Build/Products/Release/Diktat.app"
ENT="$ROOT/VoiceInk/VoiceInk.local.entitlements"

if [[ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
  echo "FEJL: Xcode blev ikke fundet i $DEVELOPER_DIR. Installér Xcode (gratis med Apple-id) eller sæt DEVELOPER_DIR." >&2
  exit 3
fi
echo "Xcode: $DEVELOPER_DIR"
if ! "$DEVELOPER_DIR/usr/bin/xcodebuild" -version; then
  echo "FEJL: xcodebuild kan ikke køre. Åbn Xcode én gang og acceptér vilkårene, eller sæt DEVELOPER_DIR." >&2
  exit 3
fi
if [[ ! -d "$HOME/VoiceInk-Dependencies/whisper.cpp/build-apple/whisper.xcframework" ]]; then
  echo "FEJL: whisper.xcframework mangler. Kør først: make whisper (kræver git og cmake)." >&2
  exit 3
fi

# 1. Hvilken signatur?
IDENTITY="${DIKTAT_CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  # Navnet sammenlignes bogstaveligt. Flere identiteter med samme navn stopper bygningen, i stedet for at gætte.
  IDENTITY=$(DIKTAT_KEYCHAIN="$KEYCHAIN" DIKTAT_CERT_NAME="$CERT_NAME" "$ROOT/scripts/setup-signing.sh" --hash)
  rc=$?
  [[ $rc -eq 5 ]] && exit 7
  # Nøgleringen kunne ikke læses: byg ikke i stilhed ad hoc. Brugeren vælger (DIKTAT_CODESIGN_IDENTITY=- for ad hoc).
  [[ $rc -eq 8 ]] && exit 8
fi
if [[ -z "$IDENTITY" || "$IDENTITY" == "-" ]]; then
  IDENTITY="-"
  echo "ADVARSEL: Appen signeres 'ad hoc'. Signaturen ændrer sig ved hver build, så macOS spørger igen om" >&2
  echo "          mikrofon, systemlyd og tilgængelighed efter hver ny build. Kør scripts/setup-signing.sh én gang" >&2
  echo "          for et fast lokalt certifikat, og byg igen. Vil du bygge uden certifikat med vilje, så skriv" >&2
  echo "          DIKTAT_CODESIGN_IDENTITY=- make local (eller scripts/build-diktat.sh med samme variabel)." >&2
else
  echo "Signerer med identitet: $IDENTITY"
fi

# 2. Byg. Altid først ad hoc (det er den måde, der er prøvet), derefter signeres indefra og ud.
xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Release \
  -derivedDataPath "$DERIVED" \
  -xcconfig LocalBuild.xcconfig \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  DEVELOPMENT_TEAM="" \
  CODE_SIGN_ENTITLEMENTS="$ENT" \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) LOCAL_BUILD' \
  STRING_CATALOG_GENERATE_SYMBOLS=NO \
  -skipPackagePluginValidation -skipMacroValidation build
STATUS=$?

# Xcode registrerer bygget i LaunchServices. Fjern den ekstra registrering, så macOS ikke åbner
# bygge-kopien i stedet for den installerede app (fx ved klik på et link eller en notifikation).
LSR=/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister
"$LSR" -u "$APP" >/dev/null 2>&1

if [[ $STATUS -ne 0 || ! -d "$APP" ]]; then
  echo "FEJL: Bygget fejlede (kode $STATUS). Læs fejlen ovenfor. Mangler en Metal-komponent, kør: xcodebuild -downloadComponent MetalToolchain" >&2
  exit ${STATUS:-1}
fi

# 3. Signér indefra og ud med den faste identitet. Entitlements og hardened runtime bevares.
if [[ "$IDENTITY" != "-" ]]; then
  KC=()
  [[ -n "${DIKTAT_KEYCHAIN:-}" ]] && KC=(--keychain "$KEYCHAIN")
  sign() { codesign --force --sign "$IDENTITY" "${KC[@]}" --timestamp=none --options runtime "$@"; }
  # Dybeste først: dylibs, frameworks, XPC-tjenester, derefter appen selv.
  while IFS= read -r item; do
    sign --preserve-metadata=entitlements,flags "$item" || { echo "FEJL: kunne ikke signere $item" >&2; exit 4; }
  done < <(find "$APP/Contents" \( -name "*.dylib" -o -name "*.framework" -o -name "*.xpc" \) -print | awk '{ print length($0) " " $0 }' | sort -rn | cut -d' ' -f2-)
  sign --entitlements "$ENT" "$APP" || { echo "FEJL: kunne ikke signere appen" >&2; exit 4; }
fi

# 4. Kontrol
if codesign --verify --deep --strict "$APP" 2>&1; then
  echo "Signaturen er i orden."
else
  echo "FEJL: signaturen består ikke kontrollen." >&2
  exit 5
fi
echo "Krav: $(codesign -d -r- "$APP" 2>&1 | grep designated || true)"
echo
echo "Færdig: $APP"
echo "Læg appen i ~/Applications (fx: ditto \"$APP\" ~/Applications/Diktat.app) og åbn den derfra."
exit 0
