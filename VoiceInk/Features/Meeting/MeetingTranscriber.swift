import AppKit
import Foundation

/// Status for ét møde i Møder-siden.
enum MeetingTranscriptState: Equatable {
    case none
    case queued(waitingForRecording: Bool)
    case running(step: String, since: Date)
    case ready
    /// Seneste forsøg fejlede. `previousKept` = et ældre transskript ligger stadig uændret.
    case failed(message: String, previousKept: Bool)
}

/// Statusfil i mødemappen (`transskript.status.json`). Skrives kun af appen, aldrig sammen med lydfilerne.
struct MeetingTranscriptStatusFile: Codable {
    var state: String  // running | failed | done
    var message: String?
    var startedAt: Date
    var finishedAt: Date?
    var model: String
    var language: String
    var automatic: Bool
}

/// Kører wrapperen `moede_transcribe.py` efter mødet, ét møde ad gangen. Intet sendes nogen steder.
/// Wrapperen skriver `transskript.txt` atomisk og rører aldrig lydfilerne. Appen skriver kun
/// `transskribering.log` og `transskript.status.json`.
@MainActor
final class MeetingTranscriber: ObservableObject {
    static let shared = MeetingTranscriber()

    /// Møder i kø eller i gang. Alt andet udledes af filerne i mødemappen.
    @Published private(set) var jobs: [String: MeetingTranscriptState] = [:]
    @Published private(set) var lastMessage: String?
    /// Kun om HF_TOKEN findes (talerseparation mulig). Værdien læses aldrig ind i noget, der vises eller gemmes.
    @Published private(set) var diarizationAvailable = false

    /// Sættes af MeetingRecorder. Et nyt job starter ikke, mens en optagelse kører.
    var isRecording: () -> Bool = { false }
    /// Sættes af MeetingRecorder: opdatér mødelisten, når en kørsel er slut.
    var onChange: () -> Void = {}
    /// Sættes af MeetingRecorder: kaldes, når et transskript er færdigt og skrevet (bruges til den automatiske titel).
    var onTranscriptReady: (URL) -> Void = { _ in }
    /// Sand, mens et møde transskriberes eller venter i køen.
    var isBusy: Bool { current != nil || !queue.isEmpty }

    static let defaultModel = "large-v3-turbo-q5_0"
    static let defaultLanguage = "da"
    static let scriptKey = "MeetingTranscribeScript"
    static let modelKey = "MeetingTranscribeModel"
    static let languageKey = "MeetingTranscribeLanguage"

    /// Hvor scriptet ligger, hvis brugeren ikke har valgt et selv. Rækkefølge:
    /// 1. miljøvariablen DIKTAT_TRANSCRIBE_SCRIPT, 2. appens eget bundt (`Resources/transcribe/`, lagt ind af bygget),
    /// 3. `scripts/transcribe/` i repoet, hvis appen ligger i en bygge-mappe inde i repoet.
    /// Intet afhænger af en bestemt mappe eller et bestemt brugernavn.
    static func defaultScriptPath(
        home: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment,
        resourceURL: URL? = Bundle.main.resourceURL, bundleURL: URL = Bundle.main.bundleURL
    ) -> String {
        let fm = FileManager.default
        if let env = environment["DIKTAT_TRANSCRIBE_SCRIPT"], !env.isEmpty { return env }
        let inBundle = resourceURL?.appendingPathComponent("transcribe/moede_transcribe.py").path
        if let inBundle, fm.fileExists(atPath: inBundle) { return inBundle }
        // Bygget ligger i <repo>/.local-build/Build/Products/Release/Diktat.app
        var dir = bundleURL.deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("scripts/transcribe/moede_transcribe.py").path
            if fm.fileExists(atPath: candidate) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return inBundle ?? (home + "/.diktat/transcribe/moede_transcribe.py")
    }

    private let defaults: UserDefaults
    private let environment: [String: String]
    private let home: String
    private let launchctlFallback: Bool
    /// Kun til test.
    var pythonCandidates: [String]?
    private var queue: [URL] = []
    private var current: Process?
    private var currentFolder: URL?
    private var currentSink: LogSink?
    private var terminatingForQuit = false
    private var retryScheduled = false
    private var terminateObserver: NSObjectProtocol?

    init(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        launchctlFallback: Bool = true
    ) {
        self.launchctlFallback = launchctlFallback
        self.defaults = defaults
        self.environment = environment
        self.home = home
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.handleQuit() } }
    }

    // MARK: - Indstillinger

    var scriptPath: String { defaults.string(forKey: Self.scriptKey) ?? Self.defaultScriptPath(home: home) }
    var model: String { defaults.string(forKey: Self.modelKey) ?? Self.defaultModel }
    var language: String {
        let v = defaults.string(forKey: Self.languageKey) ?? Self.defaultLanguage
        return ["da", "en", "auto"].contains(v) ? v : Self.defaultLanguage
    }

    func setLanguage(_ code: String) {
        defaults.set(code, forKey: Self.languageKey)
        objectWillChange.send()
    }

    func setScriptPath(_ path: String?) {
        if let path { defaults.set(path, forKey: Self.scriptKey) } else { defaults.removeObject(forKey: Self.scriptKey) }
        objectWillChange.send()
    }

    var modelDescription: String { "Whisper \(model) (kvantiseret turbo-model, med stemmeaktivitetsfilter)" }

    // MARK: - Tilstand

    func state(for folder: URL) -> MeetingTranscriptState {
        if let job = jobs[folder.lastPathComponent] { return job }
        let fm = FileManager.default
        let transcript = folder.appendingPathComponent("transskript.txt")
        let hasTranscript = fm.fileExists(atPath: transcript.path)
        if let status = readStatus(folder), status.state == "failed" {
            let tDate = (try? transcript.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            // Et transskript, der er klart nyere end fejlen (fx fra en forældreløs kørsel), vinder. Statusfilen har kun sekunders præcision.
            if !(hasTranscript && tDate != nil && tDate! > (status.finishedAt ?? status.startedAt).addingTimeInterval(2)) {
                return .failed(message: status.message ?? "Transskriptionen fejlede.", previousKept: hasTranscript)
            }
        }
        return hasTranscript ? .ready : .none
    }

    func readStatus(_ folder: URL) -> MeetingTranscriptStatusFile? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("transskript.status.json")) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(MeetingTranscriptStatusFile.self, from: data)
    }

    private func writeStatus(_ folder: URL, _ status: MeetingTranscriptStatusFile) {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? e.encode(status).write(to: folder.appendingPathComponent("transskript.status.json"), options: .atomic)
    }

    /// Ved opstart: en kørsel, der stod som "running", men ikke kører, blev afbrudt (appen blev lukket).
    func recoverStale(in root: URL) {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs where dir.hasDirectoryPath {
            guard jobs[dir.lastPathComponent] == nil, var s = readStatus(dir), s.state == "running" else { continue }
            s.state = "failed"
            s.finishedAt = Date()
            s.message = "Transskriptionen blev afbrudt, fordi appen blev lukket. Tryk Transskribér igen."
            writeStatus(dir, s)
        }
    }

    // MARK: - Kø

    /// Lægger et møde i køen. `automatic` = lige efter en normal stop. Returnerer false, hvis mødet allerede er i kø.
    @discardableResult
    func enqueue(folder: URL, automatic: Bool) -> Bool {
        let id = folder.lastPathComponent
        guard jobs[id] == nil else { return false }
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("meta.json").path) else {
            lastMessage = "Mødemappen mangler meta.json, så den kan ikke transskriberes: \(folder.path)"
            return false
        }
        lastMessage = nil
        jobs[id] = .queued(waitingForRecording: false)
        queue.append(folder)
        autoFlags[id] = automatic
        pump()
        return true
    }

    private var autoFlags: [String: Bool] = [:]

    private func pump() {
        guard current == nil, let folder = queue.first else { return }
        if isRecording() {
            // Tung kørsel midt i en optagelse kan forstyrre lyden. Vent.
            for f in queue { jobs[f.lastPathComponent] = .queued(waitingForRecording: true) }
            scheduleRetry()
            return
        }
        queue.removeFirst()
        start(folder)
    }

    private func scheduleRetry() {
        guard !retryScheduled else { return }
        retryScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            self?.retryScheduled = false
            self?.pump()
        }
    }

    // MARK: - Forudsætninger

    struct PreflightResult {
        var python: URL?
        var error: String?
    }

    func preflight() -> PreflightResult {
        let fm = FileManager.default
        let script = scriptPath
        guard fm.fileExists(atPath: script) else {
            return .init(error: "Transskriptionsscriptet findes ikke: \(script). Det følger normalt med appen (scripts/transcribe i repoet). Du kan vælge scriptet selv.")
        }
        let interview = (script as NSString).deletingLastPathComponent + "/interview_transcribe.py"
        guard fm.fileExists(atPath: interview) else {
            return .init(error: "interview_transcribe.py mangler ved siden af scriptet (\(interview)). Begge scripts skal ligge i samme mappe.")
        }
        let candidates = pythonCandidates ?? [
            environment["DIKTAT_PYTHON"] ?? "",
            home + "/.diktat/venv/bin/python",
            "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3",
        ].filter { !$0.isEmpty }
        guard let py = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) else {
            return .init(error: "Python 3 blev ikke fundet på denne Mac. Det følger med Xcodes kommandolinjeværktøjer (xcode-select --install) eller kan installeres med brew install python.")
        }
        return .init(python: URL(fileURLWithPath: py), error: nil)
    }

    /// Appens egen modelmappe (der hvor startvinduet og AI-modeller lægger Whisper-modeller). Samme sti som i VoiceInk.swift.
    static func appModelsDirectory(home: String) -> String {
        home + "/Library/Application Support/local.diktat.app/WhisperModels"
    }

    /// Hvad `DIKTAT_WHISPER_MODELS` skal være for møde-scriptet. Har brugeren selv sat den, røres den ikke (nil).
    /// Ellers appens modelmappe. Scriptet falder selv tilbage til ~/.whisper-models, hvis modellen kun ligger dér.
    static func modelsDirectoryForScripts(environment: [String: String], home: String) -> String? {
        if let own = environment["DIKTAT_WHISPER_MODELS"], !own.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        return appModelsDirectory(home: home)
    }

    /// Findes HF_TOKEN? Returnerer kun værdien til at give videre til underprocessen, aldrig til visning eller fil.
    private func hfToken() -> String? {
        if let t = environment["HF_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        guard launchctlFallback else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["getenv", "HF_TOKEN"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let t = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }

    func refreshDiarizationAvailability() {
        diarizationAvailable = hfToken() != nil
    }

    // MARK: - Kørsel

    private func start(_ folder: URL) {
        let id = folder.lastPathComponent
        let automatic = autoFlags.removeValue(forKey: id) ?? false
        let pre = preflight()
        guard let python = pre.python else {
            fail(folder, id: id, message: pre.error ?? "Kunne ikke starte transskriptionen.", automatic: automatic)
            return
        }
        let startedAt = Date()
        writeStatus(
            folder,
            .init(state: "running", message: nil, startedAt: startedAt, finishedAt: nil, model: model, language: language, automatic: automatic))
        let logURL = folder.appendingPathComponent("transskribering.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let sink = LogSink(handle: try? FileHandle(forWritingTo: logURL)) { [weak self] step in
            Task { @MainActor in
                guard let self, self.currentFolder?.lastPathComponent == id else { return }
                self.jobs[id] = .running(step: step, since: startedAt)
            }
        }

        var env = environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        // Appen og møderne har hver sin modelmappe. Giv appens videre, så mødet finder den model, der allerede er hentet.
        if let dir = Self.modelsDirectoryForScripts(environment: environment, home: home) { env["DIKTAT_WHISPER_MODELS"] = dir }
        if let token = hfToken() { env["HF_TOKEN"] = token } else { env.removeValue(forKey: "HF_TOKEN") }

        let process = Process()
        process.executableURL = python
        process.arguments = [scriptPath, folder.path, "--model", model, "--lang", language]
        process.environment = env
        process.qualityOfService = .utility
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if !data.isEmpty { sink.feed(data) }
        }
        process.terminationHandler = { [weak self] p in
            pipe.fileHandleForReading.readabilityHandler = nil
            if let rest = try? pipe.fileHandleForReading.readToEnd(), !rest.isEmpty { sink.feed(rest) }
            sink.finish()
            let code = p.terminationStatus
            let signalled = p.terminationReason == .uncaughtSignal
            let lastError = sink.lastError
            Task { @MainActor in
                self?.finished(folder: folder, id: id, code: code, signalled: signalled, lastError: lastError,
                               startedAt: startedAt, automatic: automatic)
            }
        }
        jobs[id] = .running(step: "Starter", since: startedAt)
        current = process
        currentFolder = folder
        currentSink = sink
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            current = nil
            currentFolder = nil
            currentSink = nil
            fail(folder, id: id, message: "Kunne ikke starte Python: \(error.localizedDescription)", automatic: automatic)
        }
    }

    private func finished(
        folder: URL, id: String, code: Int32, signalled: Bool, lastError: String?, startedAt: Date, automatic: Bool
    ) {
        current = nil
        currentFolder = nil
        currentSink = nil
        if terminatingForQuit { return }
        let transcript = folder.appendingPathComponent("transskript.txt")
        let tDate = (try? transcript.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let wrote = tDate.map { $0 >= startedAt.addingTimeInterval(-1) } ?? false
        if code == 0 && wrote {
            jobs.removeValue(forKey: id)
            writeStatus(
                folder,
                .init(state: "done", message: nil, startedAt: startedAt, finishedAt: Date(), model: model, language: language,
                      automatic: automatic))
            lastMessage = "Transskript er klar"
            onChange()
            onTranscriptReady(folder)
        } else {
            let message: String
            if signalled {
                message = "Transskriptionen blev afbrudt."
            } else if code == 0 {
                message = "Scriptet blev færdigt, men skrev intet nyt transskript. Se transskribering.log i mødemappen."
            } else {
                let base = lastError ?? "Transskriptionen fejlede (kode \(code))."
                message = base.contains("transskribering.log") ? base : base + " Se transskribering.log i mødemappen."
            }
            fail(folder, id: id, message: message, automatic: automatic, startedAt: startedAt)
        }
        pump()
    }

    private func fail(_ folder: URL, id: String, message: String, automatic: Bool, startedAt: Date = Date()) {
        jobs.removeValue(forKey: id)
        writeStatus(
            folder,
            .init(state: "failed", message: message, startedAt: startedAt, finishedAt: Date(), model: model, language: language,
                  automatic: automatic))
        lastMessage = message
        onChange()
        pump()
    }

    /// Appen lukkes: stop underprocessen (wrapperen standser også whisper-cli) og markér som afbrudt.
    private func handleQuit() {
        terminatingForQuit = true
        guard let process = current, let folder = currentFolder else { return }
        if process.isRunning { process.terminate() }
        var s = readStatus(folder)
        s?.state = "failed"
        s?.finishedAt = Date()
        s?.message = "Transskriptionen blev afbrudt, fordi appen blev lukket. Tryk Transskribér igen."
        if let s { writeStatus(folder, s) }
        process.waitUntilExit()
    }
}

/// Skriver underprocessens output til loggen og finder "TRIN:" og "FEJL:" linjer. Trådsikker.
final class LogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?
    private var buffer = Data()
    private var _lastError: String?
    private let onStep: @Sendable (String) -> Void

    init(handle: FileHandle?, onStep: @escaping @Sendable (String) -> Void) {
        self.handle = handle
        self.onStep = onStep
    }

    var lastError: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastError
    }

    func feed(_ data: Data) {
        lock.lock()
        try? handle?.write(contentsOf: data)
        buffer.append(data)
        var steps: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            if line.hasPrefix("TRIN: ") { steps.append(String(line.dropFirst(6))) }
            if line.hasPrefix("FEJL: ") { _lastError = String(line.dropFirst(6)) }
        }
        lock.unlock()
        for s in steps { onStep(s) }
    }

    func finish() {
        lock.lock()
        try? handle?.close()
        handle = nil
        lock.unlock()
    }
}
