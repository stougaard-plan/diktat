#!/usr/bin/env python3
"""Lokal transskription af en lydfil med whisper.cpp og (valgfrit) talerseparation med pyannote.

Bruges af Diktats notetaker via `moede_transcribe.py`. Kan også køres alene.
Alt kører lokalt. Der sendes ingen lyd eller tekst nogen steder.
Eneste netværk: pyannote henter sine modeller fra Hugging Face første gang, og kun hvis du slår talerseparation til.

Pipeline:
  1. ffmpeg laver lydfilen om til 16 kHz mono WAV.
  2. (kun --mode talere) pyannote/speaker-diarization-3.1 finder ud af, hvem der taler hvornår.
  3. whisper.cpp (whisper-cli, lokalt, dansk som standard, -bs 1 -mc 0 -sns) laver tekst med tider.
  4. (kun --mode talere) Hvert tekststykke får den taler, der overlapper mest i tid.
  5. Resultatet skrives som tekst: [00:00:12] Taler 1: ...

Miljøvariabler:
  HF_TOKEN               Kun til --mode talere. Et Hugging Face-token, hvor du har accepteret licensen for
                         pyannote/speaker-diarization-3.1, pyannote/segmentation-3.0 og
                         pyannote/speaker-diarization-community-1. Gemmes aldrig i en fil af dette script.
  DIKTAT_WHISPER_MODELS  Mappe med ggml-<model>.bin (standard ~/.whisper-models).

Krav på maskinen:
  whisper-cli   brew install whisper-cpp
  ffmpeg        brew install ffmpeg
  modelfil      se scripts/transcribe/README.md
  pyannote      kun til talerseparation, se requirements.txt

Brug:
  python3 interview_transcribe.py <lydfil> [--output <mappe>] [--mode tekst|talere] [--model large-v3-turbo-q5_0]
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import time
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

# ── Konstanter ──────────────────────────────────────────────────────────────

WHISPER_CLI_BIN = "whisper-cli"
WHISPER_MODEL_DIR = Path(os.environ.get("DIKTAT_WHISPER_MODELS", "~/.whisper-models")).expanduser()
WHISPER_MODEL_PATH = WHISPER_MODEL_DIR / "ggml-large-v3-turbo-q5_0.bin"  # sættes af --model
WHISPER_LANG = "da"
DIARIZATION_MODEL = "pyannote/speaker-diarization-3.1"

SRT_TIME_RE = re.compile(
    r"(\d{2}):(\d{2}):(\d{2}),(\d{3})\s*-->\s*(\d{2}):(\d{2}):(\d{2}),(\d{3})"
)


def fail(msg: str) -> None:
    print(f"FEJL: {msg}", file=sys.stderr)
    sys.exit(1)


def check_env() -> str:
    """Tjek at HF_TOKEN er sat (til diarization). Fail tydeligt hvis ikke.

    Kræver IKKE længere nogen cloud-transskriptionsnøgle — hele pipelinen
    er lokal siden 1/9-2026."""
    hf_token = os.environ.get("HF_TOKEN", "").strip()
    if not hf_token:
        fail(
            "Mangler miljøvariabel HF_TOKEN (Hugging Face-token, kun til talerseparation. Sæt den i terminalen med "
            "`export HF_TOKEN=<token>`, eller brug --mode tekst uden talerseparation. "
            "Kræver accepteret licens for pyannote/speaker-diarization-3.1, "
            "pyannote/segmentation-3.0 OG pyannote/speaker-diarization-community-1 "
            "på huggingface.co — den tredje trækkes ind af pipelinen uden at stå "
            "på modelkortet)"
        )
    return hf_token


def check_ffmpeg() -> None:
    try:
        subprocess.run(["ffmpeg", "-version"], capture_output=True, check=True)
    except (subprocess.CalledProcessError, FileNotFoundError):
        fail("ffmpeg blev ikke fundet. Installér med `brew install ffmpeg`.")


def check_whisper_cli() -> None:
    """Tjek at whisper-cli og modelfilen findes, med en fejlbesked der viser
    præcis hvad der mangler og hvordan det installeres/hentes."""
    if shutil.which(WHISPER_CLI_BIN) is None:
        fail(
            f"'{WHISPER_CLI_BIN}' blev ikke fundet i PATH. Installér med "
            "`brew install whisper-cpp`."
        )
    if not WHISPER_MODEL_PATH.exists():
        fail(
            f"Whisper-modellen mangler: {WHISPER_MODEL_PATH}\n"
            "Hent den med:\n"
            "  mkdir -p ~/.whisper-models\n"
            f"  curl -L -o {WHISPER_MODEL_PATH} \\\n"
            f"    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/{WHISPER_MODEL_PATH.name}"
        )


# ── Trin 1: konvertér til 16kHz mono WAV ────────────────────────────────────


def convert_to_wav(input_path: Path, work_dir: Path) -> Path:
    """Konvertér input til 16kHz mono WAV via ffmpeg (samme mønster som
    video-transscribe-skillen). Springer over hvis input allerede er et
    16kHz mono WAV — men for enkelhedens skyld konverterer vi altid, det
    er billigt i tid sammenlignet med diarization + transskription."""
    out_path = work_dir / "audio_16k_mono.wav"
    cmd = [
        "ffmpeg", "-y", "-i", str(input_path),
        "-vn", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le",
        str(out_path),
    ]
    result = subprocess.run(cmd, capture_output=True)
    if result.returncode != 0:
        fail(f"ffmpeg-konvertering fejlede:\n{result.stderr.decode(errors='replace')[:2000]}")
    return out_path


# ── Trin 2: diarization (pyannote.audio, lokalt) ────────────────────────────


@dataclass
class DiarizationSegment:
    start: float
    end: float
    speaker: str  # "SPEAKER_00" osv. fra pyannote


def run_diarization(
    wav_path: Path, hf_token: str, num_speakers: Optional[int] = None
) -> list[DiarizationSegment]:
    """Kør pyannote/speaker-diarization-3.1 lokalt på WAV-filen.

    num_speakers: sættes eksplicit hvis antal talere kendes på forhånd —
    pyannote's pipeline understøtter dette og det giver typisk bedre
    resultat end automatisk detektion, især ved 2 talere der ligner
    hinanden stemmemæssigt.
    """
    # pyannote.audio 4.x sender som standard målinger til otel.pyannote.ai (varighed af lydfiler m.m.). Slås fra FØR
    # pakken importeres, for den læser variablen ved import. Altid fra, også hvis miljøet siger andet.
    os.environ["PYANNOTE_METRICS_ENABLED"] = "0"
    # Modeller hentes kun, når brugeren særskilt har sagt ja (setup-diarization.sh sætter DIKTAT_TILLAD_MODELHENTNING).
    # Ellers må pakken slet ikke bruge nettet, og modellerne skal ligge i cachen i forvejen.
    if os.environ.get("DIKTAT_TILLAD_MODELHENTNING") != "1":
        os.environ["HF_HUB_OFFLINE"] = "1"
    try:
        from pyannote.audio import Pipeline
    except ImportError:
        fail(
            "pyannote.audio er ikke installeret i denne Python. Se scripts/transcribe/README.md "
            "(requirements.txt og setup-diarization.sh), eller brug --mode tekst."
        )

    print(f"Indlæser diarization-pipeline ({DIARIZATION_MODEL})...", file=sys.stderr)
    try:
        pipeline = Pipeline.from_pretrained(DIARIZATION_MODEL, token=hf_token)
    except Exception as e:  # noqa: BLE001
        if os.environ.get("DIKTAT_TILLAD_MODELHENTNING") != "1":
            fail(
                "Stemmemodellerne er ikke hentet til denne maskine, og scriptet henter dem ikke af sig selv. "
                "Kør scripts/transcribe/setup-diarization.sh --hent-modeller (kræver HF_TOKEN og accepterede licenser), "
                f"eller brug --mode tekst. Detalje: {e}"
            )
        fail(
            f"Kunne ikke hente diarization-modellen fra HuggingFace: {e}\n"
            "Tjek at HF_TOKEN er gyldig, og at licensen for "
            "pyannote/speaker-diarization-3.1, pyannote/segmentation-3.0 OG "
            "pyannote/speaker-diarization-community-1 er accepteret på "
            "huggingface.co med samme konto som tokenet (den tredje repo "
            "trækkes ind af pipelinen uden at stå på modelkortet, obs. 225)."
        )

    # Brug GPU/MPS hvis tilgængeligt, ellers CPU.
    try:
        import torch

        if torch.backends.mps.is_available():
            pipeline.to(torch.device("mps"))
            print("Kører diarization på Apple Silicon MPS.", file=sys.stderr)
        else:
            print("Kører diarization på CPU (ingen MPS tilgængelig).", file=sys.stderr)
    except Exception:  # noqa: BLE001
        pass  # falder tilbage til CPU-default uden at fejle

    kwargs = {}
    if num_speakers:
        kwargs["num_speakers"] = num_speakers

    print("Kører diarization — dette kan tage flere minutter for lange filer...", file=sys.stderr)
    output = pipeline(str(wav_path), **kwargs)
    # pyannote.audio >= 4.0 wraps the Annotation in a DiarizeOutput dataclass
    diarization = getattr(output, "speaker_diarization", output)

    segments: list[DiarizationSegment] = []
    for turn, _, speaker in diarization.itertracks(yield_label=True):
        segments.append(DiarizationSegment(start=turn.start, end=turn.end, speaker=speaker))
    if not segments:
        fail("Diarization returnerede ingen talersegmenter — tjek lydfilens indhold.")
    return segments


# ── Trin 3: transskription (whisper.cpp, lokalt) ────────────────────────────


@dataclass
class WhisperSegment:
    start: float
    end: float
    text: str


def _srt_timestamp_to_seconds(h: str, m: str, s: str, ms: str) -> float:
    return int(h) * 3600 + int(m) * 60 + int(s) + int(ms) / 1000.0


def parse_srt(srt_text: str) -> list[WhisperSegment]:
    """Parse SRT-tekst til en liste af WhisperSegment (start, end, text).

    SRT-blokke ser sådan ud:
        1
        00:00:00,000 --> 00:00:04,320
        Så velkommen til...

        2
        00:00:04,320 --> 00:00:08,100
        Tak fordi jeg må være med...

    Flerlinjede tekstblokke samles til én linje med mellemrum. Tomme
    blokke (ingen tekst) springes over."""
    segments: list[WhisperSegment] = []
    blocks = re.split(r"\r?\n\r?\n+", srt_text.strip())
    for block in blocks:
        lines = [line for line in block.splitlines() if line.strip() != ""]
        if not lines:
            continue
        # Find tidslinjen — normalt linje 2 (efter indeksnummeret), men vær
        # robust hvis indeksnummeret mangler.
        time_line_idx = None
        for i, line in enumerate(lines):
            if SRT_TIME_RE.search(line):
                time_line_idx = i
                break
        if time_line_idx is None:
            continue
        match = SRT_TIME_RE.search(lines[time_line_idx])
        if not match:
            continue
        start = _srt_timestamp_to_seconds(*match.groups()[0:4])
        end = _srt_timestamp_to_seconds(*match.groups()[4:8])
        text = " ".join(lines[time_line_idx + 1:]).strip()
        if text:
            segments.append(WhisperSegment(start=start, end=end, text=text))
    return segments


def run_transcription(wav_path: Path, work_dir: Path) -> list[WhisperSegment]:
    """Kør whisper.cpp (whisper-cli) direkte på hele WAV-filen — ingen
    filstørrelsesgrænse, så ingen chunking nødvendig (modsat den tidligere
    Groq-baserede version)."""
    out_prefix = work_dir / "transcript"
    cmd = [
        WHISPER_CLI_BIN,
        "-m", str(WHISPER_MODEL_PATH),
        "-f", str(wav_path),
        "-l", WHISPER_LANG,
        # Greedy uden kontekst-overførsel og med ikke-tale undertrykt. Målt
        # 30/10-2026 på CoRal-v3 test: lavere WER end defaults (-bs 5), og
        # defaults gik i gentagelsesløkke. VAD fravalgt: tabte samtale-ord.
        "-bs", "1",
        "-mc", "0",
        "-sns",
        "-osrt",
        "-of", str(out_prefix),
    ]
    print(
        f"Transskriberer med whisper.cpp ({WHISPER_MODEL_PATH.name}, lokalt, "
        "kan tage et stykke tid for lange filer)...",
        file=sys.stderr,
    )
    result = subprocess.run(cmd, capture_output=True)
    if result.returncode != 0:
        fail(
            f"whisper-cli fejlede:\n{result.stderr.decode(errors='replace')[:2000]}"
        )

    srt_path = out_prefix.with_suffix(".srt")
    if not srt_path.exists():
        fail(f"whisper-cli producerede ikke den forventede SRT-fil: {srt_path}")

    segments = parse_srt(srt_path.read_text(encoding="utf-8", errors="replace"))
    if not segments:
        fail("SRT-parsing gav ingen tekst-segmenter — tjek whisper-cli-outputtet.")
    return drop_phantom_segments(segments)


# Undertekst-krediteringer fra Whispers træningsdata (film/tv-rulletekster).
# Whisper skriver dem i stilhed og musik. Kun hele segmenter fjernes, og kun
# fraser ingen siger i et møde — ikke "tak for i dag" o.l., der også er tale.
PHANTOM_RE = re.compile(
    r"^(danske |danish )?(under)?tekst(er|et)? (af|ved|by)\b.*"
    r"|^subtitles by\b.*"
    r"|^thanks? (you )?for watching\b.*",
    re.IGNORECASE,
)


def drop_phantom_segments(segments: list[WhisperSegment]) -> list[WhisperSegment]:
    """Fjern segmenter der udelukkende er en kendt fantomlinje. Fjernede linjer
    logges på stderr, så intet forsvinder i det skjulte."""
    kept: list[WhisperSegment] = []
    for seg in segments:
        if PHANTOM_RE.match(seg.text.strip(" .,!-♪")):
            print(f"Fjernet fantomlinje [{format_timestamp(seg.start)}]: {seg.text}", file=sys.stderr)
        else:
            kept.append(seg)
    return kept or segments


# ── Trin 4: merge diarization + transskription ──────────────────────────────


def _overlap_seconds(a_start: float, a_end: float, b_start: float, b_end: float) -> float:
    return max(0.0, min(a_end, b_end) - max(a_start, b_start))


def merge_speakers(
    whisper_segments: list[WhisperSegment],
    diar_segments: list[DiarizationSegment],
) -> list[tuple[float, str, str]]:
    """For hvert tekst-segment: find diarization-talen med størst
    tidsmæssigt overlap. Returnerer liste af (start, speaker_label, text).

    Speaker-labels omdøbes fra pyannotes "SPEAKER_00" til menneskeligt
    "Taler 1", "Taler 2" osv., i den rækkefølge de først optræder."""
    speaker_order: list[str] = []

    def human_label(raw_speaker: str) -> str:
        if raw_speaker not in speaker_order:
            speaker_order.append(raw_speaker)
        return f"Taler {speaker_order.index(raw_speaker) + 1}"

    results: list[tuple[float, str, str]] = []
    for wseg in whisper_segments:
        best_speaker = None
        best_overlap = 0.0
        for dseg in diar_segments:
            ov = _overlap_seconds(wseg.start, wseg.end, dseg.start, dseg.end)
            if ov > best_overlap:
                best_overlap = ov
                best_speaker = dseg.speaker
        if best_speaker is None:
            # Intet overlap fundet (fx stilhed/musik uden for diarization-spor)
            # — brug nærmeste segment i tid som fallback.
            nearest = min(
                diar_segments,
                key=lambda d: min(abs(d.start - wseg.start), abs(d.end - wseg.start)),
                default=None,
            )
            best_speaker = nearest.speaker if nearest else "UKENDT"
        label = human_label(best_speaker) if best_speaker != "UKENDT" else "Ukendt taler"
        text = wseg.text.strip()
        if text:
            results.append((wseg.start, label, text))
    return results


# ── Output-formatering ───────────────────────────────────────────────────────


def format_timestamp(seconds: float) -> str:
    total = int(seconds)
    h, rem = divmod(total, 3600)
    m, s = divmod(rem, 60)
    return f"{h:02d}:{m:02d}:{s:02d}"


def _fsync_dir(directory: Path) -> None:
    """Gør selve omdøbningen holdbar. Fejler stille på filsystemer, der ikke kan det."""
    try:
        fd = os.open(str(directory), os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


def write_atomic(target: Path, data: str) -> None:
    """Skriv til en skjult midlertidig fil i samme mappe, fsync den, og omdøb den så på plads.
    En afbrudt kørsel efterlader aldrig en halv fil, og en eksisterende fil erstattes kun af en hel."""
    tmp = target.with_name(f".{target.name}.tmp-{os.getpid()}")
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, target)
        _fsync_dir(target.parent)
    finally:
        if tmp.exists():
            tmp.unlink()


def copy_atomic(source: Path, target: Path) -> None:
    """Som write_atomic, men kopierer en eksisterende fil (fx SRT-filen)."""
    write_atomic(target, source.read_text(encoding="utf-8"))


def write_transcript(entries: list[tuple[float, str, str]], out_path: Path) -> None:
    lines = [f"[{format_timestamp(start)}] {speaker}: {text}" for start, speaker, text in entries]
    write_atomic(out_path, "\n".join(lines) + "\n")


# ── Main ─────────────────────────────────────────────────────────────────────


def main() -> None:
    global WHISPER_MODEL_PATH, WHISPER_LANG
    parser = argparse.ArgumentParser(description="Lokal transskription: tekst alene, eller tekst med talerseparation.")
    parser.add_argument("input", type=str, help="Sti til lyd- eller videofil.")
    parser.add_argument(
        "--output", type=str, default=None,
        help="Output-mappe til .txt-transskriptet (default: samme mappe som input).",
    )
    parser.add_argument(
        "--mode", choices=["talere", "tekst"], default="tekst",
        help="tekst (standard) = kun whisper, ingen talerseparation, intet HF_TOKEN. talere = pyannote + whisper.",
    )
    parser.add_argument(
        "--model", default="large-v3-turbo-q5_0",
        help="whisper.cpp-model i modelmappen, som ggml-<model>.bin (standard large-v3-turbo-q5_0).",
    )
    parser.add_argument("--lang", default="da", help="Sprogkode til whisper (default da).")
    parser.add_argument(
        "--num-speakers", type=int, default=None,
        help="Antal talere, hvis kendt på forhånd (kun --mode talere).",
    )
    parser.add_argument(
        "--keep-work-dir", action="store_true",
        help="Behold den midlertidige arbejdsmappe (WAV, SRT) efter kørsel — til fejlsøgning.",
    )
    args = parser.parse_args()

    input_path = Path(args.input).expanduser().resolve()
    if not input_path.exists():
        fail(f"Filen findes ikke: {input_path}")

    WHISPER_MODEL_PATH = WHISPER_MODEL_DIR / f"ggml-{args.model}.bin"
    WHISPER_LANG = args.lang
    check_ffmpeg()
    check_whisper_cli()
    hf_token = check_env() if args.mode == "talere" else ""

    output_dir = Path(args.output).expanduser().resolve() if args.output else input_path.parent
    output_dir.mkdir(parents=True, exist_ok=True)
    out_path = output_dir / f"{input_path.stem}_transskript.txt"

    t0 = time.time()
    with tempfile.TemporaryDirectory(prefix="interview_transcribe_") as tmp:
        work_dir = Path(tmp)

        print(f"Konverterer {input_path.name} til 16kHz mono WAV...", file=sys.stderr)
        wav_path = convert_to_wav(input_path, work_dir)

        diar_segments = []
        if args.mode == "talere":
            diar_segments = run_diarization(wav_path, hf_token, num_speakers=args.num_speakers)
            print(
                f"Diarization færdig: {len(diar_segments)} segmenter, "
                f"{len({d.speaker for d in diar_segments})} talere fundet.",
                file=sys.stderr,
            )

        whisper_segments = run_transcription(wav_path, work_dir)
        print(f"Transskription færdig: {len(whisper_segments)} tekst-segmenter.", file=sys.stderr)

        if args.mode == "tekst":
            copy_atomic(work_dir / "transcript.srt", output_dir / f"{input_path.stem}_transskript.srt")

        if args.keep_work_dir:
            kept = input_path.parent / f"{input_path.stem}_work"
            shutil.copytree(work_dir, kept, dirs_exist_ok=True)
            print(f"Arbejdsmappe beholdt: {kept}", file=sys.stderr)

    if args.mode == "tekst":
        lines = [f"[{format_timestamp(w.start)}] {w.text.strip()}" for w in whisper_segments if w.text.strip()]
        write_atomic(out_path, "\n".join(lines) + "\n")
    else:
        merged = merge_speakers(whisper_segments, diar_segments)
        if not merged:
            fail("Ingen tekst-segmenter efter merge — noget gik galt undervejs.")
        write_transcript(merged, out_path)
    print(f"Færdig på {time.time() - t0:.0f} s ({args.mode}, {args.model}). Transskript gemt: {out_path}")


if __name__ == "__main__":
    main()
