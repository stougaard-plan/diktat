# Mødetransskription (scripts)

To Python-scripts, som Diktats notetaker kører efter et møde. Alt kører lokalt på din Mac.

| Fil | Hvad den gør |
|---|---|
| `moede_transcribe.py` | Tager en mødemappe fra `~/Moeder/`, transskriberer mikrofonen («Mig») og computerlyden («De») og skriver `transskript.txt`. |
| `interview_transcribe.py` | Kører ffmpeg og whisper.cpp på én lydfil. Kan også køre talerseparation med pyannote. |
| `requirements.txt` | Kun til valgfri talerseparation. |
| `setup-diarization.sh` | Opretter et Python-miljø til talerseparation i `~/.diktat/venv`. |

Appen finder scriptet i sit eget bundt (`Diktat.app/Contents/Resources/transcribe/`). Du kan også køre det i hånden fra repoet.

## Det der skal være installeret

| Hvad | Hvordan | Størrelse |
|---|---|---|
| `whisper-cli` | `brew install whisper-cpp` | lille |
| `ffmpeg` og `ffprobe` | `brew install ffmpeg` | ca. 100 MB med afhængigheder |
| Whisper-model `ggml-large-v3-turbo-q5_0.bin` i `~/.whisper-models/` | se herunder | ca. 574 MB |
| Python 3 | følger med Xcodes kommandolinjeværktøjer | |

Hent modellen:

```
mkdir -p ~/.whisper-models
curl -L -o ~/.whisper-models/ggml-large-v3-turbo-q5_0.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin
```

Stemmeaktivitetsfilteret (`ggml-silero-v5.1.2.bin`) ligger i repoet og i appens bundt. Scriptet finder det selv. Du kan pege på en anden med `DIKTAT_VAD_MODEL`.

## Stemmeopdeling (valgfri)

Uden den står alle andre i mødet som «De». Med den kan flere stemmer blive «De 1», «De 2». Det er et teknisk gæt på stemmer og siger ikke, hvem de er. I testen delte den én stemme i tre, så regn ikke med, at den er rigtig.

1. Installér Python 3.12: `brew install python@3.12`
2. Kør `scripts/transcribe/setup-diarization.sh`. Det henter flere GB og spørger først (`--ja` springer spørgsmålet over).
3. Opret en konto på huggingface.co og et token med læseadgang. Acceptér licensen på de tre modelsider: `pyannote/speaker-diarization-3.1`, `pyannote/segmentation-3.0` og `pyannote/speaker-diarization-community-1`.
4. Sæt tokenet i miljøet, uden at gemme det i en fil, fx `launchctl setenv HF_TOKEN <token>`. Det forsvinder, når Macen genstarter.
5. Kør `scripts/transcribe/setup-diarization.sh --hent-modeller`. Det er dit **særskilte** ja til at hente stemmemodellerne fra huggingface.co (flere hundrede MB). Uden trin 5 hentes der intet, og møde- og interviewscripts går aldrig selv på nettet efter modeller. Mangler modellerne, står det i fejlen, og mødet transskriberes uden stemmeopdeling.

Det er det eneste netværk i scripts, og kun hvis du har gjort trin 1 til 5. pyannote.audio sender ellers som standard målinger til `otel.pyannote.ai`. Scriptene slår det fra (`PYANNOTE_METRICS_ENABLED=0`, sat før pakken importeres), så der sendes ingen.

## Miljøvariabler (alle valgfrie)

| Variabel | Betydning |
|---|---|
| `HF_TOKEN` | Slår talerseparation til. Læses kun fra miljøet. |
| `DIKTAT_TILLAD_MODELHENTNING=1` | Sættes kun af `setup-diarization.sh --hent-modeller`. Uden den er nettet slået fra for modeller (`HF_HUB_OFFLINE=1`). |
| `DIKTAT_WHISPER_MODELS` | Anden modelmappe end `~/.whisper-models`. |
| `DIKTAT_VAD_MODEL` | Sti til stemmeaktivitetsfilteret. |
| `DIKTAT_PYTHON` | Python med pyannote, hvis den ikke ligger i `~/.diktat/venv`. |
| `MOEDE_NO_VAD=1` | Slå stemmeaktivitetsfilteret fra. |

## Kør i hånden

```
python3 scripts/transcribe/moede_transcribe.py ~/Moeder/<mødemappe> --lang da
```

Sprog: `da`, `en` eller `auto`. Resultatet er `transskript.txt` i mødemappen. Læs teksten efter. Tal og navne kan være forkerte.
