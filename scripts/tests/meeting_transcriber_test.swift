import AppKit
import Foundation

// Test af MeetingTranscriber og MeetingTranscript med konstruerede mapper og falske scripts.
// Ingen lyd, ingen mikrofon, ingen rigtig transskription. Eget UserDefaults-domæne.

/// Testportene vælges af shell-scriptet (ledige porte), så to testkørsler samtidig ikke støder sammen.
let portBase = Int(ProcessInfo.processInfo.environment["DIKTAT_TEST_PORT_BASE"] ?? "") ?? 18700

extension MeetingTitleModel {
    /// Kun til tests: loopback på en given port, med et fast testmodelnavn.
    static func makeGenerator(port: Int, model: String = "test-model", isStillEnabled: @escaping @Sendable () -> Bool = { true })
        -> @Sendable (_ system: String, _ input: String) async throws -> String
    {
        guard (1024...65535).contains(port), let url = URL(string: "http://127.0.0.1:\(port)") else {
            return { _, _ in throw ModelError.addressNotAllowed }
        }
        return makeGenerator(baseURL: url, model: model, isStillEnabled: isStillEnabled)
    }
}

var failures = 0
func check(_ cond: Bool, _ label: String) {
    print((cond ? "OK   " : "FEJL ") + label)
    if !cond { failures += 1 }
}

let fm = FileManager.default
let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mt-test-\(UUID().uuidString)")
try! fm.createDirectory(at: tmp, withIntermediateDirectories: true)
let fakeHome = tmp.appendingPathComponent("home")
try! fm.createDirectory(at: fakeHome.appendingPathComponent(".diktat/venv/bin"), withIntermediateDirectories: true)
let fakePython = fakeHome.appendingPathComponent(".diktat/venv/bin/python")
try! "#!/bin/sh\nexec /bin/sh \"$@\"\n".write(to: fakePython, atomically: true, encoding: .utf8)
chmod(fakePython.path, 0o755)
let scripts = tmp.appendingPathComponent("scripts")
try! fm.createDirectory(at: scripts, withIntermediateDirectories: true)
try! "# findes\n".write(to: scripts.appendingPathComponent("interview_transcribe.py"), atomically: true, encoding: .utf8)
let events = tmp.appendingPathComponent("events.txt")
let script = scripts.appendingPathComponent("moede_transcribe.py")

func writeScript(_ body: String) {
    try! body.write(to: script, atomically: true, encoding: .utf8)
}

let suite = "local.diktat.app.test-\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defaults.set(script.path, forKey: MeetingTranscriber.scriptKey)

func makeMeeting(_ name: String, audio: String = "LYD-INDHOLD") -> URL {
    let d = tmp.appendingPathComponent("Moeder").appendingPathComponent(name)
    try! fm.createDirectory(at: d, withIntermediateDirectories: true)
    try! "{}".write(to: d.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)
    try! audio.write(to: d.appendingPathComponent("mik_0001.caf"), atomically: true, encoding: .utf8)
    try! audio.write(to: d.appendingPathComponent("computer_0001.caf"), atomically: true, encoding: .utf8)
    return d
}

func audioHash(_ d: URL) -> String {
    ["mik_0001.caf", "computer_0001.caf"].map { (try? String(contentsOf: d.appendingPathComponent($0), encoding: .utf8)) ?? "mangler" }.joined(separator: "|")
}

@MainActor
func waitUntil(_ timeout: Double, _ cond: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if cond() { return true }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return cond()
}


final class ResponseQueue: @unchecked Sendable {
    private var items: [String]
    private let lock = NSLock()
    init(_ items: [String]) { self.items = items }
    func next() -> String { lock.lock(); defer { lock.unlock() }; return items.isEmpty ? "" : items.removeFirst() }
}

@MainActor
func run() async {
    // 1. Parser
    let sample = """
    # Møde
    Optagelse startet 02/01-2026 kl. 13.29. Tider er fra optagelsens start.
    Mig = mikrofonen. De = computerlyden.

    Bemærkninger:
    - De er delt op af talerseparation (2 stemmer).

    [00:00:00] Mig: Nu siger jeg lige noget her.
    [00:00:02] De 1: Tre år: siden
    fortsat linje
    [01:02:03] De 2: Slut.
    """
    let t = MeetingTranscript.parse(sample)
    check(t.title == "Møde" && t.notes.count == 1 && t.lines.count == 3, "parser: titel, 1 bemærkning, 3 replikker")
    check(t.lines[1].speaker == "De 1" && t.lines[1].text == "Tre år: siden fortsat linje", "parser: taler med tal, kolon i tekst, fortsat linje")
    check(t.lines[2].time == "01:02:03", "parser: tidsstempel over en time")
    check(t.fullText == sample, "parser: fullText er uændret (det der kopieres)")

    // 2. Kø: tre møder, aldrig samtidig
    writeScript("""
    echo "START $(basename "$1")" >> "\(events.path)"
    echo "TRIN: Transskriberer"
    sleep 1
    printf '# Møde\\n\\n[00:00:00] Mig: hej\\n' > "$1/transskript.txt"
    echo "SLUT $(basename "$1")" >> "\(events.path)"
    """)
    let tr = MeetingTranscriber(defaults: defaults, environment: [:], home: fakeHome.path, launchctlFallback: false)
    let a = makeMeeting("a"), b = makeMeeting("b"), c = makeMeeting("c")
    let hashes = [a, b, c].map(audioHash)
    check(tr.enqueue(folder: a, automatic: true), "kø: a lagt i kø")
    check(tr.enqueue(folder: b, automatic: true), "kø: b lagt i kø")
    check(tr.enqueue(folder: c, automatic: false), "kø: c lagt i kø")
    check(!tr.enqueue(folder: b, automatic: false), "kø: b to gange afvises")
    if case .running = tr.state(for: a) { check(true, "kø: a kører med det samme") } else { check(false, "kø: a kører med det samme") }
    if case .queued = tr.state(for: b) { check(true, "kø: b venter") } else { check(false, "kø: b venter, men er \(tr.state(for: b))") }
    let done = await waitUntil(30) { [a, b, c].allSatisfy { tr.state(for: $0) == .ready } }
    check(done, "kø: alle tre er klar")
    let log = (try? String(contentsOf: events, encoding: .utf8)) ?? ""
    check(log == "START a\nSLUT a\nSTART b\nSLUT b\nSTART c\nSLUT c\n", "kø: aldrig to samtidig, rækkefølge a b c (\(log.replacingOccurrences(of: "\n", with: " ")))")
    check(tr.readStatus(a)?.state == "done" && tr.readStatus(a)?.automatic == true && tr.readStatus(c)?.automatic == false, "kø: statusfil 'done' med automatic-flag")
    check([a, b, c].map(audioHash) == hashes, "kø: lydfilerne uændrede")

    // 3. Fejl: lydfiler urørte, gammelt transskript bevaret, ærlig besked
    writeScript("""
    echo "FEJL: Whisper-modellen 'large-v3' mangler (/x/y). Bed en kollega hente den." >&2
    exit 3
    """)
    let f = makeMeeting("fejl")
    try! "GAMMELT TRANSSKRIPT\n".write(to: f.appendingPathComponent("transskript.txt"), atomically: true, encoding: .utf8)
    let fh = audioHash(f)
    tr.enqueue(folder: f, automatic: false)
    _ = await waitUntil(10) { if case .failed = tr.state(for: f) { return true } else { return false } }
    if case .failed(let msg, let kept) = tr.state(for: f) {
        check(msg.contains("Whisper-modellen") && msg.contains("transskribering.log"), "fejl: dansk besked fra scriptet + henvisning til loggen")
        check(kept, "fejl: tidligere transskript markeret som bevaret")
    } else { check(false, "fejl: forventede failed, fik \(tr.state(for: f))") }
    check(audioHash(f) == fh, "fejl: lydfilerne uændrede")
    check((try? String(contentsOf: f.appendingPathComponent("transskript.txt"), encoding: .utf8)) == "GAMMELT TRANSSKRIPT\n", "fejl: gammelt transskript.txt uændret")

    // 3b. Standardsti til scriptet: miljøvariabel, appens bundt, repoet. Ingen hårde stier.
    let bundleRes = tmp.appendingPathComponent("App.app/Contents/Resources")
    try! fm.createDirectory(at: bundleRes.appendingPathComponent("transcribe"), withIntermediateDirectories: true)
    try! "x".write(to: bundleRes.appendingPathComponent("transcribe/moede_transcribe.py"), atomically: true, encoding: .utf8)
    let repoDir = tmp.appendingPathComponent("repo")
    try! fm.createDirectory(at: repoDir.appendingPathComponent("scripts/transcribe"), withIntermediateDirectories: true)
    try! "x".write(to: repoDir.appendingPathComponent("scripts/transcribe/moede_transcribe.py"), atomically: true, encoding: .utf8)
    let noBundle = tmp.appendingPathComponent("tom/Resources")
    check(MeetingTranscriber.defaultScriptPath(home: fakeHome.path, environment: ["DIKTAT_TRANSCRIBE_SCRIPT": "/x/y.py"], resourceURL: bundleRes, bundleURL: tmp) == "/x/y.py",
          "standardsti: miljøvariabel vinder")
    check(MeetingTranscriber.defaultScriptPath(home: fakeHome.path, environment: [:], resourceURL: bundleRes, bundleURL: tmp).hasSuffix("App.app/Contents/Resources/transcribe/moede_transcribe.py"),
          "standardsti: appens bundt")
    let built = repoDir.appendingPathComponent(".local-build/Build/Products/Release/Diktat.app")
    check(MeetingTranscriber.defaultScriptPath(home: fakeHome.path, environment: [:], resourceURL: noBundle, bundleURL: built) == repoDir.appendingPathComponent("scripts/transcribe/moede_transcribe.py").path,
          "standardsti: repoets scripts/transcribe, når appen ligger i en bygge-mappe")
    let fallbackPath = MeetingTranscriber.defaultScriptPath(home: fakeHome.path, environment: [:], resourceURL: noBundle, bundleURL: tmp.appendingPathComponent("A.app"))
    check(!fallbackPath.contains("CloudStorage"), "standardsti: ingen sti til nogens Drive eller vault")

    // 4. Script mangler, python mangler, mappe uden meta.json
    defaults.set("/findes/ikke/moede_transcribe.py", forKey: MeetingTranscriber.scriptKey)
    let g = makeMeeting("ingenscript")
    tr.enqueue(folder: g, automatic: false)
    if case .failed(let msg, _) = tr.state(for: g) { check(msg.contains("findes ikke") && msg.contains("scripts/transcribe"), "script mangler: dansk besked med henvisning til scripts/transcribe") } else { check(false, "script mangler: forventede failed") }
    defaults.set(script.path, forKey: MeetingTranscriber.scriptKey)
    let tr2 = MeetingTranscriber(defaults: defaults, environment: [:], home: fakeHome.path, launchctlFallback: false)
    tr2.pythonCandidates = ["/findes/ikke/python"]
    let h = makeMeeting("ingenpython")
    tr2.enqueue(folder: h, automatic: false)
    if case .failed(let msg, _) = tr2.state(for: h) { check(msg.contains("Python 3 blev ikke fundet"), "python mangler: dansk besked") } else { check(false, "python mangler: forventede failed") }
    let noMeta = tmp.appendingPathComponent("Moeder/utenmeta")
    try! fm.createDirectory(at: noMeta, withIntermediateDirectories: true)
    check(!tr.enqueue(folder: noMeta, automatic: true) && (tr.lastMessage ?? "").contains("meta.json"), "uden meta.json: afvist med besked")

    // 5. Afbrudt optagelse startes ikke af sig selv: kun stop() kalder enqueue(automatic: true). Her: status uden kørsel.
    let i = makeMeeting("afbrudt")
    try! "{\"status\":\"interrupted\"}".write(to: i.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)
    check(tr.state(for: i) == .none, "afbrudt optagelse: ingen automatisk status, knappen er tilgængelig")

    // 6. Optagelse kører: job venter
    writeScript("""
    printf '# M\\n\\n[00:00:00] Mig: x\\n' > "$1/transskript.txt"
    """)
    var recording = true
    tr.isRecording = { recording }
    let r = makeMeeting("optager")
    tr.enqueue(folder: r, automatic: true)
    check(tr.state(for: r) == .queued(waitingForRecording: true), "optagelse kører: job venter")
    recording = false
    check(await waitUntil(15) { tr.state(for: r) == .ready }, "optagelse stoppet: jobbet starter og bliver klar")
    tr.isRecording = { false }

    // 7. HF_TOKEN: videregives til barnet, men står ikke i loggen og ikke i nogen fil
    let trTok = MeetingTranscriber(defaults: defaults, environment: ["HF_TOKEN": "hemmelig-testvaerdi-123"], home: fakeHome.path, launchctlFallback: false)
    writeScript("""
    if [ -n "$HF_TOKEN" ]; then echo "token-sat" > "$1/token_flag.txt"; else echo "token-mangler" > "$1/token_flag.txt"; fi
    echo "env: PATH=$PATH"
    printf '# M\\n\\n[00:00:00] Mig: x\\n' > "$1/transskript.txt"
    """)
    let k = makeMeeting("token")
    trTok.enqueue(folder: k, automatic: false)
    check(await waitUntil(10) { trTok.state(for: k) == .ready }, "HF_TOKEN: kørsel færdig")
    check((try? String(contentsOf: k.appendingPathComponent("token_flag.txt"), encoding: .utf8)) == "token-sat\n", "HF_TOKEN: videregivet til underprocessen")
    var leak = false
    for file in (try? fm.contentsOfDirectory(atPath: k.path)) ?? [] {
        if let txt = try? String(contentsOf: k.appendingPathComponent(file), encoding: .utf8), txt.contains("hemmelig-testvaerdi") { leak = true }
    }
    check(!leak, "HF_TOKEN: værdien står ikke i nogen fil i mødemappen")
    let logK = (try? String(contentsOf: k.appendingPathComponent("transskribering.log"), encoding: .utf8)) ?? ""
    check(logK.contains("/opt/homebrew/bin"), "PATH: Homebrew er med i underprocessens PATH")
    trTok.refreshDiarizationAvailability()
    check(trTok.diarizationAvailable, "HF_TOKEN: diarizationAvailable = true")
    tr.refreshDiarizationAvailability()
    check(!tr.diarizationAvailable, "HF_TOKEN mangler: diarizationAvailable = false")

    // 7b. K5: appens modelmappe gives videre som DIKTAT_WHISPER_MODELS (hjemmemappen er en tom, falsk mappe)
    writeScript("""
    echo "${DIKTAT_WHISPER_MODELS:-ikke-sat}" > "$1/modeldir.txt"
    printf '# M\\n\\n[00:00:00] Mig: x\\n' > "$1/transskript.txt"
    """)
    let kd = makeMeeting("modelmappe")
    tr.enqueue(folder: kd, automatic: false)
    check(await waitUntil(10) { tr.state(for: kd) == .ready }, "K5: kørsel færdig")
    let seenDir = ((try? String(contentsOf: kd.appendingPathComponent("modeldir.txt"), encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    check(seenDir == fakeHome.path + "/Library/Application Support/local.diktat.app/WhisperModels", "K5: underprocessen får appens modelmappe (\(seenDir))")
    check(MeetingTranscriber.modelsDirectoryForScripts(environment: ["DIKTAT_WHISPER_MODELS": "/egen/mappe"], home: "/x") == nil, "K5: en mappe brugeren selv har sat, overskrives ikke")
    check(MeetingTranscriber.modelsDirectoryForScripts(environment: ["DIKTAT_WHISPER_MODELS": "  "], home: "/x") == "/x/Library/Application Support/local.diktat.app/WhisperModels", "K5: tom variabel tæller som ikke sat")

    // 8. Appen lukkes midt i en kørsel: underprocessen stoppes, ingen halv fil der ligner en færdig, markeret afbrudt
    writeScript("""
    echo "TRIN: Transskriberer" 
    echo "halv" > "$1/.transskript.txt.tmp-1"
    sleep 30
    printf '# M\\n\\n[00:00:00] Mig: x\\n' > "$1/transskript.txt"
    """)
    let q = makeMeeting("lukket")
    tr.enqueue(folder: q, automatic: true)
    check(await waitUntil(5) { if case .running = tr.state(for: q) { return true } else { return false } }, "lukning: kørsel i gang")
    try? await Task.sleep(nanoseconds: 500_000_000)
    NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
    check(!fm.fileExists(atPath: q.appendingPathComponent("transskript.txt").path), "lukning: ingen transskript.txt")
    check(tr.readStatus(q)?.state == "failed" && (tr.readStatus(q)?.message ?? "").contains("afbrudt"), "lukning: statusfil siger afbrudt")
    // Genstart af appen: en ny instans ser mappen som fejlet, ikke som klar
    let tr3 = MeetingTranscriber(defaults: defaults, environment: [:], home: fakeHome.path, launchctlFallback: false)
    if case .failed(let msg, let kept) = tr3.state(for: q) { check(msg.contains("afbrudt") && !kept, "lukning: efter genstart vises Fejlet/afbrudt og knappen kan bruges") } else { check(false, "lukning: efter genstart forventede failed") }

    // 9. Forældreløs 'running' (appen dræbt med kill -9): recoverStale markerer afbrudt
    let z = makeMeeting("doed")
    let st = MeetingTranscriptStatusFile(state: "running", message: nil, startedAt: Date(), finishedAt: nil, model: "large-v3", language: "da", automatic: true)
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
    try! enc.encode(st).write(to: z.appendingPathComponent("transskript.status.json"))
    tr3.recoverStale(in: tmp.appendingPathComponent("Moeder"))
    if case .failed(let msg, _) = tr3.state(for: z) { check(msg.contains("afbrudt"), "kill -9: forældreløs 'running' markeres afbrudt ved opstart") } else { check(false, "kill -9: forventede failed") }

    // 10. Tom lyd/script der returnerer 0 uden at skrive: ikke 'klar'
    writeScript("exit 0\n")
    let e = makeMeeting("intet")
    let tr4 = MeetingTranscriber(defaults: defaults, environment: [:], home: fakeHome.path, launchctlFallback: false)
    tr4.enqueue(folder: e, automatic: false)
    _ = await waitUntil(10) { if case .failed = tr4.state(for: e) { return true } else { return false } }
    if case .failed(let msg, _) = tr4.state(for: e) { check(msg.contains("skrev intet nyt transskript"), "exit 0 uden fil: fejl, ikke klar") } else { check(false, "exit 0 uden fil: forventede failed, fik \(tr4.state(for: e))") }

    // 11. Mødetitel (syntetiske transskripter, falsk model). Titlen ændrer aldrig transskript eller lyd.
    final class Flag: @unchecked Sendable { var calls = 0 }
    let long = """
    # Møde
    Optagelse startet 03/01-2026 kl. 10.00. Tider er fra optagelsens start.

    [00:00:00] Mig: Jeg ringer, fordi jeg er i tvivl om fristen for høringssvar til lokalplanen for området ved stationen.
    [00:00:09] De 1: Ja, fristen er fjerde december, og jeg vil gerne sende et kort svar nu og supplere senere, når naboerne har talt sammen.
    [00:00:20] Mig: Det kan du godt, men vigtigst er det, at høringssvaret kommer med inden fristen, så kommunen kan behandle det.
    [00:00:30] De 1: Tak, så skriver jeg til kommunen i weekenden og beder om at få fristen forlænget, hvis naboerne ikke er klar.
    """
    func titledMeeting(_ name: String, transcript: String = long, meta: String = "{\"title\":\"Møde\",\"status\":\"stopped\",\"sources\":{\"mik\":\"mikrofon\"},\"segments\":[]}") -> URL {
        let d = makeMeeting(name)
        try! meta.write(to: d.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)
        try! transcript.write(to: d.appendingPathComponent("transskript.txt"), atomically: true, encoding: .utf8)
        return d
    }
    func metaTitle(_ d: URL) -> (String?, String?) {
        let m = MeetingTitler.readMeta(d)
        return (m?["title"] as? String, m?["titleSource"] as? String)
    }
    func logOf(_ d: URL) -> String { (try? String(contentsOf: d.appendingPathComponent("transskribering.log"), encoding: .utf8)) ?? "" }
    func newTitler() -> MeetingTitler {
        let t = MeetingTitler()
        t.retryDelay = 0.2
        t.timeout = 3
        return t
    }
    func settled(_ t: MeetingTitler) async -> Bool { await waitUntil(10) { t.pending.isEmpty } }

    // 11a. Titel skrevet, resten af meta.json og alle filer urørte, ingen halve filer
    let ta = newTitler()
    ta.generate = { _, _ in "Frist for høringssvar til lokalplan\n" }
    let da = titledMeeting("titel-a")
    let daAudio = audioHash(da), daTranscript = (try? String(contentsOf: da.appendingPathComponent("transskript.txt"), encoding: .utf8)) ?? ""
    ta.enqueue(folder: da)
    check(await settled(ta), "titel: kørsel færdig")
    check(metaTitle(da) == ("Frist for høringssvar til lokalplan", "auto"), "titel: skrevet i meta.json med titleSource auto (\(metaTitle(da)))")
    check((MeetingTitler.readMeta(da)?["sources"] as? [String: String])?["mik"] == "mikrofon" && MeetingTitler.readMeta(da)?["status"] as? String == "stopped", "titel: resten af meta.json uændret")
    check(MeetingTitler.readMeta(da)?["titleUpdatedAt"] != nil, "titel: titleUpdatedAt sat")
    check(audioHash(da) == daAudio && (try? String(contentsOf: da.appendingPathComponent("transskript.txt"), encoding: .utf8)) == daTranscript, "titel: lyd og transskript uændret")
    check(((try? fm.contentsOfDirectory(atPath: da.path)) ?? []).filter { $0.contains("tmp") || $0.hasPrefix(".") }.isEmpty, "titel: ingen midlertidige filer tilbage (atomisk skrivning)")
    check(logOf(da).contains("Titel sat automatisk"), "titel: loggen siger det")

    // 11b. Modellen mangler (standardopsætning uden model): Møde, transskriptet klar, dansk bemærkning
    let tb = newTitler()
    let db = titledMeeting("titel-b")
    tb.enqueue(folder: db)
    check(await settled(tb), "model mangler: kørsel færdig")
    check(metaTitle(db) == ("Møde", nil), "model mangler: titlen er stadig Møde")
    check(logOf(db).contains("Titlen kunne ikke laves") && logOf(db).contains("ikke sat nogen titelmodel"), "model mangler: dansk bemærkning i loggen")
    check(FileManager.default.fileExists(atPath: db.appendingPathComponent("transskript.txt").path), "model mangler: transskriptet er der stadig")

    // 11c. Timeout: modellen svarer ikke
    let tc = newTitler()
    tc.timeout = 0.5
    tc.generate = { _, _ in try await Task.sleep(nanoseconds: 20_000_000_000); return "Aldrig set" }
    let dc = titledMeeting("titel-c")
    let started = Date()
    tc.enqueue(folder: dc)
    check(await settled(tc), "timeout: kørsel færdig")
    check(Date().timeIntervalSince(started) < 4, "timeout: gav op efter ca. et halvt sekund, ikke efter 20 (\(Date().timeIntervalSince(started)) s)")
    check(metaTitle(dc) == ("Møde", nil) && logOf(dc).contains("svarede ikke"), "timeout: titlen Møde og bemærkning i loggen")

    // 11d. Model der ignorerer afbrydelse (blokerer tråden): timeout holder alligevel
    let td = newTitler()
    td.timeout = 0.5
    td.generate = { _, _ in
        await Task.detached { Thread.sleep(forTimeInterval: 3) }.value  // blokerer og ignorerer afbrydelse
        return "Aldrig set"
    }
    let dd = titledMeeting("titel-d")
    let startedD = Date()
    td.enqueue(folder: dd)
    check(await settled(td) && Date().timeIntervalSince(startedD) < 4, "timeout: virker også, når modellen slet ikke reagerer")

    // 11e. Manuel titel bevares: rettet FØR, UNDER og efter «Transskribér igen»
    let te = newTitler()
    let flagE = Flag()
    te.generate = { _, _ in flagE.calls += 1; return "Frist for høringssvar til lokalplan" }
    let de = titledMeeting("titel-e")
    te.rename(folder: de, to: "  Anna og haven \n")
    check(metaTitle(de) == ("Anna og haven", "manual"), "manuel: titel rettet og markeret manual (\(metaTitle(de)))")
    te.enqueue(folder: de)
    try? await Task.sleep(nanoseconds: 400_000_000)
    check(flagE.calls == 0 && metaTitle(de).0 == "Anna og haven", "manuel: automatisk titel overskriver ikke og modellen kaldes ikke")
    // Gennem hele kæden: Transskribér igen
    writeScript("""
    printf '# Møde\\n\\n[00:00:00] Mig: hej\\n' > "$1/transskript.txt"
    """)
    let trE = MeetingTranscriber(defaults: defaults, environment: [:], home: fakeHome.path, launchctlFallback: false)
    trE.onTranscriptReady = { te.enqueue(folder: $0) }
    trE.enqueue(folder: de, automatic: false)
    check(await waitUntil(15) { trE.state(for: de) == .ready }, "manuel: Transskribér igen er kørt færdig")
    try? await Task.sleep(nanoseconds: 500_000_000)
    check(metaTitle(de) == ("Anna og haven", "manual") && flagE.calls == 0, "manuel: titlen står uændret efter Transskribér igen")
    // Rettet mens modellen arbejder
    let tf = newTitler()
    tf.generate = { _, _ in try await Task.sleep(nanoseconds: 800_000_000); return "Frist for høringssvar til lokalplan" }
    let df = titledMeeting("titel-f")
    tf.enqueue(folder: df)
    try? await Task.sleep(nanoseconds: 300_000_000)
    tf.rename(folder: df, to: "Min titel")
    check(await settled(tf), "manuel under kørsel: færdig")
    check(metaTitle(df) == ("Min titel", "manual") && logOf(df).contains("rettet undervejs"), "manuel under kørsel: brugerens titel vandt (\(metaTitle(df)))")
    // Titel skrevet ved start af optagelsen (ikke «Møde», ingen kilde) regnes som manuel
    let tg = newTitler()
    let flagG = Flag()
    tg.generate = { _, _ in flagG.calls += 1; return "Frist for høringssvar til lokalplan" }
    let dg = titledMeeting("titel-g", meta: "{\"title\":\"Viking VVM\",\"status\":\"stopped\"}")
    tg.enqueue(folder: dg)
    try? await Task.sleep(nanoseconds: 400_000_000)
    check(flagG.calls == 0 && metaTitle(dg).0 == "Viking VVM", "start-titel: bevares")
    // Tom titel nulstiller og lader appen foreslå ny
    tg.rename(folder: dg, to: "   ")
    check(await settled(tg) && metaTitle(dg) == ("Frist for høringssvar til lokalplan", "auto"), "tom titel: nulstillet og ny automatisk titel (\(metaTitle(dg)))")
    // Automatisk titel må rettes af en ny automatisk titel (Transskribér igen), men ikke af brugeren frem for
    let th = newTitler()
    th.generate = { _, _ in "Gennemgang af timer og budget" }
    th.enqueue(folder: dg)
    check(await settled(th) && metaTitle(dg).0 == "Gennemgang af timer og budget", "auto: kan opdateres af en ny automatisk titel")

    // 11f. Meningsløst eller for kort: modellen kaldes ikke, titlen er Møde
    let ti = newTitler()
    let flagI = Flag()
    ti.generate = { _, _ in flagI.calls += 1; return "Test af lyd og mikrofon" }
    let di = titledMeeting("titel-i", transcript: "# Møde\n\n[00:00:00] Mig: Test, test. En, to, tre.\n[00:00:05] Mig: Hører du mig?\n[00:00:09] De 1: Øh. Ja.\n")
    ti.enqueue(folder: di)
    check(await settled(ti) && flagI.calls == 0 && metaTitle(di) == ("Møde", nil), "meningsløst: Møde uden at kalde modellen")
    check(logOf(di).contains("for kort eller uklar"), "meningsløst: bemærkning i loggen")
    // Modellen selv siger Møde, når samtalen er lang men uklar
    let tj = newTitler()
    tj.generate = { _, _ in "Møde" }
    let dj = titledMeeting("titel-j")
    tj.enqueue(folder: dj)
    check(await settled(tj) && metaTitle(dj) == ("Møde", nil), "uklar: modellen svarer Møde, titlen bliver Møde")

    // 11g. Opfundne navne, tal og forkerte former afvises
    let tk = newTitler()
    var answers = ["Møde med Test Eksempelsen om budget", "Frist for 500 høringssvar", "Gennemgang af the budget", "Frist for høringssvar til lokalplan for hele den nye bydel i kommunen", "Nu skriver jeg som aftalt HEMMELIG KODE", ""]
    let answerQueue = ResponseQueue(answers)
    tk.generate = { _, _ in answerQueue.next() }
    for (i, _) in answers.enumerated() {
        let d = titledMeeting("titel-k\(i)")
        tk.enqueue(folder: d)
        check(await settled(tk) && metaTitle(d) == ("Møde", nil), "afvist svar \(i + 1): titlen bliver Møde (\(metaTitle(d)))")
    }
    answers.removeAll()
    // Renser pynt
    let c1 = MeetingTitle.clean("\"Titel: Frist for høringssvar.\"\n", transcript: long)
    check(c1.title == "Frist for høringssvar", "rens: anførselstegn, Titel: og punktum fjernet (\(c1.title ?? "nil"))")
    check(MeetingTitle.clean("Frist for Eksempelsen", transcript: long).title == nil, "rens: opfundet navn midt i titlen afvises")
    check(MeetingTitle.clean("Telefonopkald om høringssvar", transcript: long).title == "Telefonopkald om høringssvar", "rens: generisk første ord er ok")
    check(MeetingTitle.clean("Eksempelsen ringer om høringssvar", transcript: long).title == nil, "rens: opfundet navn som første ord afvises")
    check(MeetingTitle.clean("Fristen for høringssvar", transcript: long).title == "Fristen for høringssvar", "rens: bøjet ord fra samtalen er ok")

    // 11g2. Fund fra Codex-gennemlæsningen: konstruerede svar skal afvises
    func rej(_ t: String, _ model: String, _ label: String) {
        check(MeetingTitle.clean(model, transcript: t).title == nil, "Codex-fund: \(label) afvises")
    }
    rej("Vi taler om budget og tilbud", "Møde om eBay og tilbud", "mixedCase-navn (eBay)")
    rej("Andersen ringede om budgettet i dag", "Møde med Andersson om budget", "navn der kun ligner (Andersson)")
    rej("Budgettet for 2026 er klar", "Gennemgang af 2 budgetter nu", "tal der kun er en del af et andet tal")
    rej("Vi taler om budget og tilbud", "Gennemgang af ½ budget nu", "brøktegn")
    rej("Vi taler om budget og tilbud", "Gennemgang\tbudget\tog\ttilbud\tfor\tdet\tnye\tår\tnu", "tabulator-adskilte ord (ni)")
    rej("Vi taler om budget og tilbud", "Gennemgang af budget og tilbud\nDet kan jeg ikke afgøre.", "forklaring på linje to")
    rej("Vi taler om budget og tilbud", "Gennemgang of the budget", "engelsk titel")
    check(MeetingTitle.clean("Ravnsholms budget og tilbud nu", transcript: "Vi er i Ravnsholm og taler budget og tilbud").title != nil, "navn med -s er ok")
    let inf = await { () async -> String in
        let o = await MeetingTitle.make(transcriptFile: long, timeout: .infinity) { _, _ in "Frist for høringssvar til lokalplan" }
        return o.title
    }()
    check(inf == "Frist for høringssvar til lokalplan", "timeout uendelig crasher ikke")
    // Rettelse af et møde der optages må ikke ske (recorderen overskriver meta.json)
    let tr2d = newTitler()
    let drec = titledMeeting("titel-rec", meta: "{\"title\":\"Møde\",\"status\":\"recording\"}")
    check(!tr2d.rename(folder: drec, to: "Min titel") && metaTitle(drec) == ("Møde", nil), "rettelse under optagelse afvises, titlen er uændret")

    check(MeetingTitle.clean("VVM-screening af biogasanlæg", transcript: "Vi skal lave en VVM og screening af biogasanlægget").title == "VVM-screening af biogasanlæg", "bindestreg: VVM-screening ok når VVM står i samtalen")
    check(MeetingTitle.clean("VVM-screening af biogasanlæg", transcript: "Vi skal lave en screening af biogasanlægget").title == nil, "bindestreg: VVM-screening afvises når VVM ikke står i samtalen")
    check(MeetingTitle.clean("Møde om Ravnsholm-sagen nu", transcript: "Vi taler om sagen og budgettet nu").title == nil, "bindestreg: opfundet navn før bindestreg afvises")

    // 11g3. For kort titel (1-2 ord): ét genforsøg, aldrig flere
    final class Calls: @unchecked Sendable { var systems: [String] = []; var n = 0 }
    let cs = Calls()
    let o1 = await MeetingTitle.make(transcriptFile: long) { sys, _ in cs.systems.append(sys); cs.n += 1; return cs.n == 1 ? "Frist" : "Frist for høringssvar til lokalplan" }
    check(o1.title == "Frist for høringssvar til lokalplan" && cs.n == 2 && cs.systems[1].contains("mindst tre ord") && !cs.systems[0].contains("mindst tre ord"), "for kort titel: genforsøg giver titel (\(cs.n) kald)")
    let cs2 = Calls()
    let o2 = await MeetingTitle.make(transcriptFile: long) { _, _ in cs2.n += 1; return "Frist" }
    check(o2.title == "Møde" && cs2.n == 2 && !o2.retryable, "for kort titel to gange: Møde efter højst to kald (\(cs2.n))")
    let cs3 = Calls()
    let o3 = await MeetingTitle.make(transcriptFile: long) { _, _ in cs3.n += 1; return "Frist for høringssvar til lokalplan for hele den nye bydel i kommunen" }
    check(o3.title == "Møde" && cs3.n == 1, "for lang titel: intet genforsøg")

    // 11h. Ventetid: intet kører, mens der optages eller transskriberes
    let tl = newTitler()
    let flagL = Flag()
    tl.generate = { _, _ in flagL.calls += 1; return "Frist for høringssvar til lokalplan" }
    var wait = true
    tl.shouldWait = { wait }
    let dl = titledMeeting("titel-l")
    tl.enqueue(folder: dl)
    try? await Task.sleep(nanoseconds: 700_000_000)
    check(flagL.calls == 0 && tl.pending.contains("titel-l"), "venter: modellen kaldes ikke, mens der optages")
    wait = false
    check(await settled(tl) && metaTitle(dl).0 == "Frist for høringssvar til lokalplan", "venter: kører, når optagelsen er slut")
    let beforeDup = flagL.calls
    tl.enqueue(folder: dl); tl.enqueue(folder: dl)
    _ = await settled(tl)
    check(flagL.calls - beforeDup <= 1, "kø: samme møde to gange giver højst ét kald")

    // 11i. Ødelagt meta.json: titlen kan ikke skrives, intet vælter, transskriptet urørt
    let tm = newTitler()
    tm.generate = { _, _ in "Frist for høringssvar til lokalplan" }
    let dm = titledMeeting("titel-m", meta: "{ikke json")
    tm.enqueue(folder: dm)
    check(await settled(tm) && FileManager.default.fileExists(atPath: dm.appendingPathComponent("transskript.txt").path), "ødelagt meta.json: ingen titel, transskript urørt")

    // 12. titelmodel (falsk Ollama på 127.0.0.1): svar, nede, timeout, genforsøg, gamle møder urørt, manuel titel bevares
    let tdir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TITLE_TEST_DIR"] ?? NSTemporaryDirectory())
    func requests(_ port: Int) -> [[String: Any]] {
        let txt = (try? String(contentsOf: tdir.appendingPathComponent("req_\(port).log"), encoding: .utf8)) ?? ""
        return txt.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }
    let rootR = tmp.appendingPathComponent("Moeder-titel")
    try! fm.createDirectory(at: rootR, withIntermediateDirectories: true)
    func mk(_ name: String, meta: String = "{\"title\":\"Møde\",\"status\":\"stopped\"}", transcript: String? = long) -> URL {
        let d = rootR.appendingPathComponent(name)
        try! fm.createDirectory(at: d, withIntermediateDirectories: true)
        try! meta.write(to: d.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)
        if let transcript { try! transcript.write(to: d.appendingPathComponent("transskript.txt"), atomically: true, encoding: .utf8) }
        return d
    }
    func metaBytes(_ d: URL) -> Data { (try? Data(contentsOf: d.appendingPathComponent("meta.json"))) ?? Data() }
    func pendingFlag(_ d: URL) -> Bool { MeetingTitler.readMeta(d)?["titlePending"] as? Bool == true }
    func attemptsOf(_ d: URL) -> Int { MeetingTitler.readMeta(d)?["titleAttempts"] as? Int ?? 0 }
    let wanted = "Frist for høringssvar til lokalplan"

    // 12a. Svar fra serveren: titel skrevet, forespørgslen er til 127.0.0.1 med den rigtige model og uden tidsstempler
    let h1 = newTitler(); h1.generate = MeetingTitleModel.makeGenerator(port: (portBase + 1))
    let dh1 = mk("a-ok")
    h1.enqueue(folder: dh1)
    check(await settled(h1) && metaTitle(dh1) == (wanted, "auto") && !pendingFlag(dh1), "titelmodel: svar giver titel, markeringen fjernes (\(metaTitle(dh1)))")
    if let r = requests((portBase + 1)).first, let body = r["body"] as? [String: Any] {
        check(r["path"] as? String == "/api/generate" && (r["host"] as? String) == "127.0.0.1:\(portBase + 1)", "titelmodel: forespørgsel til 127.0.0.1 /api/generate")
        check(body["model"] as? String == "test-model" && body["stream"] as? Bool == false && body["think"] as? Bool == false, "titelmodel: model test-model, ikke streamet, think false")
        check((body["options"] as? [String: Any])?["temperature"] as? Int == 0, "titelmodel: temperatur 0")
        let prompt = body["prompt"] as? String ?? ""
        check(!prompt.contains("[00:") && !prompt.contains("Optagelse startet") && prompt.count <= 3100, "titelmodel: sender ingen tidsstempler eller overskrift og højst ca. 3000 tegn (\(prompt.count))")
    } else { check(false, "titelmodel: forespørgslen nåede serveren") }
    // 12b. Tænkeblok fjernes
    let h2 = newTitler(); h2.generate = MeetingTitleModel.makeGenerator(port: (portBase + 2))
    let dh2 = mk("b-think")
    h2.enqueue(folder: dh2)
    check(await settled(h2) && metaTitle(dh2) == (wanted, "auto"), "titelmodel: <think>-blok fjernes (\(metaTitle(dh2)))")
    // 12c. Serveren nede (ingen lytter): Møde, markering bevares, transskript urørt, dansk linje
    let h3 = newTitler(); h3.generate = MeetingTitleModel.makeGenerator(port: (portBase + 99))
    let dh3 = mk("c-nede")
    h3.enqueue(folder: dh3)
    check(await settled(h3), "nede: kørsel færdig")
    check(metaTitle(dh3) == ("Møde", nil) && pendingFlag(dh3) && attemptsOf(dh3) == 1, "nede: titlen Møde, markering og forsøg 1 (\(metaTitle(dh3)), \(attemptsOf(dh3)))")
    check(logOf(dh3).contains("kunne ikke nås") && logOf(dh3).contains("Prøver igen senere"), "nede: dansk linje i loggen")
    check(FileManager.default.fileExists(atPath: dh3.appendingPathComponent("transskript.txt").path), "nede: transskriptet urørt")
    // 12d. Genforsøg efter genstart (ny titler = ny opstart): titlen kommer, gamle møder og manuelle titler røres ikke
    let dGammel = mk("d-gammel")                       // fandtes i forvejen: ingen markering
    let dManuel = mk("e-manuel", meta: "{\"title\":\"Min titel\",\"titleSource\":\"manual\",\"titlePending\":true,\"status\":\"stopped\"}")
    let dUdenTekst = mk("f-udentekst", meta: "{\"title\":\"Møde\",\"titlePending\":true,\"status\":\"stopped\"}", transcript: nil)
    let gammelBytes = metaBytes(dGammel), manuelBytes = metaBytes(dManuel), udenBytes = metaBytes(dUdenTekst)
    let before = requests((portBase + 1)).count
    let h4 = newTitler(); h4.generate = MeetingTitleModel.makeGenerator(port: (portBase + 1))
    h4.scanForPending(root: rootR)
    check(await settled(h4), "genforsøg: færdig")
    check(metaTitle(dh3) == (wanted, "auto") && !pendingFlag(dh3), "genforsøg: mødet, der ventede, fik sin titel (\(metaTitle(dh3)))")
    check(requests((portBase + 1)).count == before + 1, "genforsøg: kun ét møde sendt til titelmodellen (\(requests((portBase + 1)).count - before))")
    check(metaBytes(dGammel) == gammelBytes && !FileManager.default.fileExists(atPath: dGammel.appendingPathComponent("transskribering.log").path), "genforsøg: gammelt møde uden markering er urørt")
    check(metaBytes(dManuel) == manuelBytes, "genforsøg: manuel titel er urørt")
    check(metaBytes(dUdenTekst) == udenBytes, "genforsøg: møde uden transskript er urørt")
    check(metaTitle(dh1) == (wanted, "auto") && metaTitle(dh2) == (wanted, "auto"), "genforsøg: allerede titlede møder er urørte")
    // 12e. Timeout
    let h5 = newTitler(); h5.generate = MeetingTitleModel.makeGenerator(port: (portBase + 3)); h5.timeout = 1
    let dh5 = mk("g-timeout")
    let t5 = Date()
    h5.enqueue(folder: dh5)
    check(await settled(h5) && Date().timeIntervalSince(t5) < 6, "timeout: gav op efter ca. 1 s mod en server der hænger (\(Date().timeIntervalSince(t5)) s)")
    check(metaTitle(dh5) == ("Møde", nil) && pendingFlag(dh5) && logOf(dh5).contains("svarede ikke"), "timeout: Møde, markering bevaret, dansk linje")
    // 12f. Serverfejl og ulæseligt svar prøves igen, tomt svar afgør sagen
    for (port, label, keep) in [((portBase + 4), "500", true), ((portBase + 5), "ulæseligt svar", true), ((portBase + 6), "tomt svar", false)] {
        let ht = newTitler(); ht.generate = MeetingTitleModel.makeGenerator(port: port)
        let d = mk("h-\(port)")
        ht.enqueue(folder: d)
        check(await settled(ht) && metaTitle(d) == ("Møde", nil) && pendingFlag(d) == keep, "\(label): Møde, markering \(keep ? "bevaret" : "fjernet") (\(pendingFlag(d)))")
    }
    // 12g. Omdirigering følges ikke
    let beforeRedirect = requests((portBase + 1)).count
    let hr = newTitler(); hr.generate = MeetingTitleModel.makeGenerator(port: (portBase + 7))
    let dr = mk("i-redirect")
    hr.enqueue(folder: dr)
    check(await settled(hr) && metaTitle(dr) == ("Møde", nil) && pendingFlag(dr) && requests((portBase + 1)).count == beforeRedirect, "omdirigering: ikke fulgt, intet sendt videre")
    // 12h. Ingen genforsøg under optagelse eller transskription
    let flagW = Flag()
    let hw = newTitler()
    hw.generate = { _, _ in flagW.calls += 1; return wanted }
    var busy = true
    hw.shouldWait = { busy }
    let rootW = tmp.appendingPathComponent("Moeder-venter")
    try! fm.createDirectory(at: rootW, withIntermediateDirectories: true)
    let dw = rootW.appendingPathComponent("j")
    try! fm.createDirectory(at: dw, withIntermediateDirectories: true)
    try! "{\"title\":\"Møde\",\"titlePending\":true,\"status\":\"stopped\"}".write(to: dw.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)
    try! long.write(to: dw.appendingPathComponent("transskript.txt"), atomically: true, encoding: .utf8)
    hw.scanForPending(root: rootW)
    try? await Task.sleep(nanoseconds: 700_000_000)
    check(flagW.calls == 0, "genforsøg venter, mens der optages eller transskriberes")
    busy = false
    check(await settled(hw) && metaTitle(dw) == (wanted, "auto") && flagW.calls == 1, "genforsøg kører, når optagelsen er slut")
    // 12i. Giver aldrig op: markeringen står, også efter mange mislykkede forsøg, og der logges kun sjældent
    let hc = newTitler(); hc.generate = MeetingTitleModel.makeGenerator(port: (portBase + 99))
    let rootC = tmp.appendingPathComponent("Moeder-opgiv")
    try! fm.createDirectory(at: rootC, withIntermediateDirectories: true)
    let dc2 = rootC.appendingPathComponent("k")
    try! fm.createDirectory(at: dc2, withIntermediateDirectories: true)
    try! "{\"title\":\"Møde\",\"titlePending\":true,\"titleAttempts\":49,\"status\":\"stopped\"}".write(to: dc2.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)
    try! long.write(to: dc2.appendingPathComponent("transskript.txt"), atomically: true, encoding: .utf8)
    hc.scanForPending(root: rootC); _ = await settled(hc)
    check(pendingFlag(dc2) && attemptsOf(dc2) == 50 && metaTitle(dc2) == ("Møde", nil), "ingen opgivelse: markering bevaret efter 50 forsøg")
    hc.scanForPending(root: rootC); _ = await settled(hc)
    check(attemptsOf(dc2) == 51 && !logOf(dc2).contains("forsøg 51"), "ingen opgivelse: kun hvert sjette forsøg logges")
    // 12i2. Markeringen går ikke tabt, hvis brugeren nulstiller titlen midt i et mislykket forsøg (Codex-fund)
    let hn = newTitler()
    hn.generate = { _, _ in try await Task.sleep(nanoseconds: 600_000_000); throw MeetingTitleModel.ModelError.unreachable("test") }
    let dn = mk("l-nulstil")
    hn.enqueue(folder: dn)
    try? await Task.sleep(nanoseconds: 200_000_000)
    hn.rename(folder: dn, to: "Midlertidig")
    hn.rename(folder: dn, to: "")
    check(await settled(hn) && pendingFlag(dn) && metaTitle(dn) == ("Møde", nil), "nulstil under forsøg: markeringen bevares (\(pendingFlag(dn)))")
    // 12i3. Andet forsøg (for kort titel) der fejler, giver en retryable fejl og ikke en afgjort sag
    let cs4 = Calls()
    let o4 = await MeetingTitle.make(transcriptFile: long) { _, _ in cs4.n += 1; if cs4.n == 1 { return "Frist" }; throw MeetingTitleModel.ModelError.unreachable("test") }
    check(o4.title == "Møde" && o4.retryable && cs4.n == 2, "andet forsøg fejler: retryable")
    // 12i4. done:false afvises som ufuldstændigt svar
    let hd = newTitler(); hd.generate = MeetingTitleModel.makeGenerator(port: (portBase + 8))
    let dd2 = mk("m-notdone")
    hd.enqueue(folder: dd2)
    check(await settled(hd) && metaTitle(dd2) == ("Møde", nil) && pendingFlag(dd2), "done:false: afvist og prøves igen")
    // 12j. «Transskribér igen» på et gammelt møde er et eksplicit valg og giver titel
    let hj = newTitler(); hj.generate = { _, _ in wanted }
    hj.enqueue(folder: dGammel)
    check(await settled(hj) && metaTitle(dGammel) == (wanted, "auto"), "Transskribér igen på gammelt møde giver titel (eksplicit valg)")
    // 12k. Fast interval: titlen kommer af sig selv, når modellen er tilbage
    let hk = newTitler()
    hk.scanInterval = 0.4
    let flagK = Flag()
    hk.generate = { _, _ in flagK.calls += 1; if flagK.calls < 2 { throw MeetingTitleModel.ModelError.unreachable("test") }; return wanted }
    let rootK = tmp.appendingPathComponent("Moeder-interval")
    try! fm.createDirectory(at: rootK, withIntermediateDirectories: true)
    let dk = rootK.appendingPathComponent("a")
    try! fm.createDirectory(at: dk, withIntermediateDirectories: true)
    try! "{\"title\":\"Møde\",\"titlePending\":true,\"status\":\"stopped\"}".write(to: dk.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)
    try! long.write(to: dk.appendingPathComponent("transskript.txt"), atomically: true, encoding: .utf8)
    hk.startAutoRetry(root: rootK)
    check(await waitUntil(10) { metaTitle(dk).0 == wanted }, "interval: titlen kommer af sig selv efter et mislykket forsøg")

    // 12m. Svarer modellen «Møde» på et rigtigt møde, skrives en TITEL-linje (ikke tavst), og prompten giver ikke udvej ved uklarhed
    check(MeetingTitle.systemPrompt.contains("giv altid dit bedste bud") && !MeetingTitle.systemPrompt.contains("Er det uklart"),
          "prompt: giver altid et bud, ingen udvej ved uklarhed")
    let om = await MeetingTitle.make(transcriptFile: long, generate: { _, _ in "Møde" })
    check(om.title == "Møde" && (om.note ?? "").contains("Modellen svarede Møde"), "modellen svarer Møde på langt møde: bemærkning i outcome (\(om.note ?? "ingen"))")
    let tq = newTitler(); tq.generate = { _, _ in "Møde" }
    let dq = titledMeeting("titel-moede-svar")
    tq.enqueue(folder: dq)
    check(await settled(tq), "modellen svarer Møde: kørsel færdig")
    let logq = (try? String(contentsOf: dq.appendingPathComponent("transskribering.log"), encoding: .utf8)) ?? ""
    check(logq.contains("TITEL:") && logq.contains("Modellen svarede Møde"), "modellen svarer Møde: TITEL-linje i transskribering.log")
    let shortM = await MeetingTitle.make(transcriptFile: "# Møde\n\n[00:00:01] Mig: test", generate: { _, _ in "Møde" })
    check(shortM.note?.contains("for kort") == true, "for kort transskript: den eksisterende besked, modellen kaldes ikke")

    // 12n. D5: fravalg under kald. Der tjekkes før hvert HTTP-forsøg, før lagring, og et kald i gang afbrydes.
    final class OnOff: @unchecked Sendable {
        private let lock = NSLock(); private var _on = true; private var _calls = 0
        var on: Bool { get { lock.lock(); defer { lock.unlock() }; return _on } set { lock.lock(); _on = newValue; lock.unlock() } }
        var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
        func call() { lock.lock(); _calls += 1; lock.unlock() }
        /// Sand de første n gange, derefter falsk (til at slå fra midt i et kald).
        func trueForFirst(_ n: Int) -> Bool { call(); return calls <= n }
    }
    // 12n-1. Slået fra, mens modellen svarer: titlen gemmes IKKE
    let sw1 = OnOff()
    let tD1 = newTitler(); tD1.isEnabled = { sw1.on }
    tD1.generate = { _, _ in sw1.call(); sw1.on = false; try? await Task.sleep(nanoseconds: 300_000_000); return wanted }
    let dD1 = mk("d5-lagring")
    tD1.enqueue(folder: dD1)
    check(await settled(tD1), "D5 lagring: kørsel færdig")
    check(metaTitle(dD1) == ("Møde", nil), "D5 lagring: slået fra under kaldet, så titlen gemmes ikke (\(metaTitle(dD1)))")
    check(logOf(dD1).contains("slået fra"), "D5 lagring: bemærkning i loggen")
    // 12n-2. Slået fra, mens mødet stod i kø: modellen kaldes slet ikke
    let sw2 = OnOff()
    let tD2 = newTitler(); tD2.isEnabled = { sw2.on }
    var waitD2 = true
    tD2.shouldWait = { waitD2 }
    tD2.generate = { _, _ in sw2.call(); return wanted }
    let dD2 = mk("d5-kø")
    tD2.enqueue(folder: dD2)
    sw2.on = false
    waitD2 = false
    check(await settled(tD2) && sw2.calls == 0 && metaTitle(dD2) == ("Møde", nil), "D5 kø: slået fra i køen, modellen kaldes ikke (\(sw2.calls) kald)")
    // 12n-3. Før hvert HTTP-forsøg: andet forsøg (uden think) sendes ikke, hvis titlen er slået fra imellem
    let beforeNoThink = requests(portBase + 9).count
    let sw3 = OnOff()
    let gD3 = MeetingTitleModel.makeGenerator(port: portBase + 9, isStillEnabled: { sw3.trueForFirst(1) })
    do { _ = try await gD3("s", "i"); check(false, "D5 forsøg: andet HTTP-forsøg blev afbrudt") }
    catch { check(error is CancellationError, "D5 forsøg: afbrudt med CancellationError (\(error))") }
    check(requests(portBase + 9).count == beforeNoThink + 1, "D5 forsøg: kun ét HTTP-forsøg nåede serveren (\(requests(portBase + 9).count - beforeNoThink))")
    let beforeOff = requests(portBase + 1).count
    let gD3b = MeetingTitleModel.makeGenerator(port: portBase + 1, isStillEnabled: { false })
    do { _ = try await gD3b("s", "i"); check(false, "D5 forsøg: intet sendt, når titlen er slået fra") }
    catch { check(error is CancellationError && requests(portBase + 1).count == beforeOff, "D5 forsøg: slået fra, så der sendes ingen forespørgsel") }
    // 12n-4. Andet kald til modellen (for kort titel) springes over, hvis titlen blev slået fra efter første
    let sw4 = OnOff(); let cs4n = Flag()
    let o4n = await MeetingTitle.make(transcriptFile: long, isStillEnabled: { sw4.trueForFirst(1) }) { _, _ in cs4n.calls += 1; return "Frist" }
    check(cs4n.calls == 1 && o4n.cancelled && o4n.isFallback, "D5 andet kald: springes over, når titlen er slået fra imellem (\(cs4n.calls) kald)")
    // 12n-5. Et kald i gang afbrydes (serveren svarer aldrig, timeout 20 s)
    let sw5 = OnOff()
    let tD5 = newTitler(); tD5.timeout = 20; tD5.isEnabled = { sw5.on }
    tD5.generate = MeetingTitleModel.makeGenerator(port: portBase + 3, isStillEnabled: { sw5.on })
    let beforeHang = requests(portBase + 3).count
    let dD5 = mk("d5-afbryd")
    let t0D5 = Date()
    tD5.enqueue(folder: dD5)
    check(await waitUntil(5) { requests(portBase + 3).count > beforeHang }, "D5 afbryd: forespørgslen nåede serveren")
    sw5.on = false
    tD5.cancelInFlight()
    check(await settled(tD5) && Date().timeIntervalSince(t0D5) < 8, "D5 afbryd: kaldet afbrydes i stedet for at vente på timeout (\(String(format: "%.1f", Date().timeIntervalSince(t0D5))) s)")
    check(metaTitle(dD5) == ("Møde", nil), "D5 afbryd: intet gemt")
    // 12n-6. Via indstillingen: slås titel fra i UserDefaults, afbrydes kaldet af sig selv
    let d6suite = "local.diktat.app.d5-\(UUID().uuidString)"
    let d6 = UserDefaults(suiteName: d6suite)!
    d6.set(true, forKey: MeetingTitleSettings.enabledKey)
    d6.set("test-model", forKey: MeetingTitleSettings.modelKey)
    d6.set("http://127.0.0.1:\(portBase + 3)", forKey: MeetingTitleSettings.urlKey)
    let tD6 = newTitler(); tD6.timeout = 20
    MeetingTitleModel.install(into: tD6, defaults: d6)
    let beforeHang6 = requests(portBase + 3).count
    let dD6 = mk("d5-indstilling")
    let t0D6 = Date()
    tD6.enqueue(folder: dD6)
    check(await waitUntil(5) { requests(portBase + 3).count > beforeHang6 }, "D5 indstilling: forespørgslen nåede serveren")
    d6.set(false, forKey: MeetingTitleSettings.enabledKey)
    check(await settled(tD6) && Date().timeIntervalSince(t0D6) < 8, "D5 indstilling: titel slået fra afbryder kaldet (\(String(format: "%.1f", Date().timeIntervalSince(t0D6))) s)")
    check(metaTitle(dD6) == ("Møde", nil), "D5 indstilling: intet gemt")
    d6.removePersistentDomain(forName: d6suite)

    // 13. Titel er FRA som standard: ingen indstilling = ingen kald, ingen ændring i meta.json, ingen markering
    let freshSuite = "local.diktat.app.title-default-\(UUID().uuidString)"
    let fresh = UserDefaults(suiteName: freshSuite)!
    check(MeetingTitleSettings.isEnabled(fresh) == false, "titel: FRA som standard i et nyt UserDefaults-domæne")
    check(MeetingTitleSettings.urlString(fresh) == "http://127.0.0.1:11434", "titel: standardadressen er 127.0.0.1:11434")
    check(MeetingTitleSettings.modelName(fresh) == "", "titel: intet modelnavn som standard")
    fresh.set(true, forKey: MeetingTitleSettings.enabledKey)
    check(MeetingTitleSettings.isEnabled(fresh) == false, "titel: slået til uden modelnavn er stadig FRA")
    fresh.set("qwen3:8b", forKey: MeetingTitleSettings.modelKey)
    check(MeetingTitleSettings.isEnabled(fresh) == true, "titel: til + modelnavn = TIL")
    fresh.removePersistentDomain(forName: freshSuite)
    let off = UserDefaults(suiteName: freshSuite + "-off")!
    let tOff = newTitler()
    nonisolated(unsafe) var offCalls = 0
    MeetingTitleModel.install(into: tOff, defaults: off)
    let realGen = tOff.generate
    tOff.generate = { s, i in offCalls += 1; return try await realGen(s, i) }
    let dOff = titledMeeting("titel-fra-standard")
    let metaBefore = (try? Data(contentsOf: dOff.appendingPathComponent("meta.json"))) ?? Data()
    tOff.enqueue(folder: dOff)
    tOff.scanForPending(root: dOff.deletingLastPathComponent())
    try? await Task.sleep(nanoseconds: 500_000_000)
    let metaAfter = (try? Data(contentsOf: dOff.appendingPathComponent("meta.json"))) ?? Data()
    check(offCalls == 0 && tOff.pending.isEmpty, "titel FRA: modellen kaldes ikke og intet ligger i kø")
    check(metaBefore == metaAfter, "titel FRA: meta.json er byte for byte uændret (ingen titel, ingen markering)")
    check(MeetingTitleSettings.isEnabled(off) == false, "titel FRA: stadig FRA efter forsøget")
    check(MeetingTitle.displayName(title: "Møde", titleSource: nil, startedAt: Date(timeIntervalSince1970: 1_762_341_720)).contains("kl."),
          "titel FRA: mødet vises med dato og tid")
    check(MeetingTitle.displayName(title: "Min titel", titleSource: "manual", startedAt: Date()) == "Min titel", "titel: egen titel vises uændret")
    // Slået til men adressen er en offentlig vært: afvises, titlen bliver Møde og intet sendes
    let pub = UserDefaults(suiteName: freshSuite + "-pub")!
    pub.set(true, forKey: MeetingTitleSettings.enabledKey)
    pub.set("qwen3:8b", forKey: MeetingTitleSettings.modelKey)
    pub.set("http://example.com:11434", forKey: MeetingTitleSettings.urlKey)
    do {
        _ = try await MeetingTitleModel.makeConfiguredGenerator(defaults: pub)("s", "i")
        check(false, "titel: offentlig adresse blev afvist")
    } catch {
        check((error as? MeetingTitleModel.ModelError).map { if case .addressNotAllowed = $0 { return true } else { return false } } ?? false,
              "titel: offentlig adresse afvises, før noget sendes")
    }
    // Adresse på lokalnettet kræver «Tillad anden maskine»
    pub.set("http://192.168.1.20:11434", forKey: MeetingTitleSettings.urlKey)
    do {
        _ = try await MeetingTitleModel.makeConfiguredGenerator(defaults: pub)("s", "i")
        check(false, "titel: lokalnet uden tilladelse blev afvist")
    } catch {
        check((error as? MeetingTitleModel.ModelError).map { if case .addressNotAllowed = $0 { return true } else { return false } } ?? false,
              "titel: lokalnet-adresse afvises, når «Tillad anden maskine» er FRA")
    }
    for suffix in ["-off", "-pub"] { UserDefaults(suiteName: freshSuite + suffix)!.removePersistentDomain(forName: freshSuite + suffix) }

    try? fm.removeItem(at: tmp)
    UserDefaults.standard.removePersistentDomain(forName: suite)
    print(failures == 0 ? "ALLE TESTS BESTÅET" : "\(failures) FEJL")
    exit(failures == 0 ? 0 : 1)
}

Task { @MainActor in await run() }
RunLoop.main.run()
