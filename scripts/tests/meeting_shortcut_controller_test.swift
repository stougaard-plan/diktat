import Foundation

@MainActor final class MeetingRecorder: MeetingRecording {
    static let shared = MeetingRecorder()
    var isRecording = false
    var errorMessage: String?
    var currentFolderName: String? { isRecording ? "2026-11-02_test" : nil }
    var hasProblems = false
    var failNextStart = false
    var starts = 0, stops = 0
    func start(title: String) {
        guard !isRecording else { return }   // som den rigtige: start under optagelse er et no-op
        if failNextStart { errorMessage = "Kunne ikke starte optagelsen: simuleret"; return }
        errorMessage = nil; isRecording = true; starts += 1
    }
    func stop(reason: String) { guard isRecording else { return }; isRecording = false; stops += 1 }
}

@MainActor func run() {
    var fails = 0
    func check(_ c: Bool, _ m: String) { print(c ? "OK   " : "FEJL ", m); if !c { fails += 1 } }
    var clock = Date(timeIntervalSince1970: 1_000_000)
    var dictation = false
    var notes: [(String, MeetingShortcutController.Level)] = []
    let rec = MeetingRecorder()
    let c = MeetingShortcutController(recorder: rec, dictationIsUsingMicrophone: { dictation }, now: { clock }, notify: { notes.append(($0, $1)) })

    check(c.toggle() == .started && rec.isRecording && rec.starts == 1, "tryk 1: starter, synlig besked '\(notes.last?.0 ?? "")'")
    clock += 0.2
    check(c.toggle() == .ignoredRapidRepeat && rec.isRecording && rec.starts == 1 && rec.stops == 0, "dobbelttryk 0,2 s efter start: ingen ny optagelse, ingen stop")
    clock += 0.5
    check(c.toggle() == .ignoredRapidRepeat && rec.starts == 1 && rec.stops == 0, "tryk 0,7 s efter start (under start): ignoreret")
    clock += 1.0
    rec.hasProblems = false
    check(c.toggle() == .stopped && !rec.isRecording && rec.stops == 1, "tryk 1,7 s efter start: stopper")
    check(notes.last?.1 == .success && notes.last!.0.contains("gemt") && notes.last!.0.contains("2026-11-02_test"), "stop viser 'gemt' + mappe: '\(notes.last?.0 ?? "")'")
    clock += 0.3
    check(c.toggle() == .ignoredRapidRepeat && !rec.isRecording && rec.starts == 1, "tryk 0,3 s efter stop (under stop): ignoreret, ingen ny optagelse")
    clock += 2
    dictation = true
    let before = notes.count
    check(c.toggle() == .blockedByDictation && !rec.isRecording && rec.starts == 1 && notes.count == before + 1 && notes.last?.1 == .warning, "diktering kører: møde afvist med tydelig besked '\(notes.last?.0 ?? "")'")
    dictation = false
    clock += 0.1
    check(c.toggle() == .started, "efter afvisning kan et nyt tryk straks starte (afvisning tæller ikke som tryk)")
    clock += 2; rec.hasProblems = true
    check(c.toggle() == .stopped && notes.last?.1 == .warning, "stop med sporproblemer: advarsel i stedet for grøn besked")
    clock += 2; rec.failNextStart = true
    if case .startFailed = c.toggle(), notes.last?.1 == .error, !rec.isRecording { check(true, "startfejl vises som fejl: '\(notes.last!.0)'") } else { check(false, "startfejl") }
    rec.failNextStart = false
    // diktering under møde
    clock += 2; _ = c.toggle(); check(rec.isRecording, "møde kører igen")
    let n = notes.count
    c.noteDictationBlockedByMeeting(); c.noteDictationBlockedByMeeting(); c.noteDictationBlockedByMeeting()
    check(notes.count == n + 1, "diktering under møde: én besked, ikke spam (3 kald, \(notes.count - n) besked)")
    print(fails == 0 ? "ALLE TESTS BESTÅET" : "\(fails) FEJL")
    exit(fails == 0 ? 0 : 1)
}
MainActor.assumeIsolated { run() }
