import Foundation

// B1 og B2: skærmlæsning (OCR) starter kun med tilvalget «Skærm», og ordlisten forlader ikke denne Mac uden tilvalg.
// Ingen skærm, ingen netværk. Skærmlæsningen og tilladelsen er udskiftet med falske.

var failures = 0
func check(_ c: Bool, _ m: String) { print(c ? "OK   " : "FEJL ", m); if !c { failures += 1 } }
func u(_ s: String) -> URL { URL(string: s)! }

final class Counter: @unchecked Sendable { var n = 0 }

@MainActor
func run() async {
    let saved = RecordingVocabulary(savedTerms: ["Hemmeligfirma", "Lokalplan"])

    // ---- B1: OCR ----
    func capture(enabled: Bool, permission: Bool) async -> (ocrCalls: Int, snapshotText: String?, names: [String]) {
        let store = RecordingContextSnapshotStore(savedVocabulary: saved)
        let calls = Counter()
        let tasks = RecordingContextCaptureService.startCapture(
            into: store, language: "en", screenCaptureEnabled: enabled,
            hasPermission: { permission },
            extractText: { calls.n += 1; return "Meeting with Testperson Eksempelsen from Eksempelfirma A/S in Copenhagen about the project" })
        for t in tasks { await t.value }
        // Navneudtræk kører videre i en baggrundsopgave (første brug af NLTagger kan tage et øjeblik). Vent højst 8 s,
        // men kun hvis der er tekst at udtrække fra.
        if enabled, permission {
            for _ in 0..<80 where store.vocabularyPreparation.current.screenNames.isEmpty {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        } else {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        let names = store.vocabularyPreparation.finish().screenNames
        return (calls.n, store.snapshot.screenText, names)
    }
    let off = await capture(enabled: false, permission: true)
    check(off.ocrCalls == 0, "B1: «Skærm» fra, macOS-tilladelse givet: OCR starter IKKE (\(off.ocrCalls) kald)")
    check(off.snapshotText == nil && off.names.isEmpty, "B1: «Skærm» fra: ingen skærmtekst og ingen skærmnavne i ordlisten")
    let on = await capture(enabled: true, permission: true)
    check(on.ocrCalls == 1 && on.snapshotText != nil, "B1: «Skærm» til og tilladelse givet: OCR kører én gang")
    check(!on.names.isEmpty, "B1: «Skærm» til: navne fra skærmen kommer i ordlisten (\(on.names))")
    let noPerm = await capture(enabled: true, permission: false)
    check(noPerm.ocrCalls == 0, "B1: «Skærm» til men ingen macOS-tilladelse: OCR starter ikke")

    // ---- B2: hvad må med til Ollama ----
    let withScreen = RecordingVocabulary(savedTerms: ["Hemmeligfirma", "Lokalplan"], screenNames: ["Testperson Eksempelsen"])
    func terms(_ v: RecordingVocabulary) -> [String] { v.terms }
    let local = u("http://127.0.0.1:11434")
    let lan = u("http://192.168.1.20:11434")
    check(terms(withScreen.forOllama(useScreenCapture: true, ollamaURL: local, sendVocabularyToRemote: false)) == ["Hemmeligfirma", "Lokalplan", "Testperson Eksempelsen"],
          "B2: denne Mac + «Skærm» til: ordliste og skærmnavne går med")
    check(terms(withScreen.forOllama(useScreenCapture: false, ollamaURL: local, sendVocabularyToRemote: false)) == ["Hemmeligfirma", "Lokalplan"],
          "B1/B2: denne Mac + «Skærm» fra: skærmnavne går IKKE med, ordlisten gør")
    check(terms(withScreen.forOllama(useScreenCapture: true, ollamaURL: lan, sendVocabularyToRemote: false)).isEmpty,
          "B2: anden maskine uden særskilt tilvalg: hverken ordliste eller skærmnavne")
    check(terms(withScreen.forOllama(useScreenCapture: true, ollamaURL: lan, sendVocabularyToRemote: true)) == ["Hemmeligfirma", "Lokalplan", "Testperson Eksempelsen"],
          "B2: anden maskine med særskilt tilvalg og «Skærm» til: alt går med")
    check(terms(withScreen.forOllama(useScreenCapture: false, ollamaURL: lan, sendVocabularyToRemote: true)) == ["Hemmeligfirma", "Lokalplan"],
          "B2: anden maskine med tilvalg men «Skærm» fra: kun ordlisten")
    check(terms(withScreen.forOllama(useScreenCapture: true, ollamaURL: nil, sendVocabularyToRemote: false)).isEmpty,
          "B2: ukendt adresse regnes som anden maskine")
    check(!withScreen.forOllama(useScreenCapture: true, ollamaURL: lan, sendVocabularyToRemote: false).enhancementSection.contains("Hemmeligfirma"),
          "B2: ordlisten står ikke i den tekst, der sendes (enhancementSection)")
    check(withScreen.terms == ["Hemmeligfirma", "Lokalplan", "Testperson Eksempelsen"], "lokal brug (Whisper-prompt, rettelser) bevarer hele ordforrådet")

    // ---- P1: assistentens samtale nulstilles, når adresse eller samtykke ændres ----
    let base = AssistantPrivacyKey(baseURL: "http://127.0.0.1:11434", allowRemote: false, sendVocabularyToRemote: false)
    check(base == AssistantPrivacyKey(baseURL: " http://127.0.0.1:11434 ", allowRemote: false, sendVocabularyToRemote: false),
          "P1: samme indstillinger giver samme nøgle (mellemrum ignoreres)")
    check(base != AssistantPrivacyKey(baseURL: "http://192.168.1.20:11434", allowRemote: false, sendVocabularyToRemote: false),
          "P1: ændret adresse giver anden nøgle")
    check(base != AssistantPrivacyKey(baseURL: "http://127.0.0.1:11434", allowRemote: true, sendVocabularyToRemote: false),
          "P1: ændret «tillad anden maskine» giver anden nøgle")
    check(base != AssistantPrivacyKey(baseURL: "http://127.0.0.1:11434", allowRemote: false, sendVocabularyToRemote: true),
          "P1: ændret tilvalg til ordliste giver anden nøgle")
    check(!base.remote && AssistantPrivacyKey(baseURL: "http://192.168.1.20:11434", allowRemote: true, sendVocabularyToRemote: false).remote
          && AssistantPrivacyKey(baseURL: "ikke en adresse", allowRemote: false, sendVocabularyToRemote: false).remote,
          "P1: nøglen ved, om adressen er en anden maskine (ukendt adresse regnes som anden maskine)")

    print(failures == 0 ? "ALLE TESTS BESTÅET" : "\(failures) FEJL")
    exit(failures == 0 ? 0 : 1)
}
Task { @MainActor in await run() }
RunLoop.main.run()
