import Darwin
import AVFoundation
import CoreAudio
import Foundation

// Læser KUN layout (antal buffere, kanaler, bytes, format). Rører aldrig lydindholdet (mData læses ikke).
func addr(_ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func getData<T>(_ id: AudioObjectID, _ a: AudioObjectPropertyAddress, _ t: T.Type) -> T? {
    var a = a; var size = UInt32(MemoryLayout<T>.size)
    let p = UnsafeMutablePointer<T>.allocate(capacity: 1); defer { p.deallocate() }
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, p) == noErr else { return nil }
    return p.pointee
}
func getArray<T>(_ id: AudioObjectID, _ a: AudioObjectPropertyAddress, _ t: T.Type) -> [T] {
    var a = a; var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    var out = [T](unsafeUninitializedCapacity: Int(size) / MemoryLayout<T>.size) { b, n in n = Int(size) / MemoryLayout<T>.size }
    _ = out.withUnsafeMutableBytes { AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0.baseAddress!) }
    return out
}
func getString(_ id: AudioObjectID, _ s: AudioObjectPropertySelector) -> String {
    var a = addr(s); var size = UInt32(MemoryLayout<CFString?>.size); var v: Unmanaged<CFString>?
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr, let v else { return "?" }
    return v.takeRetainedValue() as String
}
func streamConfig(_ dev: AudioObjectID, _ scope: AudioObjectPropertyScope) -> String {
    var a = addr(kAudioDevicePropertyStreamConfiguration, scope); var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &size) == noErr else { return "(ingen)" }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16); defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, raw) == noErr else { return "(fejl)" }
    let l = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return "\(l.count) buffere: " + l.map { "\($0.mNumberChannels)ch" }.joined(separator: ", ")
}
func fmtStr(_ f: AudioStreamBasicDescription) -> String {
    "\(Int(f.mSampleRate)) Hz, \(f.mChannelsPerFrame) kanaler, \(f.mBitsPerChannel) bit, flags=0x\(String(f.mFormatFlags, radix: 16))\(f.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? " non-interleaved" : " interleaved")"
}
func describeStreams(_ dev: AudioObjectID, _ scope: AudioObjectPropertyScope, label: String) {
    let streams = getArray(dev, addr(kAudioDevicePropertyStreams, scope), AudioObjectID.self)
    print("  \(label) streams: \(streams.count)")
    for s in streams {
        let f = getData(s, addr(kAudioStreamPropertyVirtualFormat), AudioStreamBasicDescription.self)
        let start = getData(s, addr(kAudioStreamPropertyStartingChannel), UInt32.self) ?? 0
        let owner = getData(s, addr(kAudioObjectPropertyOwner), AudioObjectID.self) ?? 0
        let phys = getData(s, addr(kAudioStreamPropertyPhysicalFormat), AudioStreamBasicDescription.self)
        print("    stream \(s) ejer=\(owner) startkanal=\(start) virtuelt: \(f.map(fmtStr) ?? "?") fysisk: \(phys.map(fmtStr) ?? "?")")
    }
}
func defaultOutput() -> AudioDeviceID { getData(AudioObjectID(kAudioObjectSystemObject), addr(kAudioHardwarePropertyDefaultSystemOutputDevice), AudioDeviceID.self) ?? 0 }
func uid(_ d: AudioObjectID) -> String { getString(d, kAudioDevicePropertyDeviceUID) }

func trial(withSubDevice: Bool, seconds: Double) {
    let out = defaultOutput()
    let transport = getData(out, addr(kAudioDevicePropertyTransportType), UInt32.self) ?? 0
    print("== Variant: \(withSubDevice ? "MED output som sub-enhed (som appen)" : "UDEN sub-enhed")")
    print("  standard-output: \(getString(out, kAudioObjectPropertyName)) transport=\(String(format: "0x%x", transport)) input: \(streamConfig(out, kAudioObjectPropertyScopeInput)), output: \(streamConfig(out, kAudioObjectPropertyScopeOutput))")
    let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
    desc.name = "probe tap"; desc.uuid = UUID(); desc.isPrivate = true; desc.muteBehavior = .unmuted
    var tap = AudioObjectID(kAudioObjectUnknown)
    var st = AudioHardwareCreateProcessTap(desc, &tap)
    guard st == noErr else { print("  FEJL oprettelse af tap: \(st)"); return }
    defer { AudioHardwareDestroyProcessTap(tap) }
    if let f = getData(tap, addr(kAudioTapPropertyFormat), AudioStreamBasicDescription.self) { print("  tap-format (kAudioTapPropertyFormat): \(fmtStr(f))") }
    var agg: [String: Any] = [
        kAudioAggregateDeviceNameKey: "probe agg", kAudioAggregateDeviceUIDKey: UUID().uuidString,
        kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceTapAutoStartKey: true,
        kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
    ]
    if withSubDevice {
        let u = uid(out)
        agg[kAudioAggregateDeviceMainSubDeviceKey] = u
        agg[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: u]]
    }
    var aggID = AudioObjectID(kAudioObjectUnknown)
    st = AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID)
    guard st == noErr else { print("  FEJL oprettelse af aggregate: \(st)"); return }
    defer { AudioHardwareDestroyAggregateDevice(aggID) }
    print("  aggregate input-konfiguration: \(streamConfig(aggID, kAudioObjectPropertyScopeInput)); output: \(streamConfig(aggID, kAudioObjectPropertyScopeOutput))")
    describeStreams(aggID, kAudioObjectPropertyScopeInput, label: "input")
    describeStreams(aggID, kAudioObjectPropertyScopeOutput, label: "output")
    let subs = getArray(aggID, addr(kAudioAggregateDevicePropertyActiveSubDeviceList), AudioObjectID.self)
    print("  aktive sub-enheder: \(subs.map { "\($0)=\(getString($0, kAudioObjectPropertyName)) input:\(streamConfig($0, kAudioObjectPropertyScopeInput)) output:\(streamConfig($0, kAudioObjectPropertyScopeOutput))" })")
    var proc: AudioDeviceIOProcID?
    var calls = 0
    var layouts: [String: Int] = [:]
    let q = DispatchQueue(label: "probe.io")
    st = AudioDeviceCreateIOProcIDWithBlock(&proc, aggID, q) { _, inData, _, _, _ in
        let l = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        let key = l.map { "\($0.mNumberChannels)ch/\($0.mDataByteSize)B" }.joined(separator: " + ")
        calls += 1; layouts[key, default: 0] += 1   // kun layout, mData læses aldrig
    }
    guard st == noErr, let proc else { print("  FEJL IOProc: \(st)"); return }
    let startSt = AudioDeviceStart(aggID, proc); print("  AudioDeviceStart status: \(startSt)")
    Thread.sleep(forTimeInterval: seconds)
    AudioDeviceStop(aggID, proc); AudioDeviceDestroyIOProcID(aggID, proc)
    print("  IOProc-kald: \(calls). Levererede layout (antal kald): \(layouts)")
}
setvbuf(stdout, nil, _IONBF, 0)
func allDevicesLayout() {
    let devs = getArray(AudioObjectID(kAudioObjectSystemObject), addr(kAudioHardwarePropertyDevices), AudioObjectID.self)
    for d in devs {
        let out = streamConfig(d, kAudioObjectPropertyScopeOutput)
        if out.hasPrefix("0 ") || out == "(ingen)" { continue }
        let name = getString(d, kAudioObjectPropertyName)
        let transport = getData(d, addr(kAudioDevicePropertyTransportType), UInt32.self) ?? 0
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.name = "probe tap"; desc.uuid = UUID(); desc.isPrivate = true; desc.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(desc, &tap) == noErr else { print("tap-fejl for \(name)"); continue }
        let u = uid(d)
        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "probe agg", kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
            kAudioAggregateDeviceMainSubDeviceKey: u, kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: u]],
        ]
        var aggID = AudioObjectID(kAudioObjectUnknown)
        if AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID) == noErr {
            let tf = getData(tap, addr(kAudioTapPropertyFormat), AudioStreamBasicDescription.self)
            let subs = getArray(aggID, addr(kAudioAggregateDevicePropertyActiveSubDeviceList), AudioObjectID.self)
            let subIn = subs.map { streamConfig($0, kAudioObjectPropertyScopeInput) }
            print("• \(name) [transport \(String(format: "0x%x", transport))] enhedens input: \(streamConfig(d, kAudioObjectPropertyScopeInput)) | aggregate input: \(streamConfig(aggID, kAudioObjectPropertyScopeInput)) | aktive sub-enheder input: \(subIn) | tap: \(tf.map(fmtStr) ?? "?")")
            AudioHardwareDestroyAggregateDevice(aggID)
        } else { print("aggregate-fejl for \(name)") }
        AudioHardwareDestroyProcessTap(tap)
    }
}
let mode = CommandLine.arguments.dropFirst().first ?? "begge"
if mode == "alle" { allDevicesLayout(); exit(0) }
if mode != "uden" { trial(withSubDevice: true, seconds: 3.0) }
if mode != "med" { trial(withSubDevice: false, seconds: 3.0) }
