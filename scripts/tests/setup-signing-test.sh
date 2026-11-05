#!/bin/zsh
# Tester scripts/setup-signing.sh i en MIDLERTIDIG nøglering (rører ikke login-nøgleringen):
#  opretter certifikat, finder det, signerer to forskellige filer med det og kontrollerer at kravet (designated requirement)
#  er det samme (det er det, der gør at macOS beholder tilladelser), at det ikke oprettes to gange, og at --remove virker.
ROOT="${0:A:h:h:h}"
S="$ROOT/scripts/setup-signing.sh"
T=$(mktemp -d)
KC="$T/test.keychain-db"
FAILS=0
check() { if [ "$1" = "0" ]; then echo "OK   $2"; else echo "FEJL $2"; FAILS=$((FAILS+1)); fi; }
# codesign finder kun identiteter i nøgleringe på søgelisten. Testens nøglering lægges derfor på listen et øjeblik
# og fjernes igen, også ved fejl. Listen gemmes ordret og sættes tilbage ordret.
OLD=("${(@f)$(security list-keychains -d user | sed -e 's/^ *"//' -e 's/"$//')}")
BEFORE="${(j:|:)OLD}"
cleanup() {
  security list-keychains -d user -s "${OLD[@]}" >/dev/null 2>&1
  security delete-keychain "$KC" >/dev/null 2>&1
  rm -rf "$T"
}
trap cleanup EXIT
security create-keychain -p testpw "$KC" >/dev/null 2>&1; check $? "midlertidig nøglering oprettet"
security set-keychain-settings "$KC" >/dev/null 2>&1
security unlock-keychain -p testpw "$KC" >/dev/null 2>&1
export DIKTAT_KEYCHAIN="$KC"
mkdir -p "$T/tmp"

"$S" --check >/dev/null 2>&1; [ $? -eq 1 ]; check $? "--check: findes ikke før oprettelse (exit 1)"
OUT=$(TMPDIR="$T/tmp" "$S" --ja 2>&1); RC=$?
[ $RC -eq 0 ] && [[ "$OUT" == *"Oprettet"* ]]; check $? "opretter certifikatet (exit $RC)"
"$S" --check >/dev/null 2>&1; check $? "--check: findes efter oprettelse"
OUT2=$("$S" 2>&1); [[ "$OUT2" == *"findes allerede"* ]]; check $? "andet kald opretter ikke endnu et"
N=$(security find-identity -p codesigning "$KC" | grep -c "Diktat Lokal Signering")
[ "$N" = "1" ]; check $? "præcis én identitet i nøgleringen ($N)"
HASH=$(security find-identity -p codesigning "$KC" | awk '/Diktat Lokal Signering/ { print $2; exit }')
# Privatnøglen må ikke ligge tilbage i en midlertidig mappe
[ -z "$(ls -A "$T/tmp")" ]; check $? "ingen privatnøgle eller andre filer efterladt i scriptets midlertidige mappe"

security list-keychains -d user -s "${OLD[@]}" "$KC" >/dev/null 2>&1
# Signér to forskellige filer. Selv med timeout, så en uventet adgangsdialog ikke hænger testen.
cp /usr/bin/true "$T/a"; cp /usr/bin/false "$T/b"
sign_with_timeout() {
  python3 - "$@" <<'PY'
import subprocess, sys
f, ident, kc = sys.argv[1:4]
try:
    r = subprocess.run(["codesign", "--force", "--sign", ident, "--keychain", kc, "--timestamp=none", f], capture_output=True, text=True, timeout=45)
    sys.exit(r.returncode)
except subprocess.TimeoutExpired:
    print("TIMEOUT: codesign ventede på en adgangsdialog"); sys.exit(99)
PY
}
sign_with_timeout "$T/a" "$HASH" "$KC"; check $? "codesign med certifikatet virker uden dialog"
sign_with_timeout "$T/b" "$HASH" "$KC"; check $? "codesign af en anden fil virker"
RA=$(codesign -d -r- "$T/a" 2>&1 | grep -o 'certificate leaf.*'); RB=$(codesign -d -r- "$T/b" 2>&1 | grep -o 'certificate leaf.*')
[ -n "$RA" ] && [ "$RA" = "$RB" ]; check $? "samme certifikat-krav på to forskellige filer: $RA"
codesign --verify --strict "$T/a" 2>/dev/null; check $? "signaturen kan verificeres"

"$S" --remove --ja >/dev/null 2>&1; check $? "--remove --ja kører"
"$S" --check >/dev/null 2>&1; [ $? -eq 1 ]; check $? "--check: væk efter --remove"
cleanup; trap - EXIT
AFTER_ARR=("${(@f)$(security list-keychains -d user | sed -e 's/^ *"//' -e 's/"$//')}")
AFTER="${(j:|:)AFTER_ARR}"
[ "$BEFORE" = "$AFTER" ]; check $? "nøgleringslisten er som før testen"
[ $FAILS -eq 0 ] && echo "ALLE TESTS BESTÅET" || echo "$FAILS FEJL"
exit $FAILS
