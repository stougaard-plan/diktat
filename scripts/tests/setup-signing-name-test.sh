#!/bin/zsh
# D4 og C7: setup-signing.sh sammenligner certifikatnavnet BOGSTAVELIGT (ikke som regulært udtryk), afviser flertydige navne
# og ændrer ikke noget uden bekræftelse. Bruger en falsk `security` først i PATH. Rører ingen rigtig nøglering og intet certifikat.
ROOT="${0:A:h:h:h}"
S="$ROOT/scripts/setup-signing.sh"
T=$(mktemp -d)
FAILS=0
check() { if [ "$1" = "0" ]; then echo "OK   $2"; else echo "FEJL $2"; FAILS=$((FAILS+1)); fi; }
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
LOG="$T/calls.log"
cat > "$T/bin/security" <<SH
#!/bin/sh
case "\$1" in
  find-identity) if [ -f "$T/fail" ]; then echo "security: SecKeychainSearchCreateFromAttributes: The specified keychain could not be found." >&2; exit 44; fi; cat "\$FIXTURE" ;;
  *) echo "\$@" >> "$LOG" ;;
esac
SH
chmod +x "$T/bin/security"
touch "$T/fake.keychain-db"
export PATH="$T/bin:$PATH" DIKTAT_KEYCHAIN="$T/fake.keychain-db"

fixture() { printf '%s\n' "$@" > "$T/fixture.txt"; export FIXTURE="$T/fixture.txt"; : > "$LOG"; }
A=AAAA1111AAAA1111AAAA1111AAAA1111AAAA1111; B=BBBB2222BBBB2222BBBB2222BBBB2222BBBB2222; C=CCCC3333CCCC3333CCCC3333CCCC3333CCCC3333

# 1. Punktum i navnet er et punktum, ikke «et vilkårligt tegn»
fixture "  1) $B \"Diktat Lokal Signering\"" "     1 identities found"
DIKTAT_CERT_NAME='Diktat Lokal.Signering' "$S" --check >/dev/null 2>&1; [ $? -eq 1 ]; check $? "D4 punktum: «Diktat Lokal.Signering» matcher ikke «Diktat Lokal Signering» (exit 1)"
# 2. Parenteser er parenteser
fixture "  1) $A \"Diktat A\"" "  2) $B \"Diktat (A)\"" "     2 identities found"
OUT=$(DIKTAT_CERT_NAME='Diktat (A)' "$S" --hash 2>&1); RC=$?
[ $RC -eq 0 ] && [ "$OUT" = "$B" ]; check $? "D4 parenteser: «Diktat (A)» giver sin egen hash, ikke «Diktat A» ($OUT, exit $RC)"
# 3. Et mønster som navn matcher ikke alt
fixture "  1) $A \"Et eller andet\"" "  2) $B \"Noget andet\"" "     2 identities found"
DIKTAT_CERT_NAME='.*' "$S" --check >/dev/null 2>&1; [ $? -eq 1 ]; check $? "D4 mønster: navnet «.*» matcher ikke alt (exit 1)"
# 4. Delvist navn og navn med ekstra tekst matcher ikke
fixture "  1) $A \"Diktat Lokal Signering Gammel\"" "  2) $C \"Anden Diktat Lokal Signering\"" "     2 identities found"
"$S" --check >/dev/null 2>&1; [ $? -eq 1 ]; check $? "D4 delvist navn: kun et præcist navn tæller (exit 1)"
# 5. Præcis ét match blandt flere ligner-navne
fixture "  1) $A \"Diktat Lokal Signering Gammel\"" "  2) $B \"Diktat Lokal Signering\"" "  3) $C \"Anden Diktat Lokal Signering\"" "     3 identities found"
OUT=$("$S" --hash 2>&1); RC=$?
[ $RC -eq 0 ] && [ "$OUT" = "$B" ]; check $? "D4 præcist match: kun den præcise identitet vælges ($OUT)"
# 6. Flertydigt: to identiteter med præcis samme navn
fixture "  1) $A \"Diktat Lokal Signering\"" "  2) $B \"Diktat Lokal Signering\"" "     2 identities found"
OUT=$("$S" --hash 2>&1); RC=$?
[ $RC -eq 5 ] && [[ "$OUT" == *"2 identiteter"* ]]; check $? "D4 flertydigt: --hash afviser (exit $RC)"
"$S" --check >/dev/null 2>&1; [ $? -eq 5 ]; check $? "D4 flertydigt: --check afviser (exit 5)"
"$S" --remove --ja >/dev/null 2>&1; RC=$?
[ $RC -eq 5 ] && ! grep -q delete-identity "$LOG"; check $? "D4 flertydigt: --remove sletter intet (exit $RC)"
"$S" --ja >/dev/null 2>&1; RC=$?
[ $RC -eq 5 ] && ! grep -q import "$LOG"; check $? "D4 flertydigt: opretter ikke et tredje certifikat (exit $RC)"
# 7. Sletter præcis den fundne hash og intet andet
fixture "  1) $A \"Diktat Lokal Signering Gammel\"" "  2) $B \"Diktat Lokal Signering\"" "     2 identities found"
"$S" --remove --ja >/dev/null 2>&1; RC=$?
[ $RC -eq 0 ] && grep -q "delete-identity -Z $B" "$LOG" && ! grep -q "$A" "$LOG"; check $? "D4 --remove sletter præcis den ene hash (exit $RC)"
# 8. C7: uden --ja og uden terminal ændres intet
fixture "  1) $B \"Diktat Lokal Signering\"" "     1 identities found"
"$S" --remove </dev/null >/dev/null 2>&1; RC=$?
[ $RC -eq 6 ] && ! grep -q delete-identity "$LOG"; check $? "C7 --remove uden --ja: intet slettet (exit $RC)"
fixture "     0 identities found"
"$S" </dev/null >/dev/null 2>&1; RC=$?
[ $RC -eq 6 ] && ! grep -q import "$LOG"; check $? "C7 oprettelse uden --ja: intet oprettet (exit $RC)"
OUT=$("$S" </dev/null 2>&1); [[ "$OUT" == *"--ja"* ]]; check $? "C7 beskeden siger, hvad man skal gøre (--ja)"
# 9. --check og --hash ændrer aldrig noget og spørger ikke
fixture "  1) $B \"Diktat Lokal Signering\"" "     1 identities found"
"$S" --check </dev/null >/dev/null 2>&1; check $? "--check spørger ikke og finder certifikatet"
[ ! -s "$LOG" ]; check $? "--check/--hash kalder kun find-identity"
# 10. K6: en fejlet `security` læses ikke som «intet certifikat». Exitkoden tjekkes først, scriptet stopper med exit 8.
fixture "  1) $B \"Diktat Lokal Signering\"" "     1 identities found"
touch "$T/fail"
for m in --check --hash; do
  OUT=$("$S" $m </dev/null 2>&1); RC=$?
  [ $RC -eq 8 ] && [[ "$OUT" == *"fejlede (exit 44)"* ]]; check $? "K6 $m: security fejler, så scriptet stopper med exit 8 og siger hvorfor ($RC)"
done
: > "$LOG"
"$S" --remove --ja </dev/null >/dev/null 2>&1; RC=$?
[ $RC -eq 8 ] && ! grep -q delete-identity "$LOG"; check $? "K6 --remove --ja: fejlet security, intet slettet (exit $RC)"
"$S" --ja </dev/null >/dev/null 2>&1; RC=$?
[ $RC -eq 8 ] && ! grep -q import "$LOG"; check $? "K6 oprettelse --ja: fejlet security, intet oprettet (exit $RC)"
rm -f "$T/fail"
[ $FAILS -eq 0 ] && echo "ALLE TESTS BESTÅET" || echo "$FAILS FEJL"
exit $FAILS
