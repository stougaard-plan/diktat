import Foundation

/// Sætter en titel på mødet, når transskriptet er klart, og lader brugeren rette den.
/// - Slået FRA som standard (MeetingTitleSettings). Er den slået til, bruger den en Ollama-model, brugeren selv har sat op, se MeetingTitleModel.
/// - Titlen står i `meta.json` (`title`), og `titleSource` siger hvem der skrev den: `auto` eller `manual`.
/// - En manuelt rettet titel overskrives aldrig, heller ikke efter «Transskribér igen».
/// - Fejl rører aldrig transskriptet: titlen bliver «Møde», og en kort bemærkning kommer i `transskribering.log`.
/// - Kan modellen ikke nås, står mødet med `titlePending` i meta.json og prøves igen (ved opstart og med fast interval).
///   Kun møder, der selv har fået markeringen (nyt færdigt transskript eller «Transskribér igen»), prøves igen.
///   Møder, der fandtes i forvejen, får aldrig en titel af sig selv.
/// - Kører først, når der hverken optages eller transskriberes, så lyden og transskriptionen ikke forstyrres.
/// - Mappen i ~/Moeder omdøbes aldrig.
@MainActor
final class MeetingTitler: ObservableObject {
    static let shared = MeetingTitler()

    /// Møder, hvor titlen er i kø eller bliver lavet nu.
    @Published private(set) var pending: Set<String> = []

    /// Modellen. Sættes af appen (MeetingTitleModel.swift). Standard: ingen model, så titlen bliver «Møde».
    var generate: @Sendable (_ system: String, _ input: String) async throws -> String = { _, _ in
        throw MeetingTitlerError.noModel
    }
    /// Må der laves automatiske titler? Appen sætter den til brugerens indstilling (FRA som standard).
    /// Er den falsk, rører titleren hverken meta.json eller netværket.
    var isEnabled: () -> Bool = { true }
    /// Sand, mens der optages eller transskriberes. Sættes af MeetingRecorder.
    var shouldWait: () -> Bool = { false }
    var onChange: () -> Void = {}
    var timeout: TimeInterval = MeetingTitle.defaultTimeout
    var minContentWords: Int = MeetingTitle.minContentWords
    var retryDelay: TimeInterval = 5
    /// Mislykkede forsøg skrives kun i loggen for forsøg 1 og derefter hvert N'te, så loggen ikke vokser uden grund.
    /// Der gives aldrig op: markeringen bliver stående, til modellen svarer, også efter en genstart af appen.
    var logEveryAttempts = 6
    /// Fast interval mellem gennemgange af møder med ventende titel.
    var scanInterval: TimeInterval = 600
    private var scanTimer: Timer?

    private var queue: [URL] = []
    private var currentRun: Task<Void, Never>?
    private var busy = false
    private var retryScheduled = false

    enum MeetingTitlerError: LocalizedError {
        case noModel
        var errorDescription: String? { "Der er ikke sat nogen titelmodel op." }
    }

    // MARK: - Kø

    /// Lægger et møde i køen til en automatisk titel og sætter markeringen `titlePending`, så titlen prøves igen,
    /// hvis modellen ikke kan nås. Kaldes kun for nye færdige transskripter og «Transskribér igen». Gør ingenting,
    /// hvis titlen er rettet af brugeren.
    func enqueue(folder: URL, isRetry: Bool = false) {
        let id = folder.lastPathComponent
        guard isEnabled() else { return }
        guard !pending.contains(id) else { return }
        guard Self.mayAutoTitle(folder) else { return }
        if !isRetry {
            do {
                try Self.updateMeta(folder) { $0["titlePending"] = true; $0["titleAttempts"] = 0 }
            } catch {
                Self.log(folder, "Titlen kunne ikke sættes i kø: \(error.localizedDescription)")
                return
            }
        }
        pending.insert(id)
        queue.append(folder)
        pump()
    }

    /// Finder møder med `titlePending` i `root` og lægger dem i køen. Rører ikke møder uden markeringen
    /// (dem, der fandtes før, eller som aldrig fik et transskript gennem appen) og ikke manuelle titler.
    func scanForPending(root: URL) {
        guard isEnabled() else { return }
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where dir.hasDirectoryPath {
            guard let meta = Self.readMeta(dir), meta["titlePending"] as? Bool == true else { continue }
            guard Self.mayAutoTitle(dir),
                FileManager.default.fileExists(atPath: dir.appendingPathComponent("transskript.txt").path)
            else { continue }
            enqueue(folder: dir, isRetry: true)
        }
    }

    /// Gennemgår `root` nu og derefter med fast interval.
    func startAutoRetry(root: URL) {
        scanForPending(root: root)
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: scanInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scanForPending(root: root) }
        }
    }

    private func pump() {
        guard !busy, let folder = queue.first else { return }
        if shouldWait() {
            scheduleRetry()
            return
        }
        queue.removeFirst()
        busy = true
        currentRun = Task { @MainActor in
            await self.run(folder)
            self.busy = false
            self.currentRun = nil
            self.pending.remove(folder.lastPathComponent)
            self.pump()
        }
    }

    /// Brugeren har slået den automatiske titel fra: afbryd kaldet, der er i gang, og tøm køen. Intet bliver
    /// gemt. Markeringen `titlePending` i meta.json røres ikke, så titlen kan komme, hvis den slås til igen.
    func cancelInFlight() {
        currentRun?.cancel()
        for folder in queue { pending.remove(folder.lastPathComponent) }
        queue.removeAll()
    }

    private func scheduleRetry() {
        guard !retryScheduled else { return }
        retryScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.retryDelay * 1_000_000_000))
            self.retryScheduled = false
            self.pump()
        }
    }

    // MARK: - Kørsel

    private func run(_ folder: URL) async {
        guard Self.mayAutoTitle(folder) else {
            try? Self.updateMeta(folder) { Self.clearPending(&$0) }
            return
        }
        guard let text = try? String(contentsOf: folder.appendingPathComponent("transskript.txt"), encoding: .utf8) else {
            Self.log(folder, "Titlen blev ikke lavet, fordi transskriptet ikke kunne læses.")
            try? Self.updateMeta(folder) { Self.clearPending(&$0) }
            return
        }
        // Fravalgt, mens mødet stod i kø: send ingenting.
        guard isEnabled() else {
            Self.log(folder, "Titlen blev ikke lavet, fordi den automatiske titel blev slået fra.")
            return
        }
        let stillEnabled: @Sendable () async -> Bool = { [weak self] in
            await MainActor.run { self?.isEnabled() ?? false }
        }
        let outcome = await MeetingTitle.make(
            transcriptFile: text, minContentWords: minContentWords, timeout: timeout,
            isStillEnabled: stillEnabled, generate: generate)
        if let note = outcome.note { Self.log(folder, note) }
        // Fravalgt, mens modellen arbejdede (eller kaldet blev afbrudt): gem intet og skriv intet i meta.json.
        guard !outcome.cancelled, !Task.isCancelled, isEnabled() else {
            Self.log(folder, "Den automatiske titel blev ikke gemt, fordi den blev slået fra undervejs.")
            return
        }
        // Brugeren kan have rettet titlen, mens modellen arbejdede. Tjek igen lige før skrivningen.
        guard Self.mayAutoTitle(folder) else {
            Self.log(folder, "Den automatiske titel blev ikke gemt, fordi titlen blev rettet undervejs.")
            try? Self.updateMeta(folder) { Self.clearPending(&$0) }
            return
        }
        do {
            if outcome.retryable {
                let attempts = ((Self.readMeta(folder)?["titleAttempts"] as? Int) ?? 0) + 1
                if attempts == 1 || attempts % logEveryAttempts == 0 {
                    Self.log(folder, "Prøver igen senere (forsøg \(attempts)). Mødet står med markering og prøves ved næste opstart og hvert \(Int(scanInterval / 60)). minut.")
                }
                // Markeringen sættes igen, hvis brugeren undervejs har nulstillet titlen (så den ikke går tabt).
                try Self.updateMeta(folder) { $0["titleAttempts"] = attempts; $0["titlePending"] = true }
                return
            }
            try Self.updateMeta(folder) { obj in
                if !outcome.isFallback {
                    obj["title"] = outcome.title
                    obj["titleSource"] = "auto"
                    obj["titleUpdatedAt"] = ISO8601DateFormatter().string(from: Date())
                }
                Self.clearPending(&obj)
            }
            if !outcome.isFallback {
                Self.log(folder, "Titel sat automatisk: \(outcome.title)")
                onChange()
            }
        } catch {
            Self.log(folder, "Titlen kunne ikke gemmes i meta.json: \(error.localizedDescription) Mødet beholder titlen Møde.")
        }
    }

    // MARK: - Manuel rettelse

    /// Brugerens egen titel. Bliver stående, indtil brugeren selv ændrer den. Tom tekst nulstiller til «Møde»
    /// og lader en ny automatisk titel komme, hvis der findes et transskript.
    @discardableResult
    func rename(folder: URL, to raw: String) -> Bool {
        let cleaned = raw.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Optagelsen skriver selv meta.json hvert 30. sekund og ville overskrive rettelsen. Ret titlen, når optagelsen er slut.
        if Self.readMeta(folder)?["status"] as? String == "recording" {
            Self.log(folder, "Titlen kunne ikke rettes, mens mødet optages.")
            return false
        }
        do {
            if cleaned.isEmpty {
                try Self.writeTitle(folder, title: MeetingTitle.fallback, source: nil)
                onChange()
                if FileManager.default.fileExists(atPath: folder.appendingPathComponent("transskript.txt").path) {
                    enqueue(folder: folder)
                }
            } else {
                try Self.writeTitle(folder, title: String(cleaned.prefix(80)), source: "manual")
                onChange()
            }
            return true
        } catch {
            Self.log(folder, "Titlen kunne ikke rettes: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - meta.json

    static func readMeta(_ folder: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    /// Må en automatisk titel skrives? Nej, hvis brugeren har rettet den, eller hvis den allerede er en anden end
    /// «Møde» uden at være lavet automatisk (fx skrevet ved start af optagelsen).
    static func mayAutoTitle(_ folder: URL) -> Bool {
        guard let meta = readMeta(folder) else { return false }
        let source = meta["titleSource"] as? String
        let title = meta["title"] as? String ?? MeetingTitle.fallback
        if source == "manual" { return false }
        if source == "auto" { return true }
        return title == MeetingTitle.fallback
    }

    static func clearPending(_ obj: inout [String: Any]) {
        obj.removeValue(forKey: "titlePending")
        obj.removeValue(forKey: "titleAttempts")
    }

    /// Ændrer kun de felter, `mutate` rører, og lader alt andet i meta.json stå som det er. Skrives atomisk
    /// (midlertidig fil og omdøbning). Læser filen friskt hver gang.
    static func updateMeta(_ folder: URL, _ mutate: (inout [String: Any]) -> Void) throws {
        let url = folder.appendingPathComponent("meta.json")
        let data = try Data(contentsOf: url)
        guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        mutate(&obj)
        let out = try JSONSerialization.data(
            withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: url, options: .atomic)
    }

    /// Skriver titel og kilde. Brugerens egen titel (`manual`) og nulstilling (`source` nil) rydder også markeringen.
    static func writeTitle(_ folder: URL, title: String, source: String?) throws {
        try updateMeta(folder) { obj in
            obj["title"] = title
            if let source {
                obj["titleSource"] = source
                obj["titleUpdatedAt"] = ISO8601DateFormatter().string(from: Date())
            } else {
                obj.removeValue(forKey: "titleSource")
                obj.removeValue(forKey: "titleUpdatedAt")
            }
            if source == "manual" { clearPending(&obj) }
        }
    }

    /// Tilføjer en linje til transskribering.log. Fejler lydløst, loggen må aldrig vælte noget.
    static func log(_ folder: URL, _ line: String) {
        let url = folder.appendingPathComponent("transskribering.log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(("TITEL: " + line + "\n").utf8))
    }
}
