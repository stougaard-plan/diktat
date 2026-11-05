import AVFoundation
import Foundation

// D3: en konverteringsfejl må ikke være tavs, og vagthunden (secondsSinceLastFrame) må ikke tilfredsstilles af
// buffere, der kommer ind men aldrig bliver skrevet. Uden lyd fra hardware: syntetiske buffere.

var failures = 0
func check(_ c: Bool, _ m: String) { print(c ? "OK   " : "FEJL ", m); if !c { failures += 1 } }

let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
func tone() -> AVAudioPCMBuffer {
    let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4800)!
    b.frameLength = 4800
    for i in 0..<4800 { b.floatChannelData![0][i] = 0.5 * sin(2 * .pi * 440 * Float(i) / 48000) }
    return b
}

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("konv-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }

let w = MeetingSegmentWriter(track: "mik", directory: dir) { _ in }
_ = w.rotate()

// 1. Normal skrivning holder vagthunden i live.
for _ in 0..<5 { w.append(tone()) }
Thread.sleep(forTimeInterval: 0.5)
check(w.secondsSinceLastFrame < 1.0, "normal skrivning: seneste skrivning er frisk (\(String(format: "%.2f", w.secondsSinceLastFrame)) s)")
#if HAS_CONVERSION_STATUS
check(w.health.conversionError == nil, "normal skrivning: ingen konverteringsfejl")
#endif

// 2. Konverteringen fejler, mens buffere stadig kommer ind.
MeetingSegmentWriter.injectConversionFailure = true
Thread.sleep(forTimeInterval: 1.3)           // lad "seneste vellykkede skrivning" blive gammel
for _ in 0..<10 { w.append(tone()); Thread.sleep(forTimeInterval: 0.1) }   // et sekund med buffere, ingen vellykket skrivning
Thread.sleep(forTimeInterval: 0.3)
check(w.secondsSinceLastFrame >= 1.0,
      "konverteringsfejl: vagthundens ur tilfredsstilles IKKE af indkommende buffere (\(String(format: "%.2f", w.secondsSinceLastFrame)) s)")
#if HAS_CONVERSION_STATUS
check(w.health.conversionError != nil, "konverteringsfejl: fejlen står i status (\(w.health.conversionError ?? "nil"))")
check(w.health.secondsSinceLastWrite >= 1.0, "konverteringsfejl: seneste vellykkede skrivning er gammel")
check(w.health.noDataSeconds < 1.0, "konverteringsfejl: kilden leverer stadig data (fejlen er ikke 'ingen data')")
#endif

// 3. Fejlen forsvinder, og alt er i orden igen.
MeetingSegmentWriter.injectConversionFailure = false
for _ in 0..<3 { w.append(tone()) }
Thread.sleep(forTimeInterval: 0.5)
check(w.secondsSinceLastFrame < 1.0, "efter retablering: skrivning er frisk igen")
#if HAS_CONVERSION_STATUS
check(w.health.conversionError == nil, "efter retablering: konverteringsfejlen er ryddet")
#endif

w.close()
print(failures == 0 ? "ALLE TESTS BESTÅET" : "\(failures) FEJL")
exit(failures == 0 ? 0 : 1)
