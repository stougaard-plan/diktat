import AVFoundation
import CoreAudio
import Foundation

/// Skriver 16 kHz mono Int16 til CAF-segmenter. Konverterer fra kildens format.
/// Hver segmentfil lukkes rent ved rotation, så et nedbrud højst koster det åbne segment.
final class MeetingSegmentWriter {
    let track: String
    private let directory: URL
    private let queue: DispatchQueue
    private let outFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var index = 0
    private var lastFrameAt = Date()
    private var levelHandler: ((Float) -> Void)?
    private(set) var currentFilename: String?
    /// Starttidspunkt for den løbende periode med digital stilhed (alle samples præcis 0). nil = der er lyd.
    private var silentSince: Date?
    private var writeError: String?
    /// Konvertering til 16 kHz mono fejlede (ingen konverter, ingen plads, konverteringsfejl eller tomt resultat).
    /// Ryddes af næste vellykkede skrivning.
    private var conversionError: String?
    private var openError: String?
    /// Kilden har meldt at den leverer data writeren ikke kan bruge (fx uventet bufferlayout).
    private var sourceFault: String?
    /// Tidspunkt for seneste faktiske buffer fra kilden. Rotation nulstiller den ikke, så en kilde der
    /// aldrig leverer noget stadig kan opdages, også efter vagthundens genstarter.
    private var lastBufferAt: Date?
    private var dataClockStart = Date()
    /// Kun til selvtest: tvinger skrivefejl, så fejlstien køres (DIKTAT_TEST_FAIL_WRITES_AT).
    nonisolated(unsafe) static var injectWriteFailure = false
    /// Kun til test: tvinger en konverteringsfejl, så fejlstien køres.
    nonisolated(unsafe) static var injectConversionFailure = false

    struct Health {
        var silentSeconds: TimeInterval
        var writeError: String?
        /// Seneste konverteringsfejl, hvis konverteringen ikke virker. Lyden bliver ikke skrevet, mens den står der.
        var conversionError: String?
        var openError: String?
        var sourceFault: String?
        /// Sekunder siden seneste buffer (eller siden sporet startede, hvis der aldrig er kommet en).
        var noDataSeconds: TimeInterval
        /// Sekunder siden seneste VELLYKKEDE lydskrivning (eller siden segmentet blev åbnet). Buffere, der kommer ind,
        /// men ikke bliver skrevet, tæller ikke.
        var secondsSinceLastWrite: TimeInterval
    }

    /// Øjebliksbillede af sporets tilstand. Bruges af MeetingRecorder til indikatoren.
    var health: Health {
        queue.sync {
            Health(
                silentSeconds: silentSince.map { Date().timeIntervalSince($0) } ?? 0,
                writeError: writeError, conversionError: conversionError, openError: openError, sourceFault: sourceFault,
                noDataSeconds: Date().timeIntervalSince(lastBufferAt ?? dataClockStart),
                secondsSinceLastWrite: Date().timeIntervalSince(lastFrameAt))
        }
    }

    init(track: String, directory: URL, onLevel: @escaping (Float) -> Void) {
        self.track = track
        self.directory = directory
        self.queue = DispatchQueue(label: "local.diktat.app.meeting.writer.\(track)")
        self.levelHandler = onLevel
    }

    /// Kaldes af kilden, når den modtager data den ikke kan bruge. Må kaldes fra enhver tråd.
    func reportFault(_ message: String) {
        queue.async { [weak self] in self?.sourceFault = message }
    }

    /// Nulstiller uret for "ingen buffere modtaget" (efter dvale, hvor kilderne bevidst stod stille).
    func resetDataClock() {
        queue.async { [weak self] in
            self?.dataClockStart = Date()
            self?.lastBufferAt = nil
        }
    }

    /// Sekunder siden seneste vellykkede lydskrivning. Det er den, vagthunden holder øje med.
    /// En buffer, der kommer ind men ikke kan konverteres eller skrives, nulstiller den IKKE.
    var secondsSinceLastFrame: TimeInterval { queue.sync { Date().timeIntervalSince(lastFrameAt) } }

    /// Lukker det åbne segment og åbner et nyt. Returnerer filnavnet.
    @discardableResult
    func rotate() -> String? {
        queue.sync {
            file = nil  // AVAudioFile lukkes når den frigives
            index += 1
            let name = String(format: "%@_%04d.caf", track, index)
            let url = directory.appendingPathComponent(name)
            do {
                file = try AVAudioFile(
                    forWriting: url, settings: outFormat.settings,
                    commonFormat: .pcmFormatInt16, interleaved: true)
                currentFilename = name
                lastFrameAt = Date()
                openError = nil
                return name
            } catch {
                currentFilename = nil
                openError = "Kan ikke åbne ny lydfil: \(error.localizedDescription)"
                return nil
            }
        }
    }

    func close() {
        queue.sync {
            file = nil
            currentFilename = nil
        }
    }

    /// Tager en kopi af bufferen (kilden genbruger sin) og konverterer asynkront.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let copy = Self.copy(buffer) else { return }
        queue.async { [weak self] in self?.write(copy) }
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        // Kun ankomsten af data noteres her. lastFrameAt (vagthundens ur) flyttes først, når lyden er SKREVET.
        lastBufferAt = Date()
        guard let file else {
            writeError = "Der er ingen åben lydfil"
            return
        }
        if converter == nil || converterInputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outFormat)
            converterInputFormat = buffer.format
        }
        guard let converter else {
            conversionError = "Kan ikke konvertere lyd fra formatet \(buffer.format.sampleRate) Hz, \(buffer.format.channelCount) kanaler"
            return
        }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
            conversionError = "Kan ikke afsætte plads til konverteret lyd"
            return
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if Self.injectConversionFailure {
            error = NSError(
                domain: "Diktat", code: 1, userInfo: [NSLocalizedDescriptionKey: "Simuleret konverteringsfejl"])
        }
        guard error == nil, status != .error else {
            conversionError = "Kan ikke konvertere lyden: \(error?.localizedDescription ?? "ukendt fejl")"
            self.converter = nil  // bygges forfra ved næste buffer
            return
        }
        guard out.frameLength > 0 else {
            // En helt lille buffer kan give 0 frames efter omsampling. En normal buffer gør ikke.
            if buffer.frameLength >= 480 {
                conversionError = "Konverteringen gav ingen lyd ud af \(buffer.frameLength) indgående frames"
            }
            return
        }
        var peak: Int32 = 0
        var rms: Float = 0
        if let samples = out.int16ChannelData?[0] {
            var sum: Double = 0
            for i in 0..<Int(out.frameLength) {
                let raw = Int32(samples[i])
                peak = max(peak, abs(raw))
                let v = Double(raw) / 32768.0
                sum += v * v
            }
            rms = Float((sum / Double(out.frameLength)).squareRoot())
        }
        // Digital stilhed (kun nuller) er noget andet end lav lyd: det er typisk manglende tilladelse eller slået fra.
        if peak == 0 {
            if silentSince == nil { silentSince = Date() }
        } else {
            silentSince = nil
        }
        do {
            if Self.injectWriteFailure {
                throw NSError(
                    domain: NSPOSIXErrorDomain, code: Int(ENOSPC),
                    userInfo: [NSLocalizedDescriptionKey: "Simuleret diskfejl"])
            }
            try file.write(from: out)
            lastFrameAt = Date()   // først nu er lyden skrevet
            writeError = nil
            conversionError = nil
            sourceFault = nil
            levelHandler?(rms)
        } catch {
            writeError = "Kan ikke skrive til lydfilen: \(error.localizedDescription)"
        }
    }

    private static func copy(_ src: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let dst = AVAudioPCMBuffer(pcmFormat: src.format, frameCapacity: src.frameLength) else { return nil }
        dst.frameLength = src.frameLength
        let s = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: src.audioBufferList))
        let d = UnsafeMutableAudioBufferListPointer(dst.mutableAudioBufferList)
        for i in 0..<min(s.count, d.count) {
            if let sp = s[i].mData, let dp = d[i].mData {
                memcpy(dp, sp, Int(min(s[i].mDataByteSize, d[i].mDataByteSize)))
                d[i].mDataByteSize = s[i].mDataByteSize
            }
        }
        return dst
    }
}

/// En lydkilde (mikrofon, systemlyd eller simuleret fil).
protocol MeetingAudioSource: AnyObject {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)? { get set }
    /// Kilden melder data den ikke kunne bruge, så fejlen vises i indikatoren i stedet for at forsvinde.
    var onFault: ((String) -> Void)? { get set }
    /// Kort beskrivelse af kildens faktiske lagdeling (antal buffere, kanaler). Aldrig lydindhold. nil = ikke relevant.
    var layoutDescription: String? { get }
    func start() throws
    func stop()
}

enum MeetingAudioError: LocalizedError {
    case tap(String, OSStatus)
    case noInput
    case symlink(String)
    case noSegments(String)

    var errorDescription: String? {
        switch self {
        case .tap(let what, let status): return "\(what) fejlede (OSStatus \(status))"
        case .noInput: return "Ingen mikrofon at optage fra"
        case .symlink(let what):
            return "Mødemappen er ikke sikker (\(what)). Optagelsen blev ikke startet, så lyden ikke ender et uventet sted."
        case .noSegments(let why): return "Ingen lydfiler kunne åbnes. \(why)"
        }
    }
}

/// Mikrofon via AVAudioEngine. Rører ikke Recorder.swift, så ingen mute og ingen pause af medier.
final class MicrophoneSource: MeetingAudioSource {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onFault: ((String) -> Void)?
    var layoutDescription: String? { nil }
    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    var onConfigurationChange: (() -> Void)?

    func start() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MeetingAudioError.noInput }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.onBuffer?(buffer)
        }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.onConfigurationChange?() }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    func stop() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }
}

/// Bygger en AVAudioPCMBuffer ud fra den AudioBufferList enheden faktisk leverer, men KUN af tappens egne buffere.
/// Aggregate-enheden har standard-output som sub-enhed, og dens egne input-strømme (fx et headsets mikrofon) står
/// først i listen, efterfulgt af tappens strøm(me). De første `skippingLeadingBuffers` buffere hører til sub-enhederne
/// og må aldrig i computersporet. Tallet kommer fra enhedens faktiske konfiguration (TapLayout), ikke fra et gæt.
/// Tap-formatet (kAudioTapPropertyFormat) giver sampleformat, samplerate og kanalantal. Tappens buffere kan være
/// 1 (interleaved) eller flere (non-interleaved, 1 kanal hver). Antal kanaler skal passe til tap-formatet.
enum TapBufferConverter {
    enum Result {
        case buffer(AVAudioPCMBuffer)
        case empty
        case unsupported(String)
    }

    static func makeBuffer(
        from list: UnsafePointer<AudioBufferList>, tapFormat: AVAudioFormat, skippingLeadingBuffers: Int = 0
    ) -> Result {
        let all = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard all.count > 0 else { return .empty }
        let skip = max(0, skippingLeadingBuffers)
        let layout = all.map { "\($0.mNumberChannels) kan." }.joined(separator: " + ")
        guard all.count > skip else {
            return .unsupported("Systemlyd leverer \(all.count) buffere (\(layout)), men alle hører til lydenhedens egen indgang og ingen til tappen")
        }
        let abl = Array(all)[skip...].map { $0 }
        let bits = Int(tapFormat.streamDescription.pointee.mBitsPerChannel)
        guard bits > 0, bits % 8 == 0, tapFormat.commonFormat != .otherFormat else {
            return .unsupported("Lydformatet fra systemlyd kan ikke bruges (commonFormat \(tapFormat.commonFormat.rawValue), \(bits) bit)")
        }
        let sampleBytes = bits / 8
        let interleaved = abl.count == 1
        let channels = interleaved ? Int(abl[0].mNumberChannels) : abl.count
        if !interleaved, abl.contains(where: { $0.mNumberChannels != 1 }) {
            return .unsupported("Systemlyd leverer \(all.count) buffere (\(layout)), og tappens \(abl.count) buffere har flere kanaler pr. buffer, det er uventet")
        }
        guard channels == Int(tapFormat.channelCount) else {
            return .unsupported("Systemlydens buffere (\(layout), \(skip) fra lydenhedens indgang) passer ikke til tappen, som skal have \(tapFormat.channelCount) kanaler")
        }
        guard channels > 0, let format = AVAudioFormat(
            commonFormat: tapFormat.commonFormat, sampleRate: tapFormat.sampleRate,
            channels: AVAudioChannelCount(channels), interleaved: interleaved)
        else {
            return .unsupported("Systemlyd leverer \(abl.count) buffere med \(channels) kanal(er), formatet kan ikke oprettes")
        }
        let bytesPerFrame = sampleBytes * (interleaved ? channels : 1)
        let frames = abl.map { Int($0.mDataByteSize) / bytesPerFrame }.min() ?? 0
        guard frames > 0 else { return .empty }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            return .unsupported("Kunne ikke oprette lydbuffer til \(frames) frames")
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        let dst = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard dst.count == abl.count else {
            return .unsupported("Bufferlayout passer ikke (\(abl.count) leveret, \(dst.count) oprettet)")
        }
        for i in 0..<abl.count {
            guard let sp = abl[i].mData, let dp = dst[i].mData else {
                return .unsupported("Systemlyd leverede en buffer uden data")
            }
            let bytes = frames * bytesPerFrame
            memcpy(dp, sp, bytes)
            dst[i].mDataByteSize = UInt32(bytes)
        }
        return .buffer(buffer)
    }
}

/// Aflæser aggregate-enhedens faktiske input-konfiguration og afgør, hvor mange af de første input-buffere der
/// tilhører sub-enhederne (deres egen indgang) frem for tappen. Kun antal og kanaler, aldrig lydindhold.
enum TapLayout {
    struct Plan: Equatable {
        /// Antal buffere først i listen, der ikke er tappen.
        let leadingNonTapBuffers: Int
        let description: String
    }

    /// aggregateInputChannels: kanaler pr. input-buffer på aggregate-enheden, i leveret rækkefølge.
    /// subDeviceInputBuffers: antal input-buffere hver aktiv sub-enhed selv har.
    static func plan(
        aggregateInputChannels: [Int], subDeviceInputBuffers: [Int], tapChannels: Int, tapDescription: String
    ) -> Plan {
        let skip = subDeviceInputBuffers.reduce(0, +)
        let tapPart = aggregateInputChannels.dropFirst(skip)
        let ok = !tapPart.isEmpty && tapPart.reduce(0, +) == tapChannels
        let desc =
            "aggregate input: \(aggregateInputChannels.count) buffere (\(aggregateInputChannels.map { "\($0) kan." }.joined(separator: " + "))), "
            + "sub-enheder med \(subDeviceInputBuffers.count) enhed(er) og \(skip) input-buffer(e), "
            + "tap: \(tapDescription), tappen er buffer \(skip) og frem"
            + (ok ? "" : " (PASSER IKKE: tappen skulle give \(tapChannels) kanaler)")
        return Plan(leadingNonTapBuffers: skip, description: desc)
    }
}

/// Systemlyd (alle processer) via Core Audio process tap. Kræver tilladelsen "Systemlyd-optagelse".
final class SystemAudioTapSource: MeetingAudioSource {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onFault: ((String) -> Void)?
    private(set) var layoutDescription: String?
    /// Antal første input-buffere, der er sub-enhedens egen indgang (fx et headsets mikrofon) og ikke tappen.
    private var leadingNonTapBuffers = 0
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var format: AVAudioFormat?
    private let ioQueue = DispatchQueue(label: "local.diktat.app.meeting.tap.io", qos: .userInitiated)

    func start() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Diktat mødetap"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw MeetingAudioError.tap("Oprettelse af tap", status) }

        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            stop()
            throw MeetingAudioError.tap("Læsning af tap-format", status)
        }
        self.format = format

        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Diktat mødetap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        if let uid = Self.defaultOutputDeviceUID() {
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = uid
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: uid]]
        }
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else {
            stop()
            throw MeetingAudioError.tap("Oprettelse af aggregate device", status)
        }

        let plan = Self.readLayout(aggregate: aggregateID, tapFormat: format)
        leadingNonTapBuffers = plan.leadingNonTapBuffers
        layoutDescription = plan.description

        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) {
            [weak self] _, inputData, _, _, _ in
            guard let self, let format = self.format else { return }
            switch TapBufferConverter.makeBuffer(
                from: inputData, tapFormat: format, skippingLeadingBuffers: self.leadingNonTapBuffers)
            {
            case .buffer(let buffer): self.onBuffer?(buffer)
            case .empty: break
            case .unsupported(let why): self.onFault?(why)
            }
        }
        guard status == noErr, let procID else {
            stop()
            throw MeetingAudioError.tap("Oprettelse af IOProc", status)
        }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            stop()
            throw MeetingAudioError.tap("Start af lydenhed", status)
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// Aflæser aggregate-enhedens input-konfiguration og sub-enhedernes. Kun antal og kanaler.
    private static func readLayout(aggregate: AudioObjectID, tapFormat: AVAudioFormat) -> TapLayout.Plan {
        let aggregateChannels = inputBufferChannels(of: aggregate)
        var subAddress = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyActiveSubDeviceList, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var subDevices: [AudioObjectID] = []
        if AudioObjectGetPropertyDataSize(aggregate, &subAddress, 0, nil, &size) == noErr, size > 0 {
            subDevices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
            _ = subDevices.withUnsafeMutableBytes {
                AudioObjectGetPropertyData(aggregate, &subAddress, 0, nil, &size, $0.baseAddress!)
            }
        }
        let tapDescription =
            "\(tapFormat.channelCount) kan., \(Int(tapFormat.sampleRate)) Hz, \(tapFormat.streamDescription.pointee.mBitsPerChannel) bit"
            + (tapFormat.isInterleaved ? ", interleaved" : ", non-interleaved")
        return TapLayout.plan(
            aggregateInputChannels: aggregateChannels,
            subDeviceInputBuffers: subDevices.map { inputBufferChannels(of: $0).count },
            tapChannels: Int(tapFormat.channelCount), tapDescription: tapDescription)
    }

    private static func inputBufferChannels(of device: AudioObjectID) -> [Int] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return [] }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }

    private static func defaultOutputDeviceUID() -> String? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return nil }
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, &uid) == noErr,
            let uid
        else { return nil }
        return uid.takeRetainedValue() as String
    }
}

/// Simuleret kilde til test uden macOS-tilladelser: spiller en lydfil i realtid
/// (stilhed før `startDelay` og efter filen). Aktiveres kun af miljøvariablerne
/// DIKTAT_SIM_COMPUTER / DIKTAT_SIM_MIC. Den erstatter IKKE den rigtige optagelse.
final class SimulatedFileSource: MeetingAudioSource {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onFault: ((String) -> Void)?
    var layoutDescription: String? { nil }
    private let url: URL
    private let startDelay: TimeInterval
    private let queue = DispatchQueue(label: "local.diktat.app.meeting.sim")
    private var timer: DispatchSourceTimer?
    private var file: AVAudioFile?
    private var elapsedFrames: AVAudioFramePosition = 0
    private let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    private let chunk: AVAudioFrameCount = 1_600
    /// Leverer kun nuller (digital stilhed), som en spærret systemlydstream gør.
    private let forceSilence: Bool

    init(url: URL, startDelay: TimeInterval = 0, forceSilence: Bool = false) {
        self.url = url
        self.startDelay = startDelay
        self.forceSilence = forceSilence
    }

    func start() throws {
        file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return }
        buffer.frameLength = chunk
        let samples = buffer.floatChannelData![0]
        memset(samples, 0, Int(chunk) * MemoryLayout<Float>.size)
        let startFrame = AVAudioFramePosition(startDelay * 16_000)
        if !forceSilence, elapsedFrames >= startFrame, let file, file.framePosition < file.length,
            let fileBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk)
        {
            try? file.read(into: fileBuffer, frameCount: chunk)
            if let src = fileBuffer.floatChannelData?[0] {
                memcpy(samples, src, Int(fileBuffer.frameLength) * MemoryLayout<Float>.size)
            }
        }
        elapsedFrames += AVAudioFramePosition(chunk)
        onBuffer?(buffer)
    }

    func stop() {
        timer?.cancel()
        timer = nil
        file = nil
    }
}
