import Foundation

/// Det controlleren behøver af mødeoptageren. MeetingRecorder opfylder den, selvtesten bruger en simuleret.
@MainActor
protocol MeetingRecording: AnyObject {
    var isRecording: Bool { get }
    /// Fejltekst, hvis start/stop endte i fejltilstand. nil = ingen fejl.
    var errorMessage: String? { get }
    /// Navn på den igangværende mødemappe (før stop).
    var currentFolderName: String? { get }
    /// Sporproblemer (advarsler) lige nu.
    var hasProblems: Bool { get }
    func start(title: String)
    func stop(reason: String)
}

/// Genvejen Control+Option+M: samme start/stop som knapperne, plus værn mod dobbelttryk og kollision med diktering.
@MainActor
final class MeetingShortcutController {
    enum Level { case info, success, warning, error }

    enum Outcome: Equatable {
        case started
        case stopped
        case ignoredRapidRepeat
        case blockedByDictation
        case startFailed(String)
    }

    static let shared = MeetingShortcutController(
        recorder: MeetingRecorder.shared,
        dictationIsUsingMicrophone: { false },
        now: { Date() },
        notify: { _, _ in })

    /// Tryk inden for dette tidsrum efter et accepteret tryk ignoreres. Fanger dobbelttryk og kontaktprel.
    let rapidRepeatWindow: TimeInterval = 1.5

    private let recorder: MeetingRecording
    private var dictationIsUsingMicrophone: () -> Bool
    private var now: () -> Date
    private var notify: (String, Level) -> Void
    private var lastAcceptedAt: Date?
    private var lastDictationNoticeAt: Date?

    init(
        recorder: MeetingRecording,
        dictationIsUsingMicrophone: @escaping () -> Bool,
        now: @escaping () -> Date,
        notify: @escaping (String, Level) -> Void
    ) {
        self.recorder = recorder
        self.dictationIsUsingMicrophone = dictationIsUsingMicrophone
        self.now = now
        self.notify = notify
    }

    /// Kaldes én gang ved opstart, når motoren og notifikationer findes.
    func configure(
        dictationIsUsingMicrophone: @escaping () -> Bool,
        notify: @escaping (String, Level) -> Void
    ) {
        self.dictationIsUsingMicrophone = dictationIsUsingMicrophone
        self.notify = notify
    }

    @discardableResult
    func toggle() -> Outcome {
        let t = now()
        if let last = lastAcceptedAt, t.timeIntervalSince(last) < rapidRepeatWindow {
            return .ignoredRapidRepeat
        }

        if recorder.isRecording {
            lastAcceptedAt = t
            let folder = recorder.currentFolderName
            let hadProblems = recorder.hasProblems
            recorder.stop(reason: "Stoppet med genvej")
            if let error = recorder.errorMessage {
                notify(error, .error)
            } else if hadProblems {
                notify("Mødeoptagelsen er gemt, men et spor havde problemer. Tjek mappen \(folder ?? "i ~/Moeder").", .warning)
            } else {
                notify("Mødeoptagelsen er stoppet og gemt\(folder.map { " i ~/Moeder/\($0)" } ?? "").", .success)
            }
            return .stopped
        }

        if dictationIsUsingMicrophone() {
            // Ikke en accepteret handling: et nyt tryk lige efter må gerne prøve igen.
            notify("Diktering kører. Stop den først, så kan mødeoptagelsen startes.", .warning)
            return .blockedByDictation
        }

        lastAcceptedAt = t
        recorder.start(title: "")
        if let error = recorder.errorMessage {
            notify(error, .error)
            return .startFailed(error)
        }
        notify("Mødeoptagelse startet. Sig det højt til de andre.", .info)
        return .started
    }

    /// Bruges, når diktering forsøges startet under en mødeoptagelse. Højst én besked pr. 2 sekunder.
    func noteDictationBlockedByMeeting() {
        let t = now()
        if let last = lastDictationNoticeAt, t.timeIntervalSince(last) < 2 { return }
        lastDictationNoticeAt = t
        notify("Mødeoptagelse kører. Diktering er slået fra, til mødet er stoppet.", .warning)
    }
}
