#!/usr/bin/env python3
"""Henter stemmemodellerne til talerseparation (pyannote) fra huggingface.co, én gang, med brugerens samtykke.

Kaldes af setup-diarization.sh --hent-modeller i miljøet fra setup-diarization.sh. Kræver HF_TOKEN og at licenserne
er accepteret på huggingface.co. Efter hentningen kører møde- og interviewscripts uden net til modellerne."""
import os
import sys
from pathlib import Path

os.environ["PYANNOTE_METRICS_ENABLED"] = "0"   # ingen målinger til pyannote.ai
os.environ["DIKTAT_TILLAD_MODELHENTNING"] = "1"
os.environ.pop("HF_HUB_OFFLINE", None)
sys.path.insert(0, str(Path(__file__).resolve().parent))

import interview_transcribe as it  # noqa: E402


def main() -> int:
    token = os.environ.get("HF_TOKEN", "").strip()
    if not token:
        print("FEJL: HF_TOKEN er ikke sat. Se scripts/transcribe/README.md.", file=sys.stderr)
        return 3
    from pyannote.audio import Pipeline
    print(f"Henter {it.DIARIZATION_MODEL} (og de modeller, den trækker ind) fra huggingface.co ...", file=sys.stderr)
    Pipeline.from_pretrained(it.DIARIZATION_MODEL, token=token)
    print("Modellerne ligger nu i cachen. Scripts henter dem ikke igen.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
