#!/bin/zsh
# Opretter et lokalt, selvsigneret kodesigneringscertifikat til Diktat i DIN egen nøglering.
#
# Hvorfor: macOS husker tilladelser (mikrofon, systemlyd, tilgængelighed) ud fra appens signatur.
# Uden fast signatur ("ad hoc") ændrer signaturen sig ved hver ny build, og macOS spørger igen.
# Med dette certifikat er signaturen den samme hver gang, så tilladelserne består.
#
# Certifikatet er dit eget. Det er ikke fra Apple, koster ingenting og gælder kun på din Mac.
# Privatnøglen skrives kort til en midlertidig mappe, lægges i nøgleringen og slettes igen.
# Intet sendes nogen steder.
#
# Brug:   scripts/setup-signing.sh            opretter certifikatet (spørger først), hvis det ikke findes
#         scripts/setup-signing.sh --ja       som ovenfor, men uden spørgsmål (til en agent, der selv har spurgt dig)
#         scripts/setup-signing.sh --check    viser kun, om det findes (exit 0 = findes, 1 = findes ikke, 5 = flere med samme navn)
#         scripts/setup-signing.sh --hash     skriver hashen på identiteten (samme exit-koder som --check)
#         scripts/setup-signing.sh --remove   sletter certifikatet igen (spørger først, --ja springer spørgsmålet over)
# Uden --ja og uden en terminal at svare i ændrer scriptet ingenting (exit 6).
# Miljø:  DIKTAT_KEYCHAIN=<sti>   brug en anden nøglering end login-nøgleringen (bruges af testen)
#         DIKTAT_CERT_NAME=<navn> andet navn end "Diktat Lokal Signering". Sammenlignes bogstaveligt, ikke som mønster.
#         DIKTAT_SECURITY=<sti>   anden `security` (bruges af testen)
# Exit 8: `security` fejlede (nøgleringen kunne ikke læses). Intet er ændret.
set -e
NAME="${DIKTAT_CERT_NAME:-Diktat Lokal Signering}"
KEYCHAIN="${DIKTAT_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
SECURITY="${DIKTAT_SECURITY:-security}"
ASSUME_YES=0
MODE=""
for arg in "$@"; do
  case "$arg" in
    --ja) ASSUME_YES=1 ;;
    --check|--hash|--remove) MODE="$arg" ;;
    *) echo "Ukendt valg: $arg" >&2; exit 2 ;;
  esac
done

# Alle hashes for identiteter, hvis navn er PRÆCIS $NAME (bogstavelig sammenligning, ingen mønstre).
# Uden -v, for en selvsigneret identitet regnes ikke som "valid".
find_hashes() {
  local out rc=0
  out=$("$SECURITY" find-identity -p codesigning "$KEYCHAIN" 2>&1) || rc=$?
  if (( rc != 0 )); then
    # Exitkoden tjekkes FØR udskriften læses. En fejlet `security` må ikke læses som "ingen certifikat".
    echo "FEJL: security find-identity fejlede (exit $rc) for $KEYCHAIN. Scriptet gætter ikke og ændrer intet." >&2
    printf '%s\n' "$out" | head -3 | sed 's/^/  /' >&2
    return 8
  fi
  printf '%s\n' "$out" \
    | awk -v n="$NAME" '{ if (match($0, /"[^"]*"/)) { if (substr($0, RSTART + 1, RLENGTH - 2) == n) print $2 } }'
}

# Sætter HASHES (linjer) og COUNT. Stopper med exit 8, hvis `security` fejlede.
lookup() {
  local rc=0
  HASHES=$(find_hashes) || rc=$?
  (( rc == 0 )) || exit 8
  COUNT=0
  if [[ -n "$HASHES" ]]; then COUNT=$(printf '%s\n' "$HASHES" | grep -c .); fi
}
ambiguous() {
  echo "FEJL: $COUNT identiteter hedder \"$NAME\" i $KEYCHAIN. Scriptet vælger ikke selv." >&2
  printf '%s\n' "$HASHES" | sed 's/^/  /' >&2
  echo "Slet de overflødige i Nøglering (Keychain Access), og prøv igen." >&2
  exit 5
}

confirm() {
  [[ "$ASSUME_YES" == 1 ]] && return 0
  if [[ ! -t 0 ]]; then
    echo "Kræver din bekræftelse: $1" >&2
    echo "Der er ingen terminal at svare i, så intet er ændret. Kør igen med --ja, når du vil gå videre." >&2
    exit 6
  fi
  local ans
  read -r "ans?$1 (j/N) "
  [[ "$ans" == (j|J|ja|Ja|JA|y|Y|yes) ]] || { echo "Afbrudt. Intet er ændret."; exit 6; }
}

case "$MODE" in
  --check)
    lookup
    (( COUNT > 1 )) && ambiguous
    if (( COUNT == 1 )); then echo "Certifikatet \"$NAME\" findes ($HASHES)."; exit 0; fi
    echo "Certifikatet \"$NAME\" findes ikke. Kør scripts/setup-signing.sh."; exit 1 ;;
  --hash)
    lookup
    (( COUNT > 1 )) && ambiguous
    (( COUNT == 1 )) || exit 1
    echo "$HASHES"; exit 0 ;;
  --remove)
    lookup
    (( COUNT > 1 )) && ambiguous
    if (( COUNT == 0 )); then echo "Intet certifikat at slette."; exit 0; fi
    confirm "Slet certifikatet \"$NAME\" ($HASHES) fra $KEYCHAIN? Appen får nye spørgsmål om tilladelser."
    "$SECURITY" delete-identity -Z "$HASHES" "$KEYCHAIN"
    echo "Slettet. Appen skal signeres igen og får nye spørgsmål om tilladelser."; exit 0 ;;
esac

if [[ ! -f "$KEYCHAIN" ]]; then
  echo "FEJL: Nøgleringen findes ikke: $KEYCHAIN" >&2
  echo "Åbn Nøglering (Keychain Access) én gang, eller byg uden certifikat (ad hoc, med advarsel)." >&2
  exit 3
fi

lookup
(( COUNT > 1 )) && ambiguous
if (( COUNT == 1 )); then
  echo "Certifikatet \"$NAME\" findes allerede ($HASHES). Intet at gøre."
  exit 0
fi

confirm "Opret certifikatet \"$NAME\" i nøgleringen $KEYCHAIN? macOS kan bede om din adgangskode."

OPENSSL=/usr/bin/openssl   # Apples egen, fordi Homebrews OpenSSL 3 laver pkcs12-filer, som security ikke kan læse
TMP=$(mktemp -d)
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT
PASS=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)

cat > "$TMP/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/openssl.cnf" 2>/dev/null
"$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/id.p12" -passout "pass:$PASS" 2>/dev/null

# -T giver codesign lov til at bruge nøglen uden at spørge hver gang.
"$SECURITY" import "$TMP/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
rm -f "$TMP/key.pem" "$TMP/id.p12"

lookup
H="$HASHES"
if (( COUNT != 1 )); then
  echo "FEJL: Certifikatet blev lagt i nøgleringen, men kunne ikke findes bagefter." >&2
  exit 4
fi
echo "Oprettet: \"$NAME\" ($H) i $KEYCHAIN"
echo "Gyldigt i ti år. Bygget bruger det automatisk (scripts/build-diktat.sh)."
echo "Første gang appen signeres, kan macOS bede om din Mac-adgangskode for nøglen. Vælg da \"Tillad altid\"."
echo "Slet det igen med: scripts/setup-signing.sh --remove"
