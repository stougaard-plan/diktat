import AppKit
import Foundation

/// Selvtest af notetakeren uden klik. Aktiv kun hvis DIKTAT_TEST_MEETING_SECONDS er sat.
/// Bruges sammen med DIKTAT_SIM_COMPUTER / DIKTAT_SIM_MIC (simulerede kilder, se MeetingAudio.swift).
/// 0 = start og lad den køre (til kill-test). Ellers stop efter N sekunder og afslut appen.
///
/// Konstruerede fejl (alle kører den rigtige fejlsti):
///   DIKTAT_TEST_ROOT            anden rodmappe end ~/Moeder (kun sammen med simulerede kilder)
///   DIKTAT_SIM_SILENT           mik | computer | begge: kilden leverer kun nuller
///   DIKTAT_SILENCE_SECONDS      tærskel for digital stilhed (standard 90)
///   DIKTAT_TEST_CHMOD_AT        efter N sek. gøres mødemappen skrivebeskyttet (ægte EACCES på næste segment og journal)
///   DIKTAT_TEST_FAIL_WRITES_AT  efter N sek. fejler alle skrivninger til lydfilen (simuleret diskfejl)
/// Status skrives som linjer med "SELFTEST" til stdout hvert sekund.
enum MeetingSelfTest {
    private static func say(_ text: String) {
        FileHandle.standardOutput.write(Data(("SELFTEST " + text + "\n").utf8))
    }

    /// Genvejens logik mod den rigtige MeetingRecorder med simulerede kilder (kræver DIKTAT_SIM_COMPUTER + DIKTAT_TEST_ROOT).
    /// Selve tastetrykket testes ikke her, kun det controlleren gør ved et tryk.
    @MainActor
    private static func runShortcutScenario(_ recorder: MeetingRecorder) async {
        let controller = MeetingShortcutController.shared
        func step(_ label: String, _ outcome: MeetingShortcutController.Outcome) {
            say("\(label): \(outcome) recording=\(recorder.isRecording) state=\(recorder.state)")
        }
        step("tryk 1 (start)", controller.toggle())
        step("tryk 2 straks efter (dobbelttryk)", controller.toggle())
        try? await Task.sleep(nanoseconds: 700_000_000)
        step("tryk 3 efter 0,7 s", controller.toggle())
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        say("mappe under optagelse: \(recorder.currentFolderName ?? "ingen")")
        step("tryk 4 (stop)", controller.toggle())
        step("tryk 5 straks efter stop", controller.toggle())
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        say("slut: recording=\(recorder.isRecording) meetings=\(recorder.meetings.count)")
        exit(0)
    }

    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let value = env["DIKTAT_TEST_MEETING_SECONDS"] ?? env["DIKTAT_TEST_SHORTCUT"].map({ _ in "0" }), let seconds = Double(value) else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let recorder = MeetingRecorder.shared
            if env["DIKTAT_TEST_SHORTCUT"] != nil {
                await runShortcutScenario(recorder)
                return
            }
            recorder.start(title: "selvtest")
            say("start state=\(recorder.state) recording=\(recorder.isRecording)")
            if env["DIKTAT_TEST_FAKE_SLEEP"] != nil {
                // Syntetisk dvale: kun logikken testes. Mac'en går ikke i dvale.
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
            }
            guard seconds > 0 else { return }
            let chmodAt = env["DIKTAT_TEST_CHMOD_AT"].flatMap(Double.init)
            let failAt = env["DIKTAT_TEST_FAIL_WRITES_AT"].flatMap(Double.init)
            var t = 0.0
            var lockedDir: URL?
            while t < seconds {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                t += 1
                if let chmodAt, t >= chmodAt, lockedDir == nil, let dir = recorder.directoryForTest {
                    lockedDir = dir
                    chmod(dir.path, 0o500)
                    say("t=\(Int(t)) mødemappen gjort skrivebeskyttet")
                }
                if let failAt, t >= failAt, !MeetingSegmentWriter.injectWriteFailure {
                    MeetingSegmentWriter.injectWriteFailure = true
                    say("t=\(Int(t)) skrivefejl slået til")
                }
                say("t=\(Int(t)) problems=\(recorder.problems)")
            }
            // Ryd op, så testmappen kan slettes og den endelige journal kan skrives.
            MeetingSegmentWriter.injectWriteFailure = false
            if let lockedDir { chmod(lockedDir.path, 0o700) }
            recorder.stop()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            // DIKTAT_TEST_WAIT_TRANSCRIPT=<sek>: vent på den automatiske transskription, og skriv tilstanden hvert 5. sekund.
            if let waitSeconds = env["DIKTAT_TEST_WAIT_TRANSCRIPT"].flatMap(Double.init) {
                let transcriber = MeetingTranscriber.shared
                var waited = 0.0
                while waited < waitSeconds, !transcriber.jobs.isEmpty {
                    if Int(waited) % 5 == 0 { say("transskription: \(transcriber.jobs)") }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    waited += 1
                }
                say("transskription slut efter \(Int(waited)) s: jobs=\(transcriber.jobs) besked=\(transcriber.lastMessage ?? "ingen")")
                for m in recorder.meetings { say("mappe \(m.id): \(transcriber.state(for: m.url))") }
            }
            exit(0)
        }
    }
}
