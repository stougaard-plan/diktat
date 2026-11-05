import AVFoundation
import CoreAudio
import Foundation

var failures = 0
func check(_ c: Bool, _ m: String) { print(c ? "OK   " : "FEJL ", m); if !c { failures += 1 } }

// Tap-format som i appen: float32, 48 kHz, 2 kanaler, interleaved (én stream)
let tapFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true)!
let frames = 4800

func makeList(buffers: Int) -> UnsafeMutablePointer<AudioBufferList> {
    let raw = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<AudioBufferList>.size + 2 * MemoryLayout<AudioBuffer>.size, alignment: 16)
    let p = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
    let abl = UnsafeMutableAudioBufferListPointer(p)
    p.pointee.mNumberBuffers = UInt32(buffers)
    for b in 0..<buffers {
        let ch = buffers == 1 ? 2 : 1
        let n = frames * ch
        let data = UnsafeMutablePointer<Float>.allocate(capacity: n)
        for f in 0..<frames {
            let t = Float(f) / 48000
            if buffers == 1 { data[f*2] = 0.5 * sin(2 * .pi * 440 * t); data[f*2+1] = 0.5 * sin(2 * .pi * 440 * t) }
            else { data[f] = 0.5 * sin(2 * .pi * 440 * t) }
        }
        abl[b] = AudioBuffer(mNumberChannels: UInt32(ch), mDataByteSize: UInt32(n * 4), mData: data)
    }
    return p
}

// Baseline: gammel kode afvises med 2 buffere mod 1-stream format
let two = makeList(buffers: 2)
let old = AVAudioPCMBuffer(pcmFormat: tapFmt, bufferListNoCopy: two, deallocator: nil)
check(old == nil, "gammel metode: 2 buffere mod interleaved tap-format giver nil (fejlen genskabt)")

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tapfix-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

for n in [1, 2] {
    let list = n == 1 ? makeList(buffers: 1) : two
    let res = TapBufferConverter.makeBuffer(from: list, tapFormat: tapFmt)
    guard case .buffer(let buf) = res else { check(false, "\(n) buffer(e): ny metode giver buffer"); continue }
    check(buf.frameLength == AVAudioFrameCount(frames) && buf.format.channelCount == 2 && buf.format.isInterleaved == (n == 1),
          "\(n) buffer(e): buffer med \(buf.frameLength) frames, \(buf.format.channelCount) kanaler, interleaved=\(buf.format.isInterleaved)")
    let w = MeetingSegmentWriter(track: "computer\(n)", directory: dir) { _ in }
    _ = w.rotate()
    for _ in 0..<20 { w.append(buf) }   // 20 x 0,1 s = 2 s
    Thread.sleep(forTimeInterval: 1)
    let name = w.currentFilename!
    w.close()
    let url = dir.appendingPathComponent(name)
    let size = (try! FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int)
    let f = try! AVAudioFile(forReading: url)
    let rb = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
    try! f.read(into: rb)
    var peak: Float = 0
    for i in 0..<Int(rb.frameLength) { peak = max(peak, abs(rb.floatChannelData![0][i])) }
    check(size > 4096 && f.length > 30000 && peak > 0.3, "\(n) buffer(e): .caf \(size) bytes, \(f.length) frames @\(Int(f.fileFormat.sampleRate)) Hz, peak \(peak)")
}

// Tomme og ubrugelige lister
let emptyRaw = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 16)
let ep = emptyRaw.bindMemory(to: AudioBufferList.self, capacity: 1); ep.pointee.mNumberBuffers = 0
if case .empty = TapBufferConverter.makeBuffer(from: ep, tapFormat: tapFmt) { check(true, "0 buffere giver .empty (ingen fejl, ingen crash)") } else { check(false, "0 buffere") }

// Fejlsti: fault og ingen-data
let w = MeetingSegmentWriter(track: "fejl", directory: dir) { _ in }
_ = w.rotate()
check(w.health.sourceFault == nil, "ingen fault før rapport")
w.reportFault("test-fault")
Thread.sleep(forTimeInterval: 0.2)
check(w.health.sourceFault == "test-fault", "reportFault vises i health.sourceFault")
Thread.sleep(forTimeInterval: 1.2)
check(w.health.noDataSeconds >= 1.2, "ingen buffere: noDataSeconds vokser (\(String(format: "%.1f", w.health.noDataSeconds)) s) uden at en eneste buffer er kommet")
w.append({ if case .buffer(let b) = TapBufferConverter.makeBuffer(from: makeList(buffers: 1), tapFormat: tapFmt) { return b }; fatalError() }())
Thread.sleep(forTimeInterval: 0.5)
check(w.health.noDataSeconds < 1 && w.health.sourceFault == nil, "efter en gyldig buffer nulstilles begge")
// ---- Sub-enhedens egen indgang (fx headsets mikrofon) må ikke i computersporet ----
func makeCustomList(_ specs: [(ch: Int, hz: Float)]) -> UnsafeMutablePointer<AudioBufferList> {
    let raw = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<AudioBufferList>.size + 4 * MemoryLayout<AudioBuffer>.size, alignment: 16)
    let p = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
    let abl = UnsafeMutableAudioBufferListPointer(p)
    p.pointee.mNumberBuffers = UInt32(specs.count)
    for (b, sp) in specs.enumerated() {
        let n = frames * sp.ch
        let data = UnsafeMutablePointer<Float>.allocate(capacity: n)
        for f in 0..<frames { let v = 0.5 * sin(2 * .pi * sp.hz * Float(f) / 48000); for c in 0..<sp.ch { data[f * sp.ch + c] = v } }
        abl[b] = AudioBuffer(mNumberChannels: UInt32(sp.ch), mDataByteSize: UInt32(n * 4), mData: data)
    }
    return p
}
func goertzel(_ x: [Float], hz: Float, rate: Float) -> Float {
    let w = 2 * Float.pi * hz / rate, c = 2 * cos(w); var s1: Float = 0, s2: Float = 0
    for v in x { let s = v + c * s1 - s2; s2 = s1; s1 = s }
    return (s1 * s1 + s2 * s2 - c * s1 * s2) / Float(x.count * x.count)
}
func fileEnergy(_ w: MeetingSegmentWriter, buffer: AVAudioPCMBuffer) -> (e440: Float, e880: Float, size: Int) {
    _ = w.rotate()
    for _ in 0..<20 { w.append(buffer) }
    Thread.sleep(forTimeInterval: 1)
    let name = w.currentFilename!
    w.close()
    let url = dir.appendingPathComponent(name)
    let size = (try! FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int)
    let f = try! AVAudioFile(forReading: url)
    let rb = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
    try! f.read(into: rb)
    let x = Array(UnsafeBufferPointer(start: rb.floatChannelData![0], count: Int(rb.frameLength)))
    return (goertzel(x, hz: 440, rate: 16000), goertzel(x, hz: 880, rate: 16000), size)
}
// Tap = 440 Hz. Sub-enhedens indgang = 880 Hz (skal IKKE nå filen).
let cases: [(String, [(ch: Int, hz: Float)], Int)] = [
    ("Layout med enhedens egen mikrofon i buffer 0: 1 buffer med 1 kan. (mik 880 Hz) + 1 buffer med 2 kan. (tap 440 Hz)", [(1, 880), (2, 440)], 1),
    ("2 buffere med hver 2 kan.: enhed 880 Hz + tap 440 Hz", [(2, 880), (2, 440)], 1),
    ("ingen sub-enhed: kun tap 440 Hz, 2 kan. interleaved", [(2, 440)], 0),
    ("ingen sub-enhed: tap non-interleaved (2 x 1 kan.)", [(1, 440), (1, 440)], 0),
    ("sub-enhed med 1 kan. + tap non-interleaved (2 x 1 kan.)", [(1, 880), (1, 440), (1, 440)], 1),
]
for (i, c) in cases.enumerated() {
    let list = makeCustomList(c.1)
    switch TapBufferConverter.makeBuffer(from: list, tapFormat: tapFmt, skippingLeadingBuffers: c.2) {
    case .buffer(let buf):
        let w = MeetingSegmentWriter(track: "computer_s\(i)", directory: dir) { _ in }
        let r = fileEnergy(w, buffer: buf)
        check(r.size > 4096 && r.e440 > 0.005 && r.e880 < r.e440 * 0.001,
              "\(c.0): .caf \(r.size) B, energi 440 Hz=\(String(format: "%.4f", r.e440)) 880 Hz=\(String(format: "%.6f", r.e880)) (kun tap)")
    default: check(false, "\(c.0): ingen buffer")
    }
}
// Uden fix (skip 0) afvises 2 x 2 kan. i stedet for at blive blandet eller skrevet
if case .unsupported(let why) = TapBufferConverter.makeBuffer(from: makeCustomList([(2, 880), (2, 440)]), tapFormat: tapFmt) {
    check(true, "2 x 2 kan. uden kendt sub-enhed afvises (fejl, ikke blanding): \(why.prefix(70))…")
} else { check(false, "2 x 2 kan. uden skip skulle afvises") }
// Forkert antagelse fanges: [tap 2 kan., enhed 1 kan.] med skip 1 giver 1 kan. ≠ 2 → fejl, ikke forkert lyd
if case .unsupported = TapBufferConverter.makeBuffer(from: makeCustomList([(2, 440), (1, 880)]), tapFormat: tapFmt, skippingLeadingBuffers: 1) {
    check(true, "ombyttet rækkefølge fanges af kanaltjekket (fejl i stedet for mikrofon i computersporet)")
} else { check(false, "ombyttet rækkefølge skulle give fejl") }
if case .unsupported = TapBufferConverter.makeBuffer(from: makeCustomList([(1, 880)]), tapFormat: tapFmt, skippingLeadingBuffers: 1) {
    check(true, "kun sub-enhedens buffer, ingen tap: fejl")
} else { check(false, "kun enhedsbuffer skulle give fejl") }
// TapLayout
let p1 = TapLayout.plan(aggregateInputChannels: [1, 2], subDeviceInputBuffers: [1], tapChannels: 2, tapDescription: "2 kan.")
check(p1.leadingNonTapBuffers == 1 && !p1.description.contains("PASSER IKKE"), "layout (1+2, sub-enhed 1 buffer): tap fra buffer 1 — \(p1.description)")
let p2 = TapLayout.plan(aggregateInputChannels: [2], subDeviceInputBuffers: [], tapChannels: 2, tapDescription: "2 kan.")
check(p2.leadingNonTapBuffers == 0, "layout uden sub-enhed: tap fra buffer 0")
let p3 = TapLayout.plan(aggregateInputChannels: [2, 2], subDeviceInputBuffers: [1], tapChannels: 1, tapDescription: "1 kan.")
check(p3.description.contains("PASSER IKKE"), "layout der ikke passer markeres i beskrivelsen")
let p4 = TapLayout.plan(aggregateInputChannels: [2, 1, 2], subDeviceInputBuffers: [1, 1], tapChannels: 2, tapDescription: "2 kan.")
check(p4.leadingNonTapBuffers == 2, "to sub-enheder: de to første buffere springes over")

print(failures == 0 ? "ALLE TESTS BESTÅET" : "\(failures) FEJL")
exit(failures == 0 ? 0 : 1)
