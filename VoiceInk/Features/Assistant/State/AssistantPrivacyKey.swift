import Foundation

/// Det, der afgør, hvad en samtale med assistenten må sende til Ollama: adressen, om den er en anden maskine,
/// om anden maskine er tilladt, og om ordlisten må med dertil. Systemprompten i en samtale kan indeholde ordlisten.
/// Derfor gemmes nøglen, da samtalen startede, og sammenlignes før hvert kald. Er den ændret, nulstilles samtalen.
struct AssistantPrivacyKey: Equatable {
    let baseURL: String
    let remote: Bool
    let allowRemote: Bool
    let sendVocabularyToRemote: Bool

    init(baseURL: String, allowRemote: Bool, sendVocabularyToRemote: Bool) {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = trimmed
        self.remote = URL(string: trimmed).map { OllamaHostPolicy.isRemote($0) } ?? true
        self.allowRemote = allowRemote
        self.sendVocabularyToRemote = sendVocabularyToRemote
    }

    /// Nøglen lige nu, aflæst fra indstillingerne.
    @MainActor
    static func current(baseURL: String) -> AssistantPrivacyKey {
        AssistantPrivacyKey(baseURL: baseURL,
                            allowRemote: OllamaHostPolicy.allowRemote,
                            sendVocabularyToRemote: OllamaHostPolicy.sendVocabularyToRemote)
    }
}
