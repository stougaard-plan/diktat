# Diktat

Diktat er en lokal dikteringsapp og møde-notetaker til Mac. Du taler, og teksten kommer ind, hvor markøren står. Du kan også optage et møde, og få det skrevet ned bagefter. Det hele kører på din egen Mac. Efter gennemgang af kildekoden sendes lyd og tekst ikke til nogen tjeneste (se [Hvad forlader din Mac](#hvad-forlader-din-mac)).

Det er gratis. Du betaler hverken for appen, for modellerne eller for et abonnement.

## Det her er ikke VoiceInks egen udgave

Diktat er en ændret kopi af [VoiceInk](https://github.com/Beingpax/VoiceInk) fra Pax (GitHub: Beingpax). VoiceInk er udgivet under GPL v3, og det er Diktat også. Diktat er ikke lavet af VoiceInk-projektet og er ikke godkendt af det.

- Send fejl i Diktat til [Diktats eget repo](https://github.com/stougaard-plan/diktat/issues). Send dem ikke til VoiceInk.
- Diktat opdaterer sig ikke selv. Nye versioner kræver, at du henter koden igen og bygger på ny.
- Er du i tvivl om, hvad VoiceInk selv kan, så se deres side. Her står kun det, der gælder for Diktat.

## Hvad er ændret i forhold til VoiceInk

- **Notetaker.** Optager computerens lyd og din mikrofon i to spor og skriver mødet ned efter optagelsen. Start og stop med Control+Option+M. Mappen hedder `~/Moeder`.
- **Dansk brugerflade** og dansk som standardsprog. Sprogvalget står synligt under modelvalget.
- **Alt lokalt.** Skyudbydere, licenstjek, automatiske opdateringer og meddelelser er fjernet. Se [Hvad forlader din Mac](#hvad-forlader-din-mac).
- **Mødetitel er slået fra.** Mødet hedder dato og tid. Du kan slå en automatisk titel til med din egen Ollama-model.
- **Panelerne** følger musens skærm og skjules, når du deler skærmen (prøvet med macOS' egen skærmoptagelse, ikke med Teams).
- **Bygning uden Apple-udviklerkonto**, med et lokalt certifikat, så tilladelserne består efter nye builds.

Den fulde liste står i filen [NOTICE](NOTICE).

## Krav

- En Mac med Apple silicon. Intel er ikke prøvet.
- macOS 26.3 og Xcode 26.6 er det, der er prøvet. Projektet siger macOS 15 som mindstekrav. Det er ikke prøvet.
- Xcode. Det er gratis og hentes med et Apple-id på developer.apple.com/download eller i App Store.
- Omkring 20 GB ledig plads. Xcode, byggefiler og modeller fylder meget.
- Internet under opsætningen. Bagefter virker diktering og møder uden net.
- Homebrew (brew.sh), hvis du vil have notetakeren. Den bruger `whisper-cpp` og `ffmpeg`.

## Sæt det op med en AI-agent

Det nemmeste. Åbn Claude Code eller Codex i en tom mappe og skriv:

> Følg OPSAETNING_PROMPT.txt i https://github.com/stougaard-plan/diktat og sæt det op på min Mac.

Agenten spørger dig før hver installation og hver store download. Den bruger ikke sudo uden at spørge. Fejler noget, stopper den og forklarer. Den sender ikke lyd eller transskripter nogen steder og læser dem ikke selv.

Husk, at selve agenten er en AI-tjeneste. Det den ser i samtalen, går til udbyderen. Derfor læser den ikke dine optagelser.

## Sæt det op i hånden

Samme trin, uden agent.

1. **Installér Xcode** og åbn det én gang, så du accepterer vilkårene.
2. **Installér værktøjer** (Homebrew skal være der):
   ```
   brew install cmake whisper-cpp ffmpeg
   ```
3. **Hent koden:**
   ```
   git clone https://github.com/stougaard-plan/diktat.git ~/diktat
   cd ~/diktat
   ```
4. **Tjek Xcode, og byg whisper.cpp** (ca. 1,5 GB, nogle minutter, kun til macOS):
   ```
   make check
   make whisper
   ```
   `make check` henter intet. Mangler Metal-komponenten (ca. 700 MB), så står der, hvad du skal køre selv.
5. **Lav et lokalt signeringscertifikat** (anbefalet). Det er dit eget, gratis, og gælder kun på din Mac. Scriptet spørger, før det ændrer noget:
   ```
   make signing
   ```
   Springer du det over, signeres appen "ad hoc". Så spørger macOS igen om mikrofon, systemlyd og tilgængelighed efter hver ny build.
6. **Byg appen** (første gang tog ca. 5 minutter hos os, regn med op til en halv time):
   ```
   make local
   ```
   Mangler Xcode en Metal-komponent, så kør `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -downloadComponent MetalToolchain` (ca. 700 MB, samme Xcode som bygningen) og byg igen. `make check` fanger det før bygningen. Vil du bygge uden certifikat (trin 5 sprunget over eller droppet), så skriv `DIKTAT_CODESIGN_IDENTITY=- make local`.
7. **Læg appen på plads:**
   ```
   mkdir -p ~/Applications
   ditto .local-build/Build/Products/Release/Diktat.app ~/Applications/Diktat.app
   ```
8. **Hent en dansk sprogmodel** (ca. 547 MiB) til både diktering og møder:
   ```
   mkdir -p ~/.whisper-models "$HOME/Library/Application Support/local.diktat.app/WhisperModels"
   curl --fail --location -o ~/.whisper-models/ggml-large-v3-turbo-q5_0.bin.hentes \
     https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin; echo "curl: $?"
   ls -l ~/.whisper-models/ggml-large-v3-turbo-q5_0.bin.hentes
   ```
   Er `curl` ikke 0, eller er filen ikke 574041195 bytes, så slet `.hentes`-filen og prøv igen. Ellers:
   ```
   mv ~/.whisper-models/ggml-large-v3-turbo-q5_0.bin.hentes ~/.whisper-models/ggml-large-v3-turbo-q5_0.bin
   cp -c ~/.whisper-models/ggml-large-v3-turbo-q5_0.bin "$HOME/Library/Application Support/local.diktat.app/WhisperModels/"
   ```
9. **Åbn appen** og giv tre tilladelser:
   - **Mikrofon.** Så den kan høre dig.
   - **Tilgængelighed.** Så den kan skrive teksten ind ved markøren. Systemindstillinger, Anonymitet og sikkerhed, Tilgængelighed.
   - **Systemlyd.** Så notetakeren kan optage computerens lyd. macOS spørger første gang. Ellers Systemindstillinger, Anonymitet og sikkerhed, Skærm- og systemlydoptagelse.

   Startvinduet kræver én sprogmodel, før du kan trykke Færdig. Har du lagt Whisper-modellen på plads (trin 8), tæller den. Ellers tilbyder vinduet at hente den (ca. 547 MB, anbefalet til dansk). Parakeet V3 er valgfri.
10. **Vælg modellen til dansk:** AI-modeller i sidemenuen, aktiv model "Large v3 Turbo (Quantized)", sprog Dansk.
11. **Prøv:** diktér én sætning i TextEdit. Tryk Control+Option+M, tal i et minut og tryk igen. Transskriptet kommer under Møder.

Stemmeopdeling i møder er valgfri og ikke med i trinene her. Se [scripts/transcribe/README.md](scripts/transcribe/README.md).

## Det der virkede på dansk

Det her er målinger fra et lille hjemmeprojekt, ikke et videnskabeligt forsøg. Stikprøverne er små, en stor del er syntetisk tale (macOS' stemme "Sara"), og de er målt på én Mac og med få stemmer. Brug dem som pejlemærker, ikke som facit. Prøv selv, før du stoler på dem.

| Hvad | Resultat | Begrænsning |
|---|---|---|
| **Parakeet V3 kan ikke låses til dansk.** | 14 af 30 korte klip (1 til 5 ord) kom på forkert sprog. Med bredere optælling op til 18. 3 af 15 klip på 5 til 15 ord. Samme resultat med og uden dansk hint. Hurtig: 50 til 60 ms pr. klip. | Syntetisk tale, 45 klip. Rigtige optagelser af egen stemme gav også engelsk og fransk på korte sætninger. |
| **Whisper large-v3-turbo-q5_0 låst til dansk.** | 0 af 7 egne optagelser og 1 af 45 syntetiske klip på forkert sprog. Ca. 3 sekunder pr. klip. | Tiden er målt med `whisper-cli`. I appen kan den være lavere. De store Whisper-modeller havde almindelige ordfejl på 22 til 39 % på klip med 1 til 5 ord. Tom lyd kan give opdigtede sætninger. |
| **VAD (stemmeaktivitetsfilter) til møder.** | På en 67 sekunders oplæsning tabte modellerne uden VAD en hel sætning. Med VAD tabte ingen. Færrest nøgleordsfejl (6 af 17) og dobbelt så hurtig som den store model. På 9 egne optagelser (1.643 ord) steg andelen af genfundne ord fra 83 til 86 %. | Én oplæsning. VAD kan springe tale over, hvis der er musik under. Med musik på computerlyden gik 23 af 62 ord tabt for den store model. |
| **Oprydning af tekst med en lokal model.** | Ingen af de prøvede modeller bestod kravet (mindst 8 af 10 diktater bedre, intet ændret indhold, højst 2 sekunder). Derfor er oprydning slået fra. | Få og små modeller. Større modeller er ikke prøvet. |
| **Ordforråd som prompt.** | Ingen målbar forskel i fejl. Gjorde det værre, når Whisper fik lov at bruge forrige tekst som kontekst. | Én oplæsning, 17 nøgleord. |
| **Ordbog og erstatninger.** | Erstatninger virker til faste navne, fx en stavemåde af et firmanavn. En ordbog på 21 ord ændrede fagordstesten fra 10 til 8 fejl, og fejlene skiftede. | Få ord, én test. |
| **Mikrofon.** | En USB-mikrofon tæt på (20 cm) gav 86 % rigtige ord. MacBookens egen mikrofon 81 %. Ved 2 meter faldt MacBooken til 51 %, USB-mikrofonen til 77 %. | Én oplæsning pr. mikrofon og afstand, 43 ord. Forskellen mellem de to var ét ord ved 60 cm. En tredje, billig USB-mikrofon gav 65 %. |

Mødetransskription tager ca. 16 sekunder pr. minut lyd uden stemmeopdeling og ca. 29 sekunder med, målt på en MacBook med Apple silicon.

### Prøv selv andre modeller

- Under AI-modeller i appen kan du hente andre Whisper-modeller og vælge dem som aktive.
- Til møder bruger du en anden model med `--model` i `scripts/transcribe/moede_transcribe.py`. Læg filen `ggml-<navn>.bin` i `~/.whisper-models`. Appen sender modelnavnet videre, og du ændrer det med `defaults write local.diktat.app MeetingTranscribeModel <navn>`, fx `large-v3-turbo-q5_0` (uden `ggml-` og `.bin`).
- I mappen `scripts/benchmark-sprog` ligger de scripts, der er brugt til at måle forkert sprog på korte klip. De bruger macOS' `say`, ingen optagelser.
- Mål på din egen stemme og dit eget mikrofonmiljø. Lav 10 korte sætninger, læs dem op, og tæl selv, hvad der går galt.

## Dansk talemodel (valgfri): Edda

Edda v0.2 large er en dansk Whisper-model fra Alexandra Instituttet (udgivet af Danish Foundation Models) under Apache-2.0: https://huggingface.co/danish-foundation-models/edda-v0.2-large. Den følger ikke med i repoet. Du henter den selv og laver den om til det format, appen bruger.

**Hvorfor.** I vores måling (100 klip fra FLEURS dansk, `ggml-large-v3-turbo-q5_0` mod Edda i q5_0) havde Edda ca. halvt så mange ordfejl: 7,7 % mod 13,7 %. På en oplæsning med fagord var forskellen lille i procent (16 mod 17 %), men Edda fik flere af fagordene rigtige (6 mod 11 forkerte). Edda skriver mere ordret, med «øh» og gentagelser, og den skriver tal som ord («paragraf nitten», ikke «§ 19»). Den er ca. 1,6 til 1,9 gange langsommere end turbo. Husk, at modelkortet siger, at Edda er trænet med FLEURS, så målingen favoriserer den. Prøv selv på din egen stemme.

**Du skal bruge en udgave af appen fra november 2026 eller nyere** (den med `AudioChunker.swift`). Edda har ikke tidsstempel-tokens. Ældre udgaver kører Whisper med tidsstempler, og så gentager Edda afkodningen mange gange og bliver meget langsom eller taber tekst. Nu kører appen uden tidsstempler, og lyd over 28 sekunder deles ved det stilleste sted mellem 20 og 28 sekunder, så Whisper ikke springer tekst over ved sin 30-sekunders-grænse. Delingen sker uden overlap og kan i sjældne tilfælde ramme midt i et ord, hvis du ikke holder en pause. Det gælder for alle modeller, også turbo.

Det gælder diktering. Mødetransskription bruger sin egen model og er ikke prøvet med Edda.

Plads: regn med ca. 15 GB ledig, mens du laver modellen (vægtene fylder 3 GB, og Python-pakkerne flere). Slet mappen bagefter. Selve modellen fylder 1,1 GB.

Det forudsætter opsætningen ovenfor: Homebrew, Xcode (med kommandolinjeværktøjerne) og en bygget app (`make whisper` og `make local`).

1. **Lav en arbejdsmappe og et Python-miljø.** Torch og coremltools følger ikke altid med den nyeste Python, så vi bruger 3.12:
   ```
   brew install uv
   mkdir -p ~/edda && cd ~/edda
   uv venv --python 3.12 venv
   uv pip install --python venv/bin/python "torch==2.15.*" "transformers==5.23.*" "numpy==2.5.*" "coremltools==9.0.*" openai-whisper ane_transformers huggingface_hub
   ```
   Versionerne er låst til dem, det er prøvet med. coremltools skriver, at torch er nyere end det, der er testet. Det virkede alligevel.
2. **Hent whisper.cpp's konverteringsscripts** i den samme version som appen (samme linje som `WHISPER_CPP_REF` i Makefile), og OpenAIs repo (bruges til mel-filtre):
   ```
   git clone https://github.com/ggerganov/whisper.cpp.git
   git -C whisper.cpp checkout 482279b8a18855ba741d7b88c30fcb3874691f59
   git clone --depth 1 https://github.com/openai/whisper.git whisper-openai
   ```
3. **Hent modellen** (3,1 GB) fra Hugging Face. Det sker i terminalen og ikke i appen, så appens egen netværksliste ændrer sig ikke:
   ```
   mkdir -p model out
   ok=ja
   for f in added_tokens.json config.json generation_config.json merges.txt normalizer.json preprocessor_config.json special_tokens_map.json tokenizer.json tokenizer_config.json vocab.json model.safetensors; do
     curl --fail --location -o model/$f https://huggingface.co/danish-foundation-models/edda-v0.2-large/resolve/main/$f || { ok=nej; echo "FEJL: $f blev ikke hentet"; break; }
   done
   echo "Alle filer hentet: $ok"
   ```
   Fortsæt kun, hvis der står `Alle filer hentet: ja`. Ellers: slet mappen `model` og kør trinnet igen.
4. **Lav den om til ggml** (ca. 15 sekunder, giver en fil på 3,1 GB):
   ```
   venv/bin/python whisper.cpp/models/convert-h5-to-ggml.py model whisper-openai out
   ```
5. **Gør den mindre med q5_0** (ca. 6 sekunder, 1,1 GB). `whisper-quantize` følger med `brew install whisper-cpp` fra opsætningen ovenfor:
   ```
   whisper-quantize out/ggml-model.bin out/ggml-edda-v0.2-large-q5_0.bin q5_0
   ```
   Vil du prøve den uden appen først: `whisper-cli -m out/ggml-edda-v0.2-large-q5_0.bin -l da -nt -f <din-lydfil>.wav` (16 kHz, mono). Brug `-nt`, ellers hænger Edda, som beskrevet ovenfor.
6. **Læg modellen i appen.** Enten under AI-modeller med «Hent lokal model ind…» og vælg `ggml-edda-v0.2-large-q5_0.bin`, eller kopiér filen selv og start appen igen:
   ```
   mkdir -p "$HOME/Library/Application Support/local.diktat.app/WhisperModels"
   cp -c out/ggml-edda-v0.2-large-q5_0.bin "$HOME/Library/Application Support/local.diktat.app/WhisperModels/"
   ```
7. **Vælg den til diktering.** Under AI-modeller (aktiv model, gælder tilstanden «Diktering») vælger du `ggml-edda-v0.2-large-q5_0`. Vil du tilbage, vælger du `ggml-large-v3-turbo-q5_0` igen.

### Hurtigere med Core ML-encoder (valgfrit)

En Core ML-encoder gør Edda ca. 20 % hurtigere (appens tid for 30 sekunders diktat, målt på en MacBook med Apple silicon). Den første indlæsning efter at du har lagt den på plads tager et halvt til et helt minut, fordi macOS oversætter modellen én gang. Filen skal hedde modellens navn uden `-q5_0`, efterfulgt af `-encoder.mlmodelc`, og ligge ved siden af `.bin`-filen. Appens whisper.cpp bygges med Core ML (`make whisper`), så den finder filen af sig selv.

```
cd ~/edda/whisper.cpp
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
PATH="$HOME/edda/venv/bin:$PATH" python models/convert-h5-to-coreml.py --model-name large-v3 --model-path "$HOME/edda/model" --encoder-only True --quantize True
xcrun coremlc compile models/coreml-encoder-large-v3.mlpackage models/
mv models/coreml-encoder-large-v3.mlmodelc "$HOME/edda/out/ggml-edda-v0.2-large-encoder.mlmodelc"
cp -c -R "$HOME/edda/out/ggml-edda-v0.2-large-encoder.mlmodelc" "$HOME/Library/Application Support/local.diktat.app/WhisperModels/"
```

Konverteringen tager ca. 4 minutter og giver en mappe på 1,2 GB. `--model-name large-v3` siger kun, at Edda har samme opbygning som Whisper large-v3. Vil du ikke have den, sletter du mappen `ggml-edda-v0.2-large-encoder.mlmodelc` i WhisperModels. Så kører appen som før.

**Hvad der er prøvet, og hvad der ikke er.** Trin 1 til 5 og Core ML-konverteringen er kørt fra bunden 16/11-2026 på macOS 26.3 med Apple silicon. Modellen er prøvet med `whisper-cli` på en kort dansk sætning, også med Core ML-encoderen. Trin 6 og 7 (valg i appen) er ikke kørt i en ren bygning af den offentlige udgave. De bygger på kildekoden og på brug af den samme rettelse i den app, vi selv bruger.

## Status og begrænsninger

Det her er et tidligt værktøj, ikke et færdigt produkt.

- Notetakeren er brugt i få rigtige møder, op til ca. 30 minutter. Møder på 1 til 2 timer er ikke prøvet.
- Deling af skærm i Teams er ikke prøvet. Panelerne er prøvet med macOS' egen skærmoptagelse. AirPods og skift af lydenhed under et møde er ikke prøvet.
- Stemmeopdelingen er ikke bevist. I en test delte den én stemme i tre. Regn ikke med, at "De 1" og "De 2" er forskellige personer.
- **Læs teksten efter.** Tal, navne, fagord og paragraffer kan være forkerte. Modellen kan finde på sætninger i tavse stykker. Brug ikke et tal eller et citat, før du har hørt stedet i optagelsen.
- Oprydning og automatisk mødetitel er slået fra, og de er kun prøvet på få eksempler.
- Appen er prøvet på én Mac (macOS 26.3, Apple silicon). Opsætningen på en anden Mac er forberedt, men er ikke prøvet på en fremmed Mac.
- Ingen slettefrister. Lyd og transskripter ligger i `~/Moeder`, til du selv sletter dem.

## Samtykke og optagelse

Du har selv ansvaret for at oplyse om, at du optager.

- **Sig det højt**, før du starter, og giv de andre en chance for at sige nej. Notetakeren optager lokalt. Teams og Zoom viser derfor ikke selv, at der optages.
- **Tavshed er ikke samtykke.**
- Er der **følsomme oplysninger** i mødet, eller er de andre **borgere** eller ikke fagfolk, så få et aktivt "ja" først. Hvis nogen ikke vil, så optag ikke.
- Optag kun møder, du selv deltager i.
- Slet lyd og transskripter, når du ikke skal bruge dem mere.

Det her er ikke juridisk rådgivning. Reglerne er fra dansk ret efter Datatilsynets vejledning om optagelse af digitale møder, læst i november 2026. Andre lande har andre regler. Har du et konkret tvivlsspørgsmål, så spørg en jurist.

## Hvad forlader din Mac

Efter gennemgang af kildekoden sender appen ikke lyd eller tekst til nogen tjeneste. Trafikken er ikke målt under kørsel (se [NETVAERK.md](NETVAERK.md)). Der er ingen konto, ingen licensserver, ingen telemetri og ingen automatisk opdatering. Det eneste netværk er:

1. **Modeldownload fra huggingface.co,** når du selv trykker på en hentning: Whisper large-v3-turbo-q5_0 (eller Parakeet V3) i startvinduet, andre Whisper-modeller under AI-modeller.
2. **Valgfri Ollama,** hvis du selv slår mødetitel eller oprydning til og peger på din Ollama. Standardadressen er din egen Mac (127.0.0.1:11434). En adresse på dit eget lokalnet kræver, at du slår "Tillad anden maskine på mit netværk" til. Teksten går da uden kryptering over HTTP.
3. **Valgfri stemmeopdeling:** pyannote henter sine modeller fra huggingface.co første gang, og kun hvis du selv har installeret den.
4. **Under bygning:** Swift-pakker og whisper.cpp hentes fra GitHub. Det sker ikke i den færdige app.

Den fulde liste med filer og linjer står i [NETVAERK.md](NETVAERK.md). Den er læst i kildekoden og ikke målt under kørsel.

## Kreditering

- [VoiceInk](https://github.com/Beingpax/VoiceInk) af Pax (Beingpax), GPL v3. Det er Pax' arbejde, der er grundlaget for alt her.
- [whisper.cpp](https://github.com/ggml-org/whisper.cpp) og OpenAI Whisper, MIT.
- [FluidAudio](https://github.com/FluidInference/FluidAudio), Apache 2.0, og NVIDIAs model [parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), CC-BY-4.0, konverteret til CoreML af FluidInference.
- [Silero VAD](https://github.com/snakers4/silero-vad) (snakers4), MIT.
- SenseVoice Small (FunAudioLLM / Alibaba), FunASR Model Open Source License Agreement, https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE. Hentes af brugeren.
- [pyannote.audio](https://github.com/pyannote/pyannote-audio) og modellerne fra pyannote, når du slår stemmeopdeling til.
- [Edda v0.2 large](https://huggingface.co/danish-foundation-models/edda-v0.2-large) fra Alexandra Instituttet (Danish Foundation Models), Apache 2.0, hvis du selv vælger den. Den følger ikke med i repoet.

Licenser for alle dele og modeller står i [NOTICE](NOTICE). Det der ikke er verificeret, er mærket ANTAGET.

## Ansvar

Diktat leveres som det er, uden garanti og uden support. Du er selv ansvarlig for, at optagelse, opbevaring og brug af lyd og tekst overholder gældende regler. Udgiveren hæfter ikke for fejl i transskriptioner eller for tab, som opstår ved brug, i det omfang loven tillader det, herunder produktansvarsloven.

## Licens

GNU General Public License version 3 (kun v3). Se [LICENSE](LICENSE), som er den fulde tekst af GPL v3. Udgivet af Stougaard Plan ApS (CVR 45908941). Du må bruge, ændre og dele Diktat, hvis du giver modtageren samme rettigheder og kildekoden. Ændringsnoten (GPL §5a) står i [NOTICE](NOTICE).
