#!/usr/bin/env python3
"""Møde-transskription for Diktat-notetakeren.

100% LOKAL: intet lydindhold forlader maskinen. Kører `interview_transcribe.py` (whisper.cpp, evt. pyannote)
pr. spor og samler til ét tidsstemplet transskript.

Input: en mødemappe fra Diktat (`~/Moeder/<dato>_<titel>/`) med
  mik_0001.caf ...       mikrofonen = "Mig"
  computer_0001.caf ...  computerlyden = "De"
  meta.json              segmenter med starttid (bruges til at lægge stilhed ind, hvor der var hul)

Output i samme mappe:
  transskript.txt        [hh:mm:ss] Mig: tekst / [hh:mm:ss] De: tekst   (skrives atomisk, kun ved succes)
  transskript.delvist.txt  kun hvis et spor FEJLEDE (ikke bare manglede). Så er transskript.txt ikke rørt, og
                         delresultatet ligger her, tydeligt mærket. Exitkode 5.

Mikrofonsporet hedder "Mig", computersporet "De".
Talerseparation er VALGFRI. Den kører kun, hvis HF_TOKEN er sat i miljøet OG pyannote er installeret
(se requirements.txt). Så hedder stemmerne "De 1", "De 2" osv. Opdelingen er et teknisk gæt på stemmer og
påstår aldrig at vide, hvem de er. Uden HF_TOKEN kører scriptet videre uden opdeling, og det står tydeligt
på skærmen og i transskriptets bemærkninger. Et fejlet kørsel rører hverken lydfilerne eller et eksisterende
transskript.txt.

Miljøvariabler (alle valgfrie):
  HF_TOKEN               Hugging Face-token til talerseparation. Læses kun fra miljøet og gemmes aldrig.
  DIKTAT_WHISPER_MODELS  Mappe med ggml-<model>.bin (standard ~/.whisper-models).
  DIKTAT_VAD_MODEL       Sti til ggml-silero-v5.1.2.bin (stemmeaktivitetsfilter).
  DIKTAT_PYTHON          Python med pyannote, hvis den ikke ligger i ~/.diktat/venv.
  MOEDE_NO_VAD=1         Slå stemmeaktivitetsfilteret fra.

Linjer til appen på stderr: "TRIN: ..." (fremdrift) og "FEJL: ..." (forståelig dansk fejl, exitkode 3 = mangler noget på maskinen).

Brug:
  python3 scripts/transcribe/moede_transcribe.py <mødemappe> [--model large-v3-turbo-q5_0] [--lang da] [--num-speakers N]

Slettefrister er ikke en del af scriptet. Lyd og transskripter ligger, til du selv sletter dem.
"""
from __future__ import annotations

import argparse
import difflib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
INTERVIEW = HERE / "interview_transcribe.py"
VENV_PYTHON = Path(os.environ.get("DIKTAT_PYTHON") or (Path.home() / ".diktat" / "venv" / "bin" / "python"))
MODEL_DIR = Path(os.environ.get("DIKTAT_WHISPER_MODELS", "~/.whisper-models")).expanduser()
LINE = re.compile(r"^\[(\d\d):(\d\d):(\d\d)\]\s*(?:(Taler \d+):\s)?(.*)$")


# Apps startet fra Finder/launchd har kun /usr/bin:/bin:/usr/sbin:/sbin i PATH. Homebrew skal med.
os.environ["PATH"] = ":".join(["/opt/homebrew/bin", "/usr/local/bin", os.environ.get("PATH", "")])


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def fail(msg: str, code: int = 3) -> None:
    log(f"FEJL: {msg}")
    raise SystemExit(code)


def find_vad_model() -> Path | None:
    """Silero VAD til whisper-cli. I en måling uden VAD tabte store modeller hele sætninger og gentog andre,
    med VAD kom alle sætninger med. Søger DIKTAT_VAD_MODEL, modelmappen, appens ressourcer (scriptet ligger i
    Diktat.app/Contents/Resources/transcribe) og repoets egen kopi (scriptet ligger i scripts/transcribe)."""
    name = "ggml-silero-v5.1.2.bin"
    cands = [os.environ.get("DIKTAT_VAD_MODEL", ""), str(MODEL_DIR / name),
             str(HERE.parent / name),
             str(HERE.parent.parent / "VoiceInk" / "Resources" / "models" / name),
             str(Path.home() / "Applications/Diktat.app/Contents/Resources" / name)]
    for c in cands:
        if c and Path(c).is_file():
            return Path(c)
    return None


def make_whisper_shim(work: Path, vad: Path) -> Path:
    """interview_transcribe.py må ikke ændres og har ingen VAD-flag. Et lille whisper-cli-skal først i PATH
    sender --vad med. Det rører intet uden for den midlertidige arbejdsmappe."""
    real = shutil.which("whisper-cli")
    shim_dir = work / "shim"
    shim_dir.mkdir(exist_ok=True)
    shim = shim_dir / "whisper-cli"
    shim.write_text(f'#!/bin/sh\nexec "{real}" "$@" --vad -vm "{vad}"\n')
    shim.chmod(0o755)
    return shim_dir


def preflight(model: str) -> None:
    """Tjek at alt, der skal bruges, findes, FØR der røres noget. Danske fejl med præcis den kommando, der mangler."""
    if not INTERVIEW.exists():
        fail(f"interview_transcribe.py ligger ikke ved siden af scriptet ({INTERVIEW}). Hent hele mappen scripts/transcribe fra repoet.")
    for tool, hint in (("ffmpeg", "brew install ffmpeg"), ("ffprobe", "brew install ffmpeg"),
                       ("whisper-cli", "brew install whisper-cpp")):
        if shutil.which(tool) is None:
            fail(f"{tool} er ikke installeret på denne Mac. Installér med: {hint}")
    global MODEL_DIR
    mp = MODEL_DIR / f"ggml-{model}.bin"
    fallback = Path("~/.whisper-models").expanduser()
    if not mp.exists() and (fallback / f"ggml-{model}.bin").exists():
        # Appen giver sin modelmappe videre, men modellen kan ligge i den gamle mappe. Brug den, hent intet.
        MODEL_DIR = fallback
        os.environ["DIKTAT_WHISPER_MODELS"] = str(fallback)   # interview_transcribe.py læser samme variabel
        mp = MODEL_DIR / f"ggml-{model}.bin"
    if not mp.exists():
        fail(f"Whisper-modellen '{model}' mangler ({mp}). Hent den fra "
             f"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-{model}.bin "
             f"og læg den i {MODEL_DIR}. Se scripts/transcribe/README.md.")


def diarization_possible() -> tuple[bool, str]:
    """Talerseparation kræver HF_TOKEN og pyannote i den Python, der bruges. Returnerer (muligt, grund hvis ikke)."""
    if not os.environ.get("HF_TOKEN", "").strip():
        return False, "HF_TOKEN er ikke sat, så De er ikke delt op i enkelte talere (talerseparation er valgfri)."
    py = str(VENV_PYTHON if VENV_PYTHON.exists() else sys.executable)
    probe = subprocess.run([py, "-c", "import importlib.util,sys;sys.exit(0 if importlib.util.find_spec('pyannote') else 1)"],
                           capture_output=True)
    if probe.returncode != 0:
        return False, ("HF_TOKEN er sat, men pyannote er ikke installeret i " + py +
                       ", så De er ikke delt op i enkelte talere. Se scripts/transcribe/README.md.")
    return True, ""


def run(cmd: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True)


def parse_time(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def duration(path: Path) -> float | None:
    r = run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)])
    try:
        return float(r.stdout.strip())
    except ValueError:
        return None


TRACK_OK, TRACK_ABSENT, TRACK_FAILED, TRACK_PARTIAL = "ok", "fravær", "fejl", "delvis"


def build_track(meeting: Path, meta: dict, track: str, work: Path) -> tuple[Path | None, list[str], str]:
    """Sæt sporets segmenter sammen til én 16 kHz mono WAV på mødets tidslinje.

    Hul mellem segmenter (fx dvale) fyldes med stilhed, så tidsstempler er mødetid.

    Tredje værdi skelner FRAVÆR fra FEJL:
      "ok"      sporet er bygget af alle segmenter, der havde lyd.
      "delvis"  sporet er bygget, men mindst ét segment MED lyd kunne ikke bruges (manglede, kunne ikke åbnes eller læses).
                WAV'en findes og transskriberes, men resultatet er ufuldstændigt og behandles som en fejl af kalderen.
      "fravær"  sporet fandtes ikke eller var tomt (fx ingen systemlyd optaget). Ikke en fejl.
      "fejl"    der VAR lyd i sporet, men det kunne ikke bruges (ulæselige filer, ffmpeg fejlede, sammenføjning fejlede).
                Så er resultatet ufuldstændigt, og kalderen må ikke give det ud som et helt transskript."""
    notes: list[str] = []
    problems = 0   # segmenter med lyd, der ikke kunne bruges
    start = parse_time(meta["startedAt"])
    segs = sorted((s for s in meta.get("segments", []) if s["track"] == track), key=lambda s: s["file"])
    parts: list[Path] = []
    pos = 0.0
    for i, seg in enumerate(segs):
        f = meeting / seg["file"]
        if not f.exists():
            notes.append(f"{seg['file']} mangler")
            problems += 1
            continue
        d = duration(f)
        if d is None:
            notes.append(f"{seg['file']} kunne ikke åbnes")
            problems += 1
            continue
        if d <= 0.05:
            notes.append(f"{seg['file']} er tom")
            continue
        offset = (parse_time(seg["startedAt"]) - start).total_seconds()
        if offset - pos > 1.0:
            gap = work / f"{track}_gap{i}.wav"
            rg = run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "anullsrc=r=16000:cl=mono",
                      "-t", f"{offset - pos:.3f}", "-c:a", "pcm_s16le", str(gap)])
            if rg.returncode != 0 or not gap.exists():
                # Uden stilheden passer tidsstemplerne ikke længere. Det er en fejl, ikke fravær.
                return None, notes + [f"Stilhed før {seg['file']} i sporet {track} kunne ikke laves"], TRACK_FAILED
            parts.append(gap)
            notes.append(f"{track}: hul på {offset - pos:.0f} s før {seg['file']} (lagt ind som stilhed)")
            pos = offset
        wav = work / f"{track}_{i}.wav"
        r = run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(f), "-ar", "16000", "-ac", "1",
                 "-c:a", "pcm_s16le", str(wav)])
        if r.returncode != 0 or not wav.exists():
            notes.append(f"{seg['file']} kunne ikke læses af ffmpeg")
            problems += 1
            continue
        parts.append(wav)
        pos += duration(wav) or d
    if not parts:
        # Ingen segmenter, eller kun tomme: fravær. Segmenter med lyd, der ikke kunne bruges: fejl.
        return None, notes + [f"Ingen brugbare segmenter i sporet {track}"], (TRACK_FAILED if problems else TRACK_ABSENT)
    lst = work / f"{track}_list.txt"
    lst.write_text("".join("file '" + str(p).replace("'", "'\\''") + "'\n" for p in parts))
    out = work / f"{track}_full.wav"
    r = run(["ffmpeg", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i", str(lst),
             "-c:a", "pcm_s16le", str(out)])
    if r.returncode != 0 or not out.exists():
        return None, notes + [f"Sammensætning af {track} fejlede"], TRACK_FAILED
    return out, notes, (TRACK_PARTIAL if problems else TRACK_OK)


def transcribe(wav: Path, outdir: Path, mode: str, model: str, num_speakers: int | None, lang: str = "da") -> list[tuple[int, str, str]]:
    py = str(VENV_PYTHON if VENV_PYTHON.exists() else sys.executable)
    cmd = [py, str(INTERVIEW), str(wav), "--output", str(outdir), "--mode", mode, "--model", model,
           "--lang", lang]
    if mode == "talere" and num_speakers:
        cmd += ["--num-speakers", str(num_speakers)]
    log("Kører: " + " ".join(cmd))
    # Egen procesgruppe, så en afbrydelse (appen lukkes) også standser whisper-cli og ikke efterlader en halv kørsel.
    env = dict(os.environ)
    if VAD_SHIM_DIR is not None:
        env["PATH"] = f"{VAD_SHIM_DIR}:{env['PATH']}"
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True, env=env)
    global _CHILD
    _CHILD = proc
    try:
        out_text, _ = proc.communicate()
    finally:
        _CHILD = None
    if proc.returncode != 0:
        log(f"interview_transcribe fejlede ({proc.returncode}). Sidste linjer:")
        log("\n".join(out_text.strip().splitlines()[-8:]))
        raise DiarizationOrWhisperError(out_text)
    txt = outdir / f"{wav.stem}_transskript.txt"
    lines = []
    for raw in txt.read_text(encoding="utf-8").splitlines():
        m = LINE.match(raw.strip())
        if not m:
            continue
        h, mi, s, who, text = m.groups()
        if text.strip():
            lines.append((int(h) * 3600 + int(mi) * 60 + int(s), who or "", text.strip()))
    return lines


_CHILD: subprocess.Popen | None = None
VAD_SHIM_DIR: Path | None = None


class DiarizationOrWhisperError(Exception):
    def __init__(self, output: str = ""):
        super().__init__(output)
        self.output = output

    @property
    def no_speech(self) -> bool:
        """interview_transcribe.py melder 'ingen tekst-segmenter', når et spor er stille (fx mikrofonen på mute).
        Det er ikke en fejl for et møde: sporet er bare tomt."""
        return "ingen tekst-segmenter" in self.output.lower()


def _terminate(signum, _frame):
    child = _CHILD
    if child is not None and child.poll() is None:
        try:
            os.killpg(child.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    raise SystemExit(128 + signum)


def norm(t: str) -> str:
    return re.sub(r"[^\wæøå ]", "", t.lower()).strip()


def drop_echo(mic: list[tuple[int, str, str]], comp: list[tuple[int, str, str]]) -> tuple[list, int]:
    """Fjern mikrofonlinjer, der næsten er ordret ens med en computerlinje inden for 10 s (højttaler-ekko)."""
    kept, dropped = [], 0
    for t, who, text in mic:
        echo = any(abs(t - ct) <= 10 and difflib.SequenceMatcher(None, norm(text), norm(ctext)).ratio() > 0.8
                   for ct, _, ctext in comp)
        if echo:
            dropped += 1
        else:
            kept.append((t, who, text))
    return kept, dropped


def stamp(t: int) -> str:
    return f"{t // 3600:02d}:{t % 3600 // 60:02d}:{t % 60:02d}"


def write_atomic(target: Path, text: str) -> None:
    """Skriv til en skjult temp-fil i samme mappe og flyt den på plads. En afbrudt kørsel efterlader
    aldrig en halv transskript.txt, og et eksisterende transskript bliver kun erstattet af et helt."""
    tmp = target.with_name(f".{target.name}.tmp-{os.getpid()}")
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, target)
    finally:
        if tmp.exists():
            tmp.unlink()


def main() -> None:
    ap = argparse.ArgumentParser(description="Transskribér en Diktat-mødemappe (lokalt).")
    ap.add_argument("meeting", type=Path)
    ap.add_argument("--model", default="large-v3-turbo-q5_0",
                    help="whisper.cpp-model i modelmappen (standard ~/.whisper-models). I egne målinger gav turbo-q5_0 med VAD færrest nøgleordsfejl og var 2x hurtigere end large-v3.")
    ap.add_argument("--lang", default="da", help="Sprogkode til whisper (standard da).")
    ap.add_argument("--num-speakers", type=int, default=None)
    args = ap.parse_args()

    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, _terminate)
    # Dør den proces, der startede os (appen blev dræbt), stopper vi også og efterlader ingen kørsel i baggrunden.
    parent = os.getppid()

    def watch_parent() -> None:
        while True:
            time.sleep(2)
            if os.getppid() != parent:
                os.kill(os.getpid(), signal.SIGTERM)
                return

    threading.Thread(target=watch_parent, daemon=True).start()

    meeting = args.meeting.expanduser().resolve()
    meta_path = meeting / "meta.json"
    if not meta_path.exists():
        fail(f"Der er ingen meta.json i mødemappen ({meeting}).", 1)
    try:
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
        parse_time(meta["startedAt"])
    except (ValueError, KeyError, OSError) as e:
        fail(f"meta.json kan ikke læses ({e}).", 1)
    preflight(args.model)
    # Ryd gamle temp-filer fra en tidligere afbrudt kørsel. Lydfiler og transskript.txt røres ikke.
    for old in meeting.glob(".transskript.txt.tmp-*"):
        old.unlink(missing_ok=True)

    t_start = time.time()
    notes: list[str] = []
    for ev in meta.get("events", []):
        if ev.get("kind") in ("spor-problem", "segment-fejl", "journal-fejl", "genstart-fejl"):
            notes.append(f"Under optagelsen: {ev.get('detail', '')}")
    if meta.get("status") != "stopped":
        notes.append(f"Optagelsen er markeret '{meta.get('status')}'. Færdige segmenter bruges, slutningen kan mangle.")

    audio_seconds = 0.0
    failed_tracks: list[str] = []
    can_diarize, why_not = diarization_possible()
    diarized = False
    with tempfile.TemporaryDirectory(prefix="moede_") as tmp:
        work = Path(tmp)
        global VAD_SHIM_DIR
        vad = find_vad_model()
        if vad is not None and os.environ.get("MOEDE_NO_VAD") != "1":
            VAD_SHIM_DIR = make_whisper_shim(work, vad)
        else:
            notes.append("Stemmeaktivitetsfilteret (VAD) blev ikke fundet, så tekst kan mangle eller gentages i lange stykker.")
        out: dict[str, list] = {}
        for n, track in enumerate(("mik", "computer"), 1):
            log(f"TRIN: Forbereder {'mikrofonen' if track == 'mik' else 'computerlyden'} ({n}/2)")
            wav, tn, track_status = build_track(meeting, meta, track, work)
            notes += tn
            if track_status in (TRACK_FAILED, TRACK_PARTIAL):
                # Også når WAV'en findes: mangler der lyd fra et segment, er resultatet ufuldstændigt og må aldrig
                # erstatte et komplet transskript. Sporet transskriberes alligevel, så delresultatet kan gemmes.
                failed_tracks.append(track)
                log(f"ADVARSEL: {'mikrofonen' if track == 'mik' else 'computerlyden'} kunne ikke forberedes helt. "
                    "Resultatet bliver ufuldstændigt og erstatter ikke et eksisterende transskript.")
            if wav is None:
                out[track] = []
                continue
            audio_seconds = max(audio_seconds, duration(wav) or 0.0)
            diarize = track == "computer" and can_diarize
            if track == "computer" and not diarize:
                notes.append(why_not)
                log("ADVARSEL: " + why_not + " Computersporet transskriberes uden talerseparation.")
            log(f"TRIN: Transskriberer {'mikrofonen' if track == 'mik' else 'computerlyden'} ({n}/2)"
                + (" med talerseparation" if diarize else ""))
            try:
                out[track] = transcribe(wav, work, "talere" if diarize else "tekst", args.model, args.num_speakers, args.lang)
                diarized = diarized or diarize
            except DiarizationOrWhisperError as err:
                if err.no_speech:
                    label = "Mikrofonen (Mig)" if track == "mik" else "Computerlyden (De)"
                    notes.append(f"{label}: der blev ikke fundet tale i sporet.")
                    out[track] = []
                    continue
                if not diarize:
                    fail("Transskriptionen fejlede. Se transskribering.log for detaljer.", 2)
                notes.append("Talerseparation fejlede (tjek HF_TOKEN og at licensen er accepteret på huggingface.co), så De er ikke delt op i enkelte talere.")
                log("ADVARSEL: talerseparation fejlede. Kører computersporet uden.")
                try:
                    out[track] = transcribe(wav, work, "tekst", args.model, None, args.lang)
                except DiarizationOrWhisperError as err2:
                    if not err2.no_speech:
                        fail("Transskriptionen fejlede. Se transskribering.log for detaljer.", 2)
                    notes.append("Computerlyden (De): der blev ikke fundet tale i sporet.")
                    out[track] = []

    comp_raw = out["computer"]
    speakers = sorted({who for _, who, _ in comp_raw if who}, key=lambda w: int(w.split()[-1]))
    if len(speakers) >= 2:
        names = {w: "De " + w.split()[-1] for w in speakers}
        notes.append(f"De er delt op af talerseparation ({len(speakers)} stemmer: De 1, De 2 ...). Opdelingen er et teknisk gæt "
                     "på stemmer og siger ikke, hvem de er.")
    else:
        names = {w: "De" for w in speakers}
        if diarized:
            notes.append("Talerseparation er kørt, men fandt kun én stemme i computerlyden.")
    comp = [(t, names.get(who, "De"), text) for t, who, text in comp_raw]
    mic, dropped = drop_echo([(t, "Mig", text) for t, _, text in out["mik"]], comp)
    if dropped:
        notes.append(f"{dropped} mikrofonlinjer fjernet som ekko af computerlyden")
    merged = sorted(mic + comp, key=lambda x: x[0])
    target = meeting / "transskript.txt"
    partial = meeting / "transskript.delvist.txt"
    if failed_tracks:
        # Et spor fejlede (var ikke bare fraværende). Et eksisterende transskript bevares uændret,
        # og det ufuldstændige resultat gemmes ved siden af, tydeligt mærket.
        names = " og ".join("mikrofonen" if t == "mik" else "computerlyden" for t in failed_tracks)
        if merged:
            start = parse_time(meta["startedAt"]).astimezone()
            warn = [f"# {meta.get('title', 'Møde')} (DELVIST RESULTAT)",
                    f"ADVARSEL: {names} kunne ikke forberedes, så dette transskript er UFULDSTÆNDIGT. "
                    "Brug det ikke som et helt referat.",
                    f"Optagelse startet {start.strftime('%d/%m-%Y kl. %H.%M')}. Tider er fra optagelsens start.", "",
                    "Bemærkninger:"] + [f"- {n}" for n in notes] + [""]
            write_atomic(partial, "\n".join(warn + [f"[{stamp(t)}] {who}: {text}" for t, who, text in merged]) + "\n")
        kept = "Det eksisterende transskript er ikke rørt. " if target.exists() else ""
        where = f"Delresultatet ligger i {partial.name}. " if merged else ""
        fail(f"{names[0].upper() + names[1:]} kunne ikke forberedes, så transskriptet ville være ufuldstændigt. "
             f"{kept}{where}Se transskribering.log for detaljer.", 5)
    if not merged:
        fail("Der blev ikke fundet tale i optagelsen (hverken Mig eller De).", 4)

    start = parse_time(meta["startedAt"]).astimezone()
    header = [f"# {meta.get('title', 'Møde')}",
              f"Optagelse startet {start.strftime('%d/%m-%Y kl. %H.%M')}. Tider er fra optagelsens start.",
              "Mig = mikrofonen. De = computerlyden.",
              "Råstof, ikke bevis: tal og navne skal kontrolleres mod lyden, før de bruges.", ""]
    if notes:
        header += ["Bemærkninger:"] + [f"- {n}" for n in notes] + [""]
    body = [f"[{stamp(t)}] {who}: {text}" for t, who, text in merged]
    write_atomic(target, "\n".join(header + body) + "\n")
    partial.unlink(missing_ok=True)  # et gammelt delresultat er overhalet af det hele
    used = time.time() - t_start
    per_min = f", {used / (audio_seconds / 60):.1f} s pr. minut lyd" if audio_seconds > 1 else ""
    print(f"Færdig: {len(merged)} linjer, {meeting / 'transskript.txt'}. Model {args.model}, "
          f"{used:.0f} s på {audio_seconds:.0f} s lyd{per_min}.")


if __name__ == "__main__":
    main()
