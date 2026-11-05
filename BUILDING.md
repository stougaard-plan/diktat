# Bygge Diktat

Kort version. Hele forløbet står i README.md og i OPSAETNING_PROMPT.txt.

## Krav

- Mac med Apple silicon. Prøvet kun på macOS 26.3 med Xcode 26.6. Projektet siger macOS 15 som mindstekrav, men det er ikke prøvet.
- Xcode (gratis med Apple-id) og git
- cmake til whisper.cpp (`brew install cmake`)

## Trin

```bash
git clone https://github.com/stougaard-plan/diktat.git
cd diktat
make check       # tjekker Xcode-version, macOS-SDK og Metal-komponenten. Henter intet.
make whisper     # bygger whisper.xcframework KUN til macOS i ~/VoiceInk-Dependencies, ca. 5 til 10 minutter
make signing     # valgfrit, opretter et lokalt certifikat (spørger først) så tilladelserne består
make local       # bygger appen
```

Appen ligger bagefter i `.local-build/Build/Products/Release/Diktat.app`. Læg den i `~/Applications`.

## Signering

`make signing` opretter et selvsigneret certifikat i din egen nøglering, efter at du har svaret ja. Det er ikke Apples og ikke andres. Uden det signeres appen "ad hoc", og macOS spørger igen om mikrofon, systemlyd og tilgængelighed efter hver ny build.

Projektet har intet udviklerteam og ingen Apple-udviklerkonto bagved. Navnet på certifikatet sammenlignes bogstaveligt. Findes der flere certifikater med samme navn, stopper scriptet og vælger ikke selv.

## Andre byggemåder

`scripts/build-diktat.sh` kan tage miljøvariabler:

- `DIKTAT_CODESIGN_IDENTITY=-` tvinger ad hoc-signering. Brug den, hvis du bygger uden certifikat: `DIKTAT_CODESIGN_IDENTITY=- make local`.
- `DIKTAT_CODESIGN_IDENTITY=<navn eller hash>` bruger en bestemt identitet.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` vælger Xcode. Uden værdi bruges `/Applications/Xcode.app`, ellers det Xcode, `xcode-select -p` peger på. Makefilen og scriptet eksporterer det til alle byggetrin.

Åbner du `VoiceInk.xcodeproj` i Xcode i stedet, bygges også, men uden de lokale indstillinger og uden den lokale signering. Projektet har intet udviklerteam. Vælg selv under Signing & Capabilities enten dit eget team eller "Sign to Run Locally".

## Hvis det går galt

- `make check` viser hvilket værktøj der mangler, inklusive macOS-SDK og Metal-komponenten.
- Fejlen "missing Metal Toolchain" eller "Metal-komponenten mangler": kør `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -downloadComponent MetalToolchain` (ca. 700 MB, samme Xcode som bygningen). Det sker ikke af sig selv.
- whisper.cpp bygges kun til macOS (`scripts/build-whisper-macos.sh`). Du behøver ikke iOS-, tvOS- eller visionOS-platformene i Xcode.
