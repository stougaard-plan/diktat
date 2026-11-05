# Netværkskort

Hvad Diktat kan kontakte over nettet, og hvor i koden det sker. Læst i kildekoden i november 2026 og kontrolleret med `strings` på den byggede app. Ikke målt under kørsel med en netværksmonitor. Det er derfor ANTAGET, at pakker som FluidAudio og mlx-swift-lm ikke laver andre kald end dem, der står her.

## Det der er tilbage

| Hvad | Hvem | Hvornår | Hvor i koden |
|---|---|---|---|
| Modeldownload fra huggingface.co (Parakeet V3) | FluidAudio, `ModelHub.download` | Når du trykker Hent model (startvinduet eller AI-modeller) | `Features/ModelLibrary/State/FluidAudioModelManager.swift` |
| Modeldownload fra huggingface.co (Whisper `ggml-*.bin`, evt. CoreML-encoder) | `URLSession` | Når du trykker Hent på en Whisper-model (startvinduet eller AI-modeller) | `Features/ModelLibrary/State/WhisperModelManager.swift`, `Features/ModelLibrary/Models/TranscriptionModel.swift`, `Features/Onboarding/FirstRunView.swift` |
| Modeldownload fra huggingface.co (GGUF-modeller via TranscribeCpp) | `URLSession` | Når du trykker Hent på en sådan model | `Features/ModelLibrary/State/TranscribeCppModelManager.swift`, `Infrastructure/Providers/Transcription/TranscribeCpp/TranscribeCppModelCatalog.swift` |
| Ollama på din egen Mac (127.0.0.1:11434) eller et lokalnet | `URLSession` med adressepolitik og uden omdirigering | Kun hvis du slår oprydning eller mødetitel til. Appen spørger desuden din Ollama-adresse ved opstart for at vise, om den er tilgængelig | `Infrastructure/Providers/Enhancement/Ollama/OllamaService.swift`, `Features/Meeting/MeetingTitleModel.swift`, `Features/Enhancement/State/AIService.swift` |
| pyannote henter modeller fra huggingface.co | Python-scripts | Kun hvis du selv har installeret stemmeopdeling, sat HF_TOKEN og sagt ja til `setup-diarization.sh --hent-modeller` | `scripts/transcribe/interview_transcribe.py` |
| Åbner Systemindstillinger (`x-apple.systempreferences:`) | `NSWorkspace` | Når du trykker på en knap om tilladelser. Intet netværk | `App/VoiceInk.swift`, `Features/Dashboard/Views/DashboardContent.swift` |

Adressepolitikken for Ollama (`OllamaHostPolicy`): standard kun denne Mac. Med "Tillad anden maskine på mit netværk" også lokalnet (10/8, 172.16/12, 192.168/16, 169.254/16, 100.64/10, .local, .lan, .ts.net, navne uden punktum). Offentlige adresser afvises altid. Teksten går over HTTP uden kryptering.

Hvad der går til Ollama, når oprydning er slået til: det dikterede tekststykke (altid), plus kun det du har valgt som sammenhæng i modens indstillinger: markeret tekst, udklipsholder og tekst læst fra skærmen. Ordlisten (dine egne ord) går med som foretrukne stavemåder.

- **Skærmlæsning (OCR)** starter kun, når den aktive mode både bruger oprydning og har «Skærm» slået til. Macs tilladelse til skærmoptagelse er ikke et tilvalg i sig selv. Nye modes har «Skærm» slået fra. Navne, der findes på skærmen, indgår kun i ordlisten til Ollama, når «Skærm» er til.
- **Ordlisten til en anden maskine.** Kører Ollama ikke på denne Mac, sendes hverken ordlisten eller skærmnavne med, før du selv har slået «Send også min ordliste og navne fra skærmen til den anden maskine» til (under oprydning af tekst). Selve diktatet og den valgte sammenhæng går stadig med, når du har tilladt en anden maskine.
- **Adresser.** Navne (fx `hjemmeserver`, `x.local`, `x.ts.net`) slås op, før der sendes noget, og alle svar skal være private adresser eller denne Mac. Et navn, der peger på en offentlig adresse, afvises, og det gør rene tal som `134744072` også. **Rest-risiko, som ikke kan lukkes i appen:** navnet slås op igen, når forespørgslen sendes. Skifter en DNS-server svar mellem de to opslag (DNS rebinding), kan det ikke fanges. Brug en adresse som IP eller et navn, du selv styrer. Teksten sendes i øvrigt over HTTP uden kryptering. Systemets proxy bruges ikke.
- **Egne kommandoer er en undtagelse.** En mode kan have output «Egen kommando». Den kører din egen shell-kommando med dine rettigheder og får den færdige tekst på stdin og i `VOICEINK_TRANSCRIPT` (`Infrastructure/SystemIntegration/Processes/CustomCommandDeliveryRunner.swift`). Hvad kommandoen gør, herunder om den bruger netværket, styrer og tjekker Diktat ikke. Skriv ikke en kommando, du ikke selv har læst.
- **Assistentens samtale (opfølgninger).** Assistenten bruger kun Ollama. Hver opfølgning sender HELE samtalehistorikken igen: dine spørgsmål og assistentens svar indtil nu, plus den systemprompt, samtalen startede med. Systemprompten kan indeholde ordlisten (efter samme regler som ovenfor). Derfor gemmer samtalen, hvad den måtte sende, da den startede: Ollama-adressen, om anden maskine er tilladt, og om ordlisten må med dertil. Før HVERT kald sammenlignes det med indstillingerne lige nu. Er adressen eller et samtykke ændret, **nulstilles samtalen** (du får besked), og der sendes intet. Ændres indstillingerne, mens et kald kører, kasseres svaret, og samtalen nulstilles. Selve samtalen ligger i appens hukommelse, til du lukker assistenten eller appen. Hver tur gemmes desuden i appens historik på din disk (inklusive systemprompt og anmodningslog), som et almindeligt diktat. Det forlader ikke Macen, men det kan indeholde ordlisten.
- **Udklipsholderen.** Alt, hvad Diktat selv lægger på udklipsholderen (indsat tekst, kopiér-knapper, møde-transskriptet, systemoplysninger), skrives med `prepareForNewContents(with: .currentHostOnly)`. Så deles det ikke med andre enheder på din Apple-konto (Universal Clipboard). Der er ingen skrivning til udklipsholderen uden om `ClipboardManager.swift`. Undtagelse: efter en indsættelse gendanner Diktat dit eget tidligere indhold. Det er ikke et transskript, og det gendannes, som macOS plejer.
- **pyannote sender som standard målinger.** Pakken `pyannote.audio` 4.0.7 har målinger slået til i sin egen `config.yaml` (`metrics_enabled: true`, adresse `otel.pyannote.ai`). Variablen hedder `PYANNOTE_METRICS_ENABLED` (læst fra den installerede pakkes `telemetry/metrics.py`), og pakken læser den ved import. Diktats scripts sætter den til `0` FØR import (`interview_transcribe.py`, `hent_stemmemodeller.py`), også hvis dit miljø siger noget andet. Gør du selv noget med pyannote uden om Diktats scripts, skal du sætte den selv.
- **Stemmemodeller hentes kun med særskilt samtykke.** `setup-diarization.sh --hent-modeller` er dit ja til at hente dem fra huggingface.co. Uden det er Hugging Face-nettet slået fra for møde- og interviewscripts (`HF_HUB_OFFLINE=1`), og mangler modellerne, transskriberes mødet uden stemmeopdeling.

Under bygning (ikke i den færdige app): `git clone` af Swift-pakker fra GitHub og af whisper.cpp fra GitHub.

## Det der er fjernet

- Skyudbydere til tekst og tale (OpenAI, Anthropic, Groq, Gemini, Mistral og flere), og styring af API-nøgler.
- Licens- og prøveperiodetjek, opdateringstjek (Sparkle), meddelelser og GitHub-stjerne-opfordring.
- Støtte for modellen VoiceInk-Refine-V1, inklusive den tilhørende XPC-tjeneste og MLX-pakkerne. Årsag: modellens licens tillader kun brug sammen med VoiceInk.
- iCloud/CloudKit. Rammeværket er stadig linket, men alle datalagre er sat til `cloudKitDatabase: .none`, og iCloud-rettigheder er fjernet fra entitlements.
- Eksterne links i brugerfladen. `InfoTip` åbner ikke browseren.

## Kontrol af den byggede app

`strings` på hovedprogrammet og rammeværkerne i det byggede program (5/11-2026) viser disse værter med forbindelse til nettet: `huggingface.co`, `localhost:11434` og `127.0.0.1:11434`. Resten er links i kommentarer og dokumentation i bibliotekerne (fx johndcook.com, opencompute.org og arxiv.org). Programmet har ingen XPC-tjeneste. Ingen spor af Sparkle, licensserver, telemetri eller skyudbydere. Strenge som `com.openai.chat` er app-identifikatorer, som appen bruger til at genkende andre programmer, ikke adresser.

Entitlements `network.client` og `network.server` står i `VoiceInk.local.entitlements`. Appen kører uden sandbox, så de har ingen virkning. Der er ingen kode, der lytter på en port (søgt efter NWListener og lignende).

## Det der ikke er målt

- Netværkstrafik under kørsel (fx med Little Snitch eller `nettop`).
- Om tredjepartspakkerne, når de kører, kontakter andre adresser end Hugging Face.
