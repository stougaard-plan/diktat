#!/bin/zsh
# Opretter et Python-miljø til VALGFRI talerseparation i ~/.diktat/venv.
# Spørger FØR det ændrer noget. Henter flere GB (torch m.fl.) fra PyPI.
# Brug: scripts/transcribe/setup-diarization.sh [--ja] [--hent-modeller] [sti-til-python3.12]
#   --ja springer spørgsmålet om miljøet over (til en agent, der selv har spurgt dig). Uden --ja og uden en terminal
#   at svare i ændres intet (exit 6).
#   --hent-modeller er et SÆRSKILT samtykke til at hente stemmemodellerne fra huggingface.co (kræver HF_TOKEN og
#   accepterede licenser). Uden det hentes der intet, og møde- og interviewscripts henter heller ikke selv.
set -e
HERE="${0:A:h}"
VENV="${DIKTAT_VENV:-$HOME/.diktat/venv}"
ASSUME_YES=0
GET_MODELS=0
ARGS=()
for arg in "$@"; do
  if [[ "$arg" == "--ja" ]]; then ASSUME_YES=1
  elif [[ "$arg" == "--hent-modeller" ]]; then GET_MODELS=1
  else ARGS+=("$arg"); fi
done
PY="${ARGS[1]:-$(command -v python3.12 || true)}"
if [[ -z "$PY" ]]; then
  echo "FEJL: Python 3.12 blev ikke fundet. Installér med: brew install python@3.12" >&2
  echo "Talerseparation er valgfri. Notetakeren virker uden." >&2
  exit 3
fi
echo "Python: $PY ($("$PY" --version))"
echo "Miljø:  $VENV"
if [[ "$ASSUME_YES" != 1 ]]; then
  if [[ ! -t 0 ]]; then
    echo "Kræver din bekræftelse: opret miljøet $VENV og hent flere GB fra PyPI." >&2
    echo "Der er ingen terminal at svare i, så intet er ændret. Kør igen med --ja, når du vil gå videre." >&2
    exit 6
  fi
  read -r "ans?Opret miljøet $VENV og hent flere GB fra PyPI? (j/N) "
  [[ "$ans" == (j|J|ja|Ja|JA|y|Y|yes) ]] || { echo "Afbrudt. Intet er ændret."; exit 6; }
fi
mkdir -p "$(dirname "$VENV")"
"$PY" -m venv "$VENV"
"$VENV/bin/python" -m pip install --upgrade pip
"$VENV/bin/python" -m pip install -r "$HERE/requirements.txt"
echo
if [[ "$GET_MODELS" != 1 && -t 0 && -n "${HF_TOKEN:-}" ]]; then
  read -r "ans?Hent også stemmemodellerne fra huggingface.co nu (flere hundrede MB, bruger HF_TOKEN)? (j/N) "
  [[ "$ans" == (j|J|ja|Ja|JA|y|Y|yes) ]] && GET_MODELS=1
fi
if [[ "$GET_MODELS" == 1 ]]; then
  PYANNOTE_METRICS_ENABLED=0 "$VENV/bin/python" "$HERE/hent_stemmemodeller.py"
  echo "Færdig. Miljø og stemmemodeller er på plads."
else
  echo "Færdig. Stemmemodellerne er IKKE hentet. Sæt HF_TOKEN (se scripts/transcribe/README.md) og kør"
  echo "scripts/transcribe/setup-diarization.sh --hent-modeller, når du vil have dem. Før det kører ingen stemmeopdeling."
fi
