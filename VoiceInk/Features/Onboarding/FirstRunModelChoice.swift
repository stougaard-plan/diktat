import Foundation

/// Hvilken sprogmodel første opstart kræver og vælger. Ren logik uden afhængigheder, så den kan prøves for sig.
///
/// Kravet er EN brugbar model: enten en installeret Whisper-model eller Parakeet V3. Nej til Parakeet blokerer ikke.
/// Til dansk anbefales Whisper large-v3-turbo-q5_0, fordi Parakeet V3 ikke kan låses til dansk.
enum FirstRunModelChoice {
    static let recommendedWhisperName = "ggml-large-v3-turbo-q5_0"
    static let parakeetName = "parakeet-tdt-0.6b-v3"

    /// Kan brugeren trykke «Færdig»?
    static func isReady(parakeetReady: Bool, installedWhisperNames: [String]) -> Bool {
        parakeetReady || !installedWhisperNames.isEmpty
    }

    /// Navnet på den model, der bliver standard. Whisper går forud for Parakeet, og turbo-q5 går forud for andre Whisper-modeller.
    /// Flersprogede Whisper-modeller går forud for engelske (.en).
    static func chosenModelName(parakeetReady: Bool, installedWhisperNames: [String]) -> String? {
        let whisper = installedWhisperNames.sorted()
        if whisper.contains(recommendedWhisperName) { return recommendedWhisperName }
        if let multilingual = whisper.first(where: { !$0.hasSuffix(".en") }) { return multilingual }
        if let first = whisper.first { return first }
        return parakeetReady ? parakeetName : nil
    }
}
