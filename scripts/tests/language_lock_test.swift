import Foundation
var fails = 0
func check(_ c: Bool, _ m: String) { print(c ? "OK   " : "FEJL ", m); if !c { fails += 1 } }
typealias L = TranscriptionLanguageLock
let w = L.info(provider: "Whisper", modelName: "ggml-large-v3", language: "da", isMultilingual: true)
check(w.strength == .locked && w.text.contains("Låst"), "Whisper + dansk: låst")
let p = L.info(provider: "Parakeet", modelName: "parakeet-tdt-0.6b-v3", language: "da", isMultilingual: true)
check(p.strength == .hintOnly && p.text.contains("Kan ikke låses") && p.text.contains("Whisper"), "Parakeet V3 + dansk: ærligt ikke låst, peger på Whisper")
let e = L.info(provider: "Parakeet", modelName: "parakeet-tdt-0.6b-v2", language: "en", isMultilingual: false)
check(e.strength == .notSupported && e.text.contains("kun engelsk"), "Parakeet V2: kun engelsk")
let a = L.info(provider: "Whisper", modelName: "ggml-small", language: "auto", isMultilingual: true)
check(a.strength == .notSupported && a.text.contains("gætter"), "automatisk sprog: ikke låst")
let n = L.info(provider: "Native Apple", modelName: "apple-speech", language: "da-DK", isMultilingual: true)
check(n.strength == .locked, "Apple Speech: låst via locale")
let name: (String) -> String = { $0 == "da" ? "Dansk" : ($0 == "en" ? "Engelsk" : $0) }
check(L.overrideNotes(effectiveModeName: "Dictation", effectiveLanguage: "da", chosenLanguage: "da", otherModes: [], displayName: name).isEmpty, "ingen overstyring, når alt er dansk")
let o = L.overrideNotes(effectiveModeName: "Dictation", effectiveLanguage: "en", chosenLanguage: "da", otherModes: [("Mail", "en"), ("Notat", "da")], displayName: name)
check(o.count == 2 && o[0].contains("overstyrer") && o[1].contains("Mail"), "aktiv mode og anden mode på engelsk giver to tydelige noter")
print(fails == 0 ? "ALLE TESTS BESTÅET" : "\(fails) FEJL"); exit(fails == 0 ? 0 : 1)
