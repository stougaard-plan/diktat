import AppKit
import AVFoundation
import Foundation

struct MeetingMeta: Codable {
    struct Segment: Codable {
        var track: String
        var file: String
        var startedAt: Date
        var endedAt: Date?
    }
    struct Event: Codable {
        var at: Date
        var kind: String
        var detail: String
    }
    var title: String
    /// Hvem skrev titlen: «auto» (lokal model) eller «manual» (brugeren, også ved start af optagelsen). Mangler = ikke rettet.
    var titleSource: String?
    var titleUpdatedAt: Date?
    /// Titlen mangler endnu og prøves igen (modellen kunne ikke nås). Sættes kun af MeetingTitler.
    var titlePending: Bool?
    var titleAttempts: Int?
    var startedAt: Date
    var endedAt: Date?
    var status: String  // recording | stopped | interrupted
    var sources: [String: String]
    var segments: [Segment]
    var events: [Event]
}

struct MeetingInfo: Identifiable {
    let id: String
    let url: URL
    let meta: MeetingMeta?
    var hasTranscript: Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("transskript.txt").path)
    }
}

/// Notetakeren: to spor (mikrofon "mik" og computerlyd "computer") i løbende CAF-segmenter i ~/Moeder/.
/// Starter aldrig af sig selv. Optager altid med synlig indikator (MeetingIndicator).
@MainActor
final class MeetingRecorder: ObservableObject {
    static let shared = MeetingRecorder()

    enum State: Equatable {
        case idle
        case recording
        case sleeping
        case error(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var computerLevel: Float = 0
    @Published private(set) var warning: String?
    @Published private(set) var meetings: [MeetingInfo] = []
    @Published private(set) var currentTitle = ""
    /// Problemer pr. spor ("mik", "computer"), vist i indikatoren. Tom = alt i orden.
    @Published private(set) var trackIssues: [String: String] = [:]
    /// Journalen (meta.json) kunne ikke skrives.
    @Published private(set) var journalError: String?

    /// Alt der skal ses i indikatoren, i fast rækkefølge. Tom liste = ingen problemer.
    var problems: [String] {
        var list: [String] = []
        for track in ["mik", "computer"] { if let t = trackIssues[track] { list.append(t) } }
        if let journalError { list.append(journalError) }
        if let warning, !list.contains(warning) { list.append(warning) }
        return list
    }

    /// Kun til selvtest.
    var directoryForTest: URL? { directory }

    var errorMessage: String? {
        if case .error(let message) = state { return message }
        return nil
    }

    var currentFolderName: String? { directory?.lastPathComponent }

    var hasProblems: Bool { !problems.isEmpty }

    var isRecording: Bool {
        switch state {
        case .recording, .sleeping: return true
        default: return false
        }
    }

    static var rootDirectory: URL {
        // Rodmappen kan kun flyttes af selvtesten med simulerede kilder, aldrig ved almindelig brug.
        let env = ProcessInfo.processInfo.environment
        if env["DIKTAT_SIM_COMPUTER"] != nil, let root = env["DIKTAT_TEST_ROOT"] {
            return URL(fileURLWithPath: root, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Moeder")
    }

    private var silenceThreshold: TimeInterval {
        ProcessInfo.processInfo.environment["DIKTAT_SILENCE_SECONDS"].flatMap(Double.init) ?? 90
    }

    private let minimumFreeBytes: Int64 = 5 * 1_024 * 1_024 * 1_024
    private let stopFreeBytes: Int64 = 1 * 1_024 * 1_024 * 1_024
    private let stallSeconds: TimeInterval = 15

    private var segmentSeconds: TimeInterval {
        let v = ProcessInfo.processInfo.environment["DIKTAT_SEGMENT_SECONDS"].flatMap(Double.init) ?? 300
        return max(10, v)
    }

    private var directory: URL?
    private var meta: MeetingMeta?
    private var micWriter: MeetingSegmentWriter?
    private var computerWriter: MeetingSegmentWriter?
    private var micSource: MeetingAudioSource?
    private var computerSource: MeetingAudioSource?
    private var timer: Timer?
    private var startedAt = Date()
    private var segmentStartedAt = Date()
    private var activity: NSObjectProtocol?
    private var generation = 0
    private var observers: [NSObjectProtocol] = []
    private var restartAttempts: [String: Int] = [:]
    private var journalFailures = 0
    private var issueKinds: [String: String] = [:]

    private init() {
        observers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.handleWillSleep() } })
        observers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.handleDidWake() } })
        recoverInterrupted()
        let transcriber = MeetingTranscriber.shared
        transcriber.isRecording = { [weak self] in self?.isRecording ?? false }
        transcriber.onChange = { [weak self] in self?.refreshMeetings() }
        transcriber.onTranscriptReady = { MeetingTitler.shared.enqueue(folder: $0) }
        let titler = MeetingTitler.shared
        titler.shouldWait = { [weak self] in (self?.isRecording ?? false) || MeetingTranscriber.shared.isBusy }
        titler.onChange = { [weak self] in self?.refreshMeetings() }
        MeetingTitleModel.install(into: titler)
        // Kun møder med markeringen titlePending prøves igen. Gamle møder får aldrig en titel af sig selv.
        titler.startAutoRetry(root: Self.rootDirectory)
        transcriber.recoverStale(in: Self.rootDirectory)
        refreshMeetings()
    }

    // MARK: - Start og stop

    func start(title rawTitle: String) {
        guard !isRecording else { return }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        warning = nil
        trackIssues = [:]
        journalError = nil
        journalFailures = 0

        do {
            try prepareRoot()
            let free = Self.freeBytes(at: Self.rootDirectory)
            guard free >= minimumFreeBytes else {
                state = .error("For lidt plads på disken (under 5 GB ledigt). Optagelsen blev ikke startet.")
                return
            }
            let now = Date()
            var folder = Self.folderName(date: now, title: title)
            var suffix = 2
            while FileManager.default.fileExists(
                atPath: Self.rootDirectory.appendingPathComponent(folder).path) {
                folder = Self.folderName(date: now, title: title) + "_\(suffix)"
                suffix += 1
            }
            let dir = Self.rootDirectory.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: dir.path)) != nil {
                throw MeetingAudioError.symlink(dir.path)
            }
            directory = dir
            startedAt = now
            currentTitle = title.isEmpty ? "Møde" : title
            meta = MeetingMeta(
                title: currentTitle, titleSource: title.isEmpty ? nil : "manual", titleUpdatedAt: nil, startedAt: now, endedAt: nil, status: "recording", sources: [:],
                segments: [], events: [])
            restartAttempts = [:]

            micWriter = MeetingSegmentWriter(track: "mik", directory: dir) { [weak self] level in
                Task { @MainActor in self?.micLevel = level }
            }
            computerWriter = MeetingSegmentWriter(track: "computer", directory: dir) { [weak self] level in
                Task { @MainActor in self?.computerLevel = level }
            }
            generation += 1
            // Segmenter åbnes før kilderne starter, så de første lydpakker ikke tabes.
            openSegments(at: now)
            if micWriter?.currentFilename == nil && computerWriter?.currentFilename == nil {
                throw MeetingAudioError.noSegments(
                    [micWriter?.health.openError, computerWriter?.health.openError].compactMap { $0 }.first ?? "")
            }
            try startSources(initial: true)
            beginActivity()
            state = .recording
            elapsed = 0
            startTimer()
            record(event: "start", detail: "Optagelse startet")
            saveMeta()
            MeetingIndicator.shared.show()
        } catch {
            stopSources()
            micWriter?.close()
            computerWriter?.close()
            micWriter = nil
            computerWriter = nil
            directory = nil
            meta = nil
            state = .error("Kunne ikke starte optagelsen: \(error.localizedDescription)")
            endActivity()
        }
    }

    func stop(reason: String = "Stoppet af bruger") {
        guard isRecording || directory != nil else { return }
        timer?.invalidate()
        timer = nil
        stopSources()
        closeSegments(at: Date())
        meta?.endedAt = Date()
        meta?.status = "stopped"
        record(event: "stop", detail: reason)
        saveMeta()
        // Normalt stop: transskriptionen starter af sig selv. Afbrudte optagelser (recoverInterrupted) startes aldrig.
        let stoppedFolder = directory
        micWriter = nil
        computerWriter = nil
        directory = nil
        meta = nil
        endActivity()
        micLevel = 0
        computerLevel = 0
        trackIssues = [:]
        issueKinds = [:]
        if case .error = state {} else { state = .idle }
        MeetingIndicator.shared.hide()
        refreshMeetings()
        if let stoppedFolder, ProcessInfo.processInfo.environment["DIKTAT_TRANSCRIBE_AUTO"] != "0" {
            MeetingTranscriber.shared.enqueue(folder: stoppedFolder, automatic: true)
        }
    }

    func dismissError() {
        if case .error = state { state = .idle }
    }

    // MARK: - Kilder

    private func makeSources() -> (mic: MeetingAudioSource, computer: MeetingAudioSource) {
        let env = ProcessInfo.processInfo.environment
        if let computerPath = env["DIKTAT_SIM_COMPUTER"] {
            let delay = env["DIKTAT_SIM_MIC_DELAY"].flatMap(Double.init) ?? 0
            let micURL = URL(fileURLWithPath: env["DIKTAT_SIM_MIC"] ?? computerPath)
            let silent = env["DIKTAT_SIM_SILENT"] ?? ""
            return (
                SimulatedFileSource(
                    url: micURL, startDelay: delay, forceSilence: silent == "mik" || silent == "begge"),
                SimulatedFileSource(
                    url: URL(fileURLWithPath: computerPath),
                    forceSilence: silent == "computer" || silent == "begge")
            )
        }
        let mic = MicrophoneSource()
        mic.onConfigurationChange = { [weak self] in
            Task { @MainActor in self?.restartSource(track: "mik", reason: "Mikrofonen skiftede enhed") }
        }
        return (mic, SystemAudioTapSource())
    }

    private func startSources(initial: Bool) throws {
        let sources = makeSources()
        sources.mic.onBuffer = { [weak self] buffer in self?.micWriter?.append(buffer) }
        sources.computer.onBuffer = { [weak self] buffer in self?.computerWriter?.append(buffer) }
        sources.mic.onFault = { [weak self] why in self?.micWriter?.reportFault(why) }
        sources.computer.onFault = { [weak self] why in self?.computerWriter?.reportFault(why) }
        var errors: [String] = []
        do {
            try sources.mic.start()
            micSource = sources.mic
            meta?.sources["mik"] = sources.mic is SimulatedFileSource ? "simuleret" : "mikrofon"
        } catch { errors.append("Mikrofon: \(error.localizedDescription)") }
        do {
            try sources.computer.start()
            computerSource = sources.computer
            meta?.sources["computer"] = sources.computer is SimulatedFileSource ? "simuleret" : "process tap"
            if let layout = sources.computer.layoutDescription {
                record(event: "tap-layout", detail: layout)
                NSLog("Diktat systemlyd-layout: %@", layout)
            }
        } catch { errors.append("Computerlyd: \(error.localizedDescription)") }
        if micSource == nil && computerSource == nil {
            throw MeetingAudioError.tap(errors.joined(separator: ". "), -1)
        }
        if !errors.isEmpty {
            warning = errors.joined(separator: ". ") + ". Kun ét spor optages."
            record(event: "kilde-fejl", detail: errors.joined(separator: " | "))
        }
    }

    private func stopSources() {
        micSource?.stop()
        computerSource?.stop()
        micSource = nil
        computerSource = nil
    }

    private func restartSource(track: String, reason: String) {
        guard state == .recording else { return }
        let attempts = (restartAttempts[track] ?? 0) + 1
        restartAttempts[track] = attempts
        record(event: "genstart", detail: "\(track): \(reason) (forsøg \(attempts))")
        if attempts > 5 {
            warning = "Sporet \(track) stoppede og kunne ikke genstartes. Tjek optagelsen."
            return
        }
        let writer = track == "mik" ? micWriter : computerWriter
        do {
            if track == "mik" {
                micSource?.stop()
                micSource = nil
            } else {
                computerSource?.stop()
                computerSource = nil
            }
            let sources = makeSources()
            let source = track == "mik" ? sources.mic : sources.computer
            source.onBuffer = { buffer in writer?.append(buffer) }
            source.onFault = { why in writer?.reportFault(why) }
            try source.start()
            if track == "mik" { micSource = source } else { computerSource = source }
            if let layout = source.layoutDescription {
                record(event: "tap-layout", detail: layout)
                NSLog("Diktat systemlyd-layout: %@", layout)
            }
            rotateTrack(track, at: Date())
            warning = nil
        } catch {
            warning = "Sporet \(track) kunne ikke genstartes: \(error.localizedDescription)"
        }
        saveMeta()
    }

    // MARK: - Segmenter og meta

    private func openSegments(at date: Date) {
        segmentStartedAt = date
        for track in ["mik", "computer"] { rotateTrack(track, at: date, closePrevious: false) }
    }

    private func rotateTrack(_ track: String, at date: Date, closePrevious: Bool = true) {
        let writer = track == "mik" ? micWriter : computerWriter
        if closePrevious, let idx = meta?.segments.lastIndex(where: { $0.track == track && $0.endedAt == nil }) {
            meta?.segments[idx].endedAt = date
        }
        if let name = writer?.rotate() {
            meta?.segments.append(.init(track: track, file: name, startedAt: date, endedAt: nil))
        } else {
            record(event: "segment-fejl", detail: "Kunne ikke åbne segment for \(track)")
            warning = "Kunne ikke skrive lydfil for \(track)."
        }
    }

    private func closeSegments(at date: Date) {
        micWriter?.close()
        computerWriter?.close()
        guard var m = meta else { return }
        for i in m.segments.indices where m.segments[i].endedAt == nil { m.segments[i].endedAt = date }
        meta = m
    }

    private func rotateAll(at date: Date) {
        segmentStartedAt = date
        for track in ["mik", "computer"] where (track == "mik" ? micSource : computerSource) != nil {
            rotateTrack(track, at: date)
        }
        saveMeta()
    }

    private func record(event kind: String, detail: String) {
        meta?.events.append(.init(at: Date(), kind: kind, detail: detail))
    }

    /// Skriver journalen. En fejl her må aldrig sluges: den vises i indikatoren, og optagelsen fortsætter.
    @discardableResult
    private func saveMeta() -> Bool {
        guard let meta, let directory else { return true }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(meta)
            try data.write(to: directory.appendingPathComponent("meta.json"), options: .atomic)
            if journalError != nil { record(event: "journal-ok", detail: "Journalen kan skrives igen") }
            journalError = nil
            return true
        } catch {
            journalFailures += 1
            let message =
                "Journalen kan ikke skrives (\(error.localizedDescription)). Lyden optages, men tidslinjen kan mangle."
            if journalError == nil { record(event: "journal-fejl", detail: error.localizedDescription) }
            journalError = message
            return false
        }
    }

    // MARK: - Tidtagning, vagthund, dvale

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private var tickCount = 0

    private func tick() {
        guard state == .recording else { return }
        tickCount += 1
        elapsed = Date().timeIntervalSince(startedAt)
        micLevel *= 0.6
        computerLevel *= 0.6

        if Date().timeIntervalSince(segmentStartedAt) >= segmentSeconds { rotateAll(at: Date()) }

        if tickCount % 5 == 0 {
            if micSource != nil, let w = micWriter, w.secondsSinceLastFrame > stallSeconds {
                restartSource(track: "mik", reason: "ingen lyd i \(Int(stallSeconds)) s")
            }
            if computerSource != nil, let w = computerWriter, w.secondsSinceLastFrame > stallSeconds {
                restartSource(track: "computer", reason: "ingen data i \(Int(stallSeconds)) s")
            }
        }
        evaluateHealth()
        if tickCount % 30 == 0 { saveMeta() }
        if tickCount % 30 == 0, let directory {
            let free = Self.freeBytes(at: directory)
            if free < stopFreeBytes {
                state = .error("Disken er næsten fuld. Optagelsen er stoppet og gemt.")
                stop(reason: "Disk næsten fuld")
            }
        }
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        t >= 120 ? "\(Int(t / 60)) min" : "\(Int(t)) s"
    }

    /// Finder spor der ikke optager rigtigt: lydfejl, skrivefejl, manglende kilde og digital stilhed.
    private func evaluateHealth() {
        var issues: [String: String] = [:]
        for track in ["mik", "computer"] {
            let writer = track == "mik" ? micWriter : computerWriter
            let source = track == "mik" ? micSource : computerSource
            let name = track == "mik" ? "Mikrofon" : "Computerlyd"
            guard let writer else { continue }
            let h = writer.health
            if source == nil {
                issues[track] = "\(name) optages ikke. Mødets lyd fra dette spor mangler."
            } else if let e = h.writeError {
                issues[track] = "\(name): \(e). Lyd går tabt."
            } else if let e = h.conversionError {
                issues[track] = "\(name): \(e). Lyd går tabt."
            } else if let e = h.openError {
                issues[track] = "\(name): \(e). Lyd går tabt."
            } else if let e = h.sourceFault {
                issues[track] = "\(name): \(e). Lyd går tabt."
            } else if h.noDataSeconds >= stallSeconds {
                issues[track] = "\(name) har ikke modtaget lyd i \(formatDuration(h.noDataSeconds)). Lyd går tabt."
            } else if h.silentSeconds >= silenceThreshold {
                let hint =
                    track == "mik"
                    ? "Tjek mikrofontilladelsen og at mikrofonen ikke er slået fra."
                    : "Hvis der er lyd i mødet, mangler tilladelsen til systemlyd."
                issues[track] = "\(name) er digitalt tavs i \(formatDuration(h.silentSeconds)). \(hint)"
            }
        }
        // Ét journalpunkt pr. ændring af problemtype, ikke pr. sekund.
        for track in ["mik", "computer"] {
            let kind = issueKind(issues[track])
            if kind != (issueKinds[track] ?? "") {
                if kind.isEmpty {
                    record(event: "spor-ok", detail: "\(track): problemet er væk")
                } else {
                    record(event: "spor-problem", detail: "\(track): \(issues[track] ?? kind)")
                }
                issueKinds[track] = kind
            }
        }
        if issues != trackIssues { trackIssues = issues }
    }

    private func issueKind(_ text: String?) -> String {
        guard let text else { return "" }
        if text.contains("digitalt tavs") { return "tavs" }
        if text.contains("optages ikke") { return "ingen-kilde" }
        if text.contains("ikke modtaget lyd") { return "ingen-data" }
        return "skrivefejl"
    }

    private func handleWillSleep() {
        guard state == .recording else { return }
        record(event: "dvale", detail: "Mac'en går i dvale. Segmenter lukkes.")
        stopSources()
        closeSegments(at: Date())
        saveMeta()
        state = .sleeping
    }

    private func handleDidWake() {
        guard state == .sleeping else { return }
        record(event: "vaagnede", detail: "Mac'en er vågen. Genopretter kilder.")
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.state == .sleeping, self.generation == gen else { return }
            do {
                self.openSegments(at: Date())
                self.micWriter?.resetDataClock()
                self.computerWriter?.resetDataClock()
                try self.startSources(initial: false)
                self.state = .recording
                self.saveMeta()
            } catch {
                self.record(event: "genstart-fejl", detail: error.localizedDescription)
                self.saveMeta()
                self.warning = "Optagelsen kunne ikke genoptages efter dvale: \(error.localizedDescription)"
                self.state = .error("Optagelsen stoppede ved dvale og kunne ikke genstartes.")
                self.stop(reason: "Genstart efter dvale fejlede")
            }
        }
    }

    private func beginActivity() {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated], reason: "Diktat optager et møde")
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    // MARK: - Mapper og liste

    private func prepareRoot() throws {
        let root = Self.rootDirectory
        let fm = FileManager.default
        // Afvis symlink: ellers kan optagelser ende et uventet sted (fx i Drive). Tjekkes før noget oprettes eller ændres.
        if let target = try? fm.destinationOfSymbolicLink(atPath: root.path) {
            throw MeetingAudioError.symlink("\(root.path) peger på \(target)")
        }
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: root.path, isDirectory: &isDir), !isDir.boolValue {
            throw MeetingAudioError.symlink("\(root.path) er en fil og ikke en mappe")
        }
        let isNew = !fm.fileExists(atPath: root.path)
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        if let owner = try fm.attributesOfItem(atPath: root.path)[.ownerAccountID] as? NSNumber,
            owner.uint32Value != getuid()
        {
            throw MeetingAudioError.symlink("\(root.path) ejes ikke af dig")
        }
        let marker = root.appendingPathComponent(".metadata_never_index")
        if !fm.fileExists(atPath: marker.path) { fm.createFile(atPath: marker.path, contents: Data()) }
        if isNew {
            // Lokal udelukkelse fra Time Machine. Fejler stille, hvis kommandoen ikke findes.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
            p.arguments = ["addexclusion", root.path]
            try? p.run()
        }
    }

    func refreshMeetings() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(
            at: Self.rootDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        meetings = dirs.filter { $0.hasDirectoryPath }
            .map { dir in
                let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json"))
                return MeetingInfo(
                    id: dir.lastPathComponent, url: dir,
                    meta: data.flatMap { try? decoder.decode(MeetingMeta.self, from: $0) })
            }
            .sorted { $0.id > $1.id }
    }

    /// Marker optagelser, der står som "recording" men ikke kører, som afbrudt.
    private func recoverInterrupted() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: Self.rootDirectory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var failed = 0
        for dir in dirs where dir.hasDirectoryPath {
            let url = dir.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: url), var m = try? decoder.decode(MeetingMeta.self, from: data),
                m.status == "recording"
            else { continue }
            m.status = "interrupted"
            for i in m.segments.indices where m.segments[i].endedAt == nil {
                let file = dir.appendingPathComponent(m.segments[i].file)
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                m.segments[i].endedAt = modified ?? m.segments[i].startedAt
            }
            m.events.append(.init(at: Date(), kind: "afbrudt", detail: "Appen stoppede uden at lukke optagelsen. Segmenter kan bruges."))
            do {
                try encoder.encode(m).write(to: url, options: .atomic)
            } catch {
                failed += 1
            }
        }
        if failed > 0 {
            warning = "\(failed) afbrudt(e) optagelse(r) kunne ikke markeres i journalen: lyden ligger stadig i mappen."
        }
    }

    static func folderName(date: Date, title: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmm"
        let safe = title.lowercased()
            .replacingOccurrences(of: "æ", with: "ae").replacingOccurrences(of: "ø", with: "oe")
            .replacingOccurrences(of: "å", with: "aa")
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            .joined(separator: "-")
        return safe.isEmpty ? f.string(from: date) : "\(f.string(from: date))_\(safe)"
    }

    static func freeBytes(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}

extension MeetingRecorder: MeetingRecording {}
