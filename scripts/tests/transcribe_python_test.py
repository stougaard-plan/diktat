#!/usr/bin/env python3
"""Tester rettelserne D1 og D2 i scripts/transcribe uden rigtig lyd, uden ffmpeg og uden whisper.

D1 (moede_transcribe.py): et spor, der FEJLER, må ikke erstatte et eksisterende transskript med et ufuldstændigt.
    Et spor, der blot MANGLER, er ikke en fejl.
D2 (interview_transcribe.py): transskript og SRT skrives atomisk (midlertidig fil, fsync, omdøbning).

Kør:  python3 scripts/tests/transcribe_python_test.py
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent.parent
TRANSCRIBE = Path(os.environ.get("DIKTAT_TRANSCRIBE_DIR") or ROOT / "scripts" / "transcribe")


def load(name: str):
    spec = importlib.util.spec_from_file_location(name, TRANSCRIBE / f"{name}.py")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod   # dataclasses slår modulet op her
    spec.loader.exec_module(mod)
    return mod


def make_meeting(tmp: Path, computer: str = "present", mik_extra: str = "") -> Path:
    """Mødemappe med dummy-filer. computer = present (ét segment) / none (ingen segmenter i meta)."""
    m = tmp / "moede"
    m.mkdir()
    (m / "mik_0001.caf").write_bytes(b"x")
    segs = [{"track": "mik", "file": "mik_0001.caf", "startedAt": "2026-11-05T10:00:00Z"}]
    if mik_extra:   # et andet mikrofonsegment: "missing" (filen findes ikke) eller "present" (findes)
        if mik_extra == "present":
            (m / "mik_0002.caf").write_bytes(b"x")
        segs.append({"track": "mik", "file": "mik_0002.caf", "startedAt": "2026-11-05T10:00:05Z"})
    if computer == "present":
        (m / "computer_0001.caf").write_bytes(b"x")
        segs.append({"track": "computer", "file": "computer_0001.caf", "startedAt": "2026-11-05T10:00:00Z"})
    (m / "meta.json").write_text(json.dumps(
        {"title": "Møde", "startedAt": "2026-11-05T10:00:00Z", "status": "stopped", "events": [], "segments": segs}))
    return m


class FakeFfmpeg:
    """Erstatter moede_transcribe.run. Laver outputfilen (sidste argument), medmindre en regel siger fejl."""

    def __init__(self, fail_when=None):
        self.fail_when = fail_when

    def __call__(self, cmd):
        if self.fail_when and self.fail_when(cmd):
            return subprocess.CompletedProcess(cmd, 1, "", "simuleret fejl")
        Path(cmd[-1]).write_bytes(b"wav")
        return subprocess.CompletedProcess(cmd, 0, "", "")


def run_main(meeting: Path, *, fail_when=None, durations=None):
    """Kører moede_transcribe.main() med lyd og whisper erstattet. Returnerer exitkode (0 hvis main vender tilbage)."""
    m = load("moede_transcribe")
    durations = durations or {}
    m.preflight = lambda model: None
    m.diarization_possible = lambda: (False, "ingen talerseparation i testen")
    m.find_vad_model = lambda: None
    m.run = FakeFfmpeg(fail_when)
    m.duration = lambda p: durations.get(Path(p).name.split("_")[0], 5.0) if Path(p).suffix == ".caf" else 5.0
    m.transcribe = lambda wav, outdir, mode, model, n, lang="da": [(1, "", "hej verden")]
    argv = ["moede_transcribe.py", str(meeting)]
    with mock.patch.object(sys, "argv", argv):
        try:
            m.main()
        except SystemExit as e:
            return int(e.code or 0)
    return 0


class D1TrackFailureKeepsTranscript(unittest.TestCase):
    def test_join_failure_keeps_existing_transcript(self):
        with tempfile.TemporaryDirectory() as t:
            m = make_meeting(Path(t))
            (m / "transskript.txt").write_text("GAMMELT OG HELT\n", encoding="utf-8")
            code = run_main(m, fail_when=lambda cmd: "concat" in cmd and "computer_list.txt" in " ".join(cmd))
            self.assertEqual(code, 5, "sammenføjningsfejl skal give exitkode 5")
            self.assertEqual((m / "transskript.txt").read_text(encoding="utf-8"), "GAMMELT OG HELT\n",
                             "det eksisterende transskript skal være uændret")
            partial = m / "transskript.delvist.txt"
            self.assertTrue(partial.exists(), "delresultatet skal gemmes separat")
            text = partial.read_text(encoding="utf-8")
            self.assertIn("UFULDSTÆNDIGT", text)
            self.assertIn("Mig: hej verden", text)

    def test_join_failure_without_existing_transcript_writes_no_transcript(self):
        with tempfile.TemporaryDirectory() as t:
            m = make_meeting(Path(t))
            code = run_main(m, fail_when=lambda cmd: "concat" in cmd and "computer_list.txt" in " ".join(cmd))
            self.assertEqual(code, 5)
            self.assertFalse((m / "transskript.txt").exists(), "et ufuldstændigt resultat må ikke hedde transskript.txt")
            self.assertTrue((m / "transskript.delvist.txt").exists())

    def test_unreadable_segments_are_failure(self):
        with tempfile.TemporaryDirectory() as t:
            m = make_meeting(Path(t))
            (m / "transskript.txt").write_text("GAMMELT\n", encoding="utf-8")
            # ffprobe kan ikke læse computerfilen (duration None) men der VAR en fil: fejl
            code = run_main(m, durations={"computer": None})
            self.assertEqual(code, 5)
            self.assertEqual((m / "transskript.txt").read_text(encoding="utf-8"), "GAMMELT\n")

    def test_one_missing_segment_with_audio_is_failure_even_though_wav_exists(self):
        """K1: mikrofonsporet har ét brugbart og ét manglende segment. WAV'en findes og transskriberes, men
        resultatet er ufuldstændigt og må ikke erstatte et komplet transskript."""
        with tempfile.TemporaryDirectory() as t:
            m = make_meeting(Path(t), computer="none", mik_extra="missing")
            (m / "transskript.txt").write_text("KOMPLET GAMMELT\n", encoding="utf-8")
            self.assertEqual(run_main(m), 5)
            self.assertEqual((m / "transskript.txt").read_text(encoding="utf-8"), "KOMPLET GAMMELT\n")
            text = (m / "transskript.delvist.txt").read_text(encoding="utf-8")
            self.assertIn("UFULDSTÆNDIGT", text)
            self.assertIn("mik_0002.caf mangler", text)
            self.assertIn("Mig: hej verden", text, "den brugbare lyd er ikke tabt, den ligger i delresultatet")

    def test_one_segment_ffmpeg_cannot_read_is_failure(self):
        with tempfile.TemporaryDirectory() as t:
            m = make_meeting(Path(t), mik_extra="present")
            (m / "transskript.txt").write_text("KOMPLET GAMMELT\n", encoding="utf-8")
            code = run_main(m, fail_when=lambda cmd: any("mik_0002" in str(a) for a in cmd))
            self.assertEqual(code, 5)
            self.assertEqual((m / "transskript.txt").read_text(encoding="utf-8"), "KOMPLET GAMMELT\n")
            self.assertTrue((m / "transskript.delvist.txt").exists())

    def test_one_empty_segment_among_good_ones_is_not_failure(self):
        with tempfile.TemporaryDirectory() as t:
            m = make_meeting(Path(t), mik_extra="present")
            code = run_main(m, durations={"mik": 5.0, "mik2": 5.0})
            self.assertEqual(code, 0)
            self.assertFalse((m / "transskript.delvist.txt").exists())

    def test_absent_track_is_not_a_failure(self):
        with tempfile.TemporaryDirectory() as t:
            m = make_meeting(Path(t), computer="none")
            (m / "transskript.txt").write_text("GAMMELT\n", encoding="utf-8")
            code = run_main(m)
            self.assertEqual(code, 0, "intet computerspor er fravær og ikke en fejl")
            new = (m / "transskript.txt").read_text(encoding="utf-8")
            self.assertIn("Mig: hej verden", new)
            self.assertFalse((m / "transskript.delvist.txt").exists())

    def test_empty_track_is_absence(self):
        with tempfile.TemporaryDirectory() as t:
            m = make_meeting(Path(t))
            code = run_main(m, durations={"computer": 0.01})
            self.assertEqual(code, 0, "et tomt computerspor er fravær")
            self.assertTrue((m / "transskript.txt").exists())

    def test_success_removes_old_partial(self):
        with tempfile.TemporaryDirectory() as t:
            m = make_meeting(Path(t))
            (m / "transskript.delvist.txt").write_text("gammelt delresultat\n", encoding="utf-8")
            self.assertEqual(run_main(m), 0)
            self.assertFalse((m / "transskript.delvist.txt").exists())


class K5ModelDirectory(unittest.TestCase):
    """Appens modelmappe og mødernes ~/.whisper-models er forskellige. Hjemmemappen er en tom, falsk mappe."""

    def _preflight(self, home: Path, env_dir):
        m = load("moede_transcribe")
        with mock.patch.dict(os.environ, {"HOME": str(home)}, clear=False):
            if env_dir is None:
                os.environ.pop("DIKTAT_WHISPER_MODELS", None)
            else:
                os.environ["DIKTAT_WHISPER_MODELS"] = str(env_dir)
            m.MODEL_DIR = Path(os.environ["DIKTAT_WHISPER_MODELS"]) if env_dir else Path(home) / ".whisper-models"
            m.shutil.which = lambda tool: "/usr/bin/" + tool
            try:
                m.preflight("large-v3-turbo-q5_0")
                return 0, m, dict(os.environ)
            except SystemExit as e:
                return int(e.code or 0), m, dict(os.environ)

    def test_model_in_app_dir_is_found_without_home_files(self):
        with tempfile.TemporaryDirectory() as t:
            home = Path(t) / "hjem"; home.mkdir()
            appdir = Path(t) / "App" / "WhisperModels"; appdir.mkdir(parents=True)
            (appdir / "ggml-large-v3-turbo-q5_0.bin").write_bytes(b"m")
            code, m, _ = self._preflight(home, appdir)
            self.assertEqual(code, 0)
            self.assertEqual(m.MODEL_DIR, appdir)

    def test_model_only_in_old_dir_is_found_by_fallback(self):
        with tempfile.TemporaryDirectory() as t:
            home = Path(t) / "hjem"; (home / ".whisper-models").mkdir(parents=True)
            (home / ".whisper-models" / "ggml-large-v3-turbo-q5_0.bin").write_bytes(b"m")
            appdir = Path(t) / "App" / "WhisperModels"; appdir.mkdir(parents=True)   # tom
            code, m, env = self._preflight(home, appdir)
            self.assertEqual(code, 0, "modellen i ~/.whisper-models skal findes uden ny hentning")
            self.assertEqual(env["DIKTAT_WHISPER_MODELS"], str(home / ".whisper-models"), "interview-scriptet får samme mappe")

    def test_missing_everywhere_gives_clear_error(self):
        with tempfile.TemporaryDirectory() as t:
            home = Path(t) / "hjem"; home.mkdir()
            appdir = Path(t) / "App" / "WhisperModels"; appdir.mkdir(parents=True)
            code, _, _ = self._preflight(home, appdir)
            self.assertEqual(code, 3)


class P3S6PyannoteEnvironment(unittest.TestCase):
    """P3: pyannotes målinger er slået fra FØR pakken importeres. S6: modeller hentes kun med særskilt samtykke."""

    def _run(self, consent: bool, preset=None):
        import importlib.abc
        import importlib.machinery
        seen = {}

        class StubLoader(importlib.abc.Loader):
            def create_module(self, spec):
                return None

            def exec_module(self, module):
                # Det, pakken ville se, da den blev importeret
                seen["metrics_at_import"] = os.environ.get("PYANNOTE_METRICS_ENABLED")
                seen["offline_at_import"] = os.environ.get("HF_HUB_OFFLINE")

                class Pipeline:
                    @staticmethod
                    def from_pretrained(name, token=None):
                        seen["offline_at_load"] = os.environ.get("HF_HUB_OFFLINE")
                        seen["token"] = token
                        raise OSError("simuleret: ingen net / ikke i cachen")
                module.Pipeline = Pipeline

        class Finder(importlib.abc.MetaPathFinder):
            def find_spec(self, name, path, target=None):
                if name in ("pyannote", "pyannote.audio"):
                    return importlib.machinery.ModuleSpec(name, StubLoader(), is_package=(name == "pyannote"))
                return None

        it = load("interview_transcribe")
        env = {k: v for k, v in os.environ.items() if k not in ("PYANNOTE_METRICS_ENABLED", "HF_HUB_OFFLINE", "DIKTAT_TILLAD_MODELHENTNING")}
        if preset is not None:
            env["PYANNOTE_METRICS_ENABLED"] = preset
        if consent:
            env["DIKTAT_TILLAD_MODELHENTNING"] = "1"
        finder = Finder()
        sys.meta_path.insert(0, finder)
        for name in ("pyannote", "pyannote.audio"):
            sys.modules.pop(name, None)
        out = None
        try:
            with mock.patch.dict(os.environ, env, clear=True):
                try:
                    it.run_diarization(Path("x.wav"), "hf_test")
                except SystemExit as e:
                    out = int(e.code or 0)
        finally:
            sys.meta_path.remove(finder)
            for name in ("pyannote", "pyannote.audio"):
                sys.modules.pop(name, None)
        return seen, out

    def test_metrics_are_off_before_import_even_when_environment_says_on(self):
        seen, _ = self._run(consent=False, preset="true")
        self.assertEqual(seen["metrics_at_import"], "0")

    def test_metrics_are_off_by_default(self):
        seen, _ = self._run(consent=True)
        self.assertEqual(seen["metrics_at_import"], "0")

    def test_no_model_download_without_consent(self):
        seen, code = self._run(consent=False)
        self.assertEqual(seen["offline_at_import"], "1")
        self.assertEqual(seen["offline_at_load"], "1", "uden samtykke er Hugging Face-nettet slået fra")
        self.assertEqual(code, 1)

    def test_model_download_allowed_with_consent(self):
        seen, code = self._run(consent=True)
        self.assertNotEqual(seen["offline_at_load"], "1")
        self.assertEqual(code, 1, "stubben fejler hentningen, så scriptet stopper med fejl")


class D2AtomicWrite(unittest.TestCase):
    def setUp(self):
        self.it = load("interview_transcribe")

    def test_failed_replace_keeps_old_file_and_leaves_no_temp(self):
        with tempfile.TemporaryDirectory() as t:
            target = Path(t) / "x_transskript.txt"
            target.write_text("GAMMEL\n", encoding="utf-8")
            with mock.patch.object(os, "replace", side_effect=OSError("simuleret afbrydelse")):
                with self.assertRaises(OSError):
                    self.it.write_transcript([(0.0, "Taler 1", "ny tekst")], target)
            self.assertEqual(target.read_text(encoding="utf-8"), "GAMMEL\n")
            self.assertEqual([p.name for p in Path(t).iterdir() if ".tmp-" in p.name], [], "ingen midlertidig fil efterladt")

    def test_fsync_happens_before_rename(self):
        order = []
        real_fsync, real_replace = os.fsync, os.replace
        with tempfile.TemporaryDirectory() as t:
            target = Path(t) / "x_transskript.txt"
            with mock.patch.object(os, "fsync", side_effect=lambda fd: (order.append("fsync"), real_fsync(fd))[1]), \
                 mock.patch.object(os, "replace", side_effect=lambda a, b: (order.append("replace"), real_replace(a, b))[1]):
                self.it.write_transcript([(0.0, "Taler 1", "tekst")], target)
            self.assertIn("fsync", order)
            self.assertLess(order.index("fsync"), order.index("replace"))
            self.assertIn("Taler 1: tekst", target.read_text(encoding="utf-8"))

    def _run_main(self, out: Path, fail_suffix: str):
        """Kører main() i tekst-tilstand med lyd og whisper erstattet. Omdøbning fejler for filer, der ender på fail_suffix."""
        it = self.it
        wav_in = out.parent / "lyd.wav"
        wav_in.write_bytes(b"x")
        real_replace = os.replace

        def selective_replace(a, b):
            if str(b).endswith(fail_suffix):
                raise OSError("simuleret afbrydelse")
            return real_replace(a, b)

        def fake_convert(inp, work):
            p = work / "audio.wav"
            p.write_bytes(b"wav")
            return p

        def fake_transcription(wav, work):
            (work / "transcript.srt").write_text("1\n00:00:00,000 --> 00:00:01,000\nny tekst\n", encoding="utf-8")
            return [it.WhisperSegment(0.0, 1.0, "ny tekst")]

        patches = [mock.patch.object(it, "check_ffmpeg", lambda: None),
                   mock.patch.object(it, "check_whisper_cli", lambda: None),
                   mock.patch.object(it, "convert_to_wav", fake_convert),
                   mock.patch.object(it, "run_transcription", fake_transcription),
                   mock.patch.object(os, "replace", selective_replace),
                   mock.patch.object(sys, "argv", ["interview_transcribe.py", str(wav_in), "--output", str(out), "--mode", os.environ.get("DIKTAT_TEXT_MODE", "tekst")])]
        for p in patches:
            p.start()
        try:
            with self.assertRaises(OSError):
                it.main()
        finally:
            for p in reversed(patches):
                p.stop()

    def test_text_mode_transcript_is_atomic(self):
        with tempfile.TemporaryDirectory() as t:
            out = Path(t) / "ud"
            out.mkdir()
            (out / "lyd_transskript.txt").write_text("GAMMEL TEKST\n", encoding="utf-8")
            self._run_main(out, "_transskript.txt")
            self.assertEqual((out / "lyd_transskript.txt").read_text(encoding="utf-8"), "GAMMEL TEKST\n")

    def test_srt_copy_is_atomic(self):
        with tempfile.TemporaryDirectory() as t:
            out = Path(t) / "ud"
            out.mkdir()
            (out / "lyd_transskript.srt").write_text("GAMMEL SRT\n", encoding="utf-8")
            self._run_main(out, "_transskript.srt")
            self.assertEqual((out / "lyd_transskript.srt").read_text(encoding="utf-8"), "GAMMEL SRT\n")


if __name__ == "__main__":
    unittest.main(verbosity=2)
