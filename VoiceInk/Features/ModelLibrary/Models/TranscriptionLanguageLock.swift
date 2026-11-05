import Foundation

/// Hvor stærkt et sprogvalg binder den aktive transskriberingsmodel. Rene tekstværdier, så logikken kan testes uden appen.
enum TranscriptionLanguageLock {
    enum Strength: Equatable {
        /// Modellen får sproget med hver optagelse og skriver på det.
        case locked
        /// Sproget sendes som hint, men modellen kan stadig skrive et andet sprog.
        case hintOnly
        /// Modellen vælger selv sprog.
        case notSupported
    }

    struct Info: Equatable {
        let strength: Strength
        let text: String
    }

    /// provider: rå værdi af ModelProvider ("Whisper", "Parakeet", "TranscribeCpp", "Native Apple").
    static func info(provider: String, modelName: String, language: String, isMultilingual: Bool) -> Info {
        if !isMultilingual {
            return Info(
                strength: .notSupported,
                text: "Denne model kan kun engelsk. Vælg en flersproget model for at skrive dansk.")
        }
        if language == "auto" {
            return Info(
                strength: .notSupported,
                text: "Automatisk sprog: modellen gætter selv. Korte sætninger kan ende på et forkert sprog.")
        }
        switch provider {
        case "Whisper":
            return Info(
                strength: .locked,
                text: "Låst: Whisper får sproget med hver optagelse og skriver på det.")
        case "Native Apple":
            return Info(
                strength: .locked,
                text: "Låst: Apple Speech bruger det valgte sprog (locale) til optagelsen.")
        case "Parakeet":
            if modelName.hasPrefix("nemotron") {
                return Info(
                    strength: .hintOnly,
                    text: "Sendes som hint til Nemotron. Hvor stærkt hintet binder modellen, er ikke målt.")
            }
            return Info(
                strength: .hintOnly,
                text:
                    "Kan ikke låses. Parakeet vælger selv sproget ud fra lyden. Valget udelukker kun tegn fra et andet skriftsystem (fx kyrillisk), så korte danske sætninger kan blive til engelsk, tysk eller fransk. Vælg en Whisper-model, hvis sproget skal låses."
            )
        case "TranscribeCpp":
            return Info(
                strength: .hintOnly,
                text: "Sendes til modellen som sprogvalg. Hvor stærkt det binder, er ikke målt.")
        default:
            return Info(strength: .hintOnly, text: "Sproget sendes til modellen. Hvor stærkt det binder, er ikke målt.")
        }
    }

    /// Beskriver en mode, der kan overstyre det viste sprog, når den er aktiv.
    static func overrideNotes(
        effectiveModeName: String?, effectiveLanguage: String?, chosenLanguage: String,
        otherModes: [(name: String, language: String?)], displayName: (String) -> String
    ) -> [String] {
        var notes: [String] = []
        if let effectiveLanguage, effectiveLanguage != chosenLanguage {
            notes.append(
                "Den aktive mode «\(effectiveModeName ?? "")» bruger \(displayName(effectiveLanguage)) og overstyrer valget her.")
        }
        for mode in otherModes where mode.language != nil && mode.language != chosenLanguage {
            notes.append(
                "Mode «\(mode.name)» bruger \(displayName(mode.language ?? "")). Den overstyrer valget, når den bliver aktiv (fx via app eller link).")
        }
        return notes
    }
}
