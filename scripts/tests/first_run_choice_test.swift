import Foundation

// C8: kravet i startvinduet er EN brugbar model. Nej til Parakeet blokerer ikke, og installeret Whisper tæller.
var failures = 0
func check(_ c: Bool, _ m: String) { print(c ? "OK   " : "FEJL ", m); if !c { failures += 1 } }
typealias C = FirstRunModelChoice

check(!C.isReady(parakeetReady: false, installedWhisperNames: []), "ingen model: ikke klar")
check(C.isReady(parakeetReady: false, installedWhisperNames: ["ggml-large-v3-turbo-q5_0"]), "kun Whisper installeret: klar (Parakeet skal ikke hentes)")
check(C.isReady(parakeetReady: true, installedWhisperNames: []), "kun Parakeet: klar")
check(C.isReady(parakeetReady: false, installedWhisperNames: ["ggml-tiny"]), "en hvilken som helst Whisper-model tæller")
check(C.chosenModelName(parakeetReady: false, installedWhisperNames: []) == nil, "intet valg uden model")
check(C.chosenModelName(parakeetReady: true, installedWhisperNames: []) == C.parakeetName, "kun Parakeet: Parakeet vælges")
check(C.chosenModelName(parakeetReady: true, installedWhisperNames: ["ggml-large-v3-turbo-q5_0"]) == "ggml-large-v3-turbo-q5_0",
      "Whisper turbo-q5 slår Parakeet (Parakeet kan ikke låses til dansk)")
check(C.chosenModelName(parakeetReady: false, installedWhisperNames: ["ggml-base", "ggml-large-v3-turbo-q5_0", "ggml-tiny.en"]) == "ggml-large-v3-turbo-q5_0",
      "turbo-q5 vælges blandt flere Whisper-modeller")
check(C.chosenModelName(parakeetReady: false, installedWhisperNames: ["ggml-tiny.en", "ggml-base"]) == "ggml-base", "flersproget Whisper slår engelsk-only")
check(C.chosenModelName(parakeetReady: false, installedWhisperNames: ["ggml-tiny.en"]) == "ggml-tiny.en", "kun engelsk-only Whisper: den vælges, så kravet er opfyldt")
check(C.recommendedWhisperName == "ggml-large-v3-turbo-q5_0", "anbefalet model er large-v3-turbo-q5_0")
print(failures == 0 ? "ALLE TESTS BESTÅET" : "\(failures) FEJL")
exit(failures == 0 ? 0 : 1)
