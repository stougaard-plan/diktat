import FluidAudio
import Foundation

// Parakeet V3 lokalt, samme kald som Diktat (AsrModels.load + AsrManager.transcribe med language-hint).
// Bruger kun filer i mappen angivet som argument. Skriver JSON-linjer: {file, hint, text, ms}.
@main struct Bench { static func main() async throws {
let args = CommandLine.arguments
guard args.count >= 3 else { print("brug: bench <mappe> <ud.jsonl>"); exit(2) }
let dir = URL(fileURLWithPath: args[1])
let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
let cache = AsrModels.defaultCacheDirectory(for: .v3)
let models = try await AsrModels.load(from: cache, configuration: nil, version: .v3, encoderPrecision: .int8)
let manager = AsrManager(config: .default)
try await manager.loadModels(models)
var out = ""
func run(_ f: URL, hint: Language?) async throws {
    var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
    let t0 = DispatchTime.now()
    let r = try await manager.transcribe(f, decoderState: &state, language: hint)
    let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
    let obj: [String: Any] = ["file": f.lastPathComponent, "hint": hint?.rawValue ?? "ingen", "text": r.text, "ms": ms]
    out += String(data: try JSONSerialization.data(withJSONObject: obj), encoding: .utf8)! + "\n"
}
// opvarmning, ikke med i målingen
if let first = files.first { try await run(first, hint: nil); out = "" }
for f in files {
    try await run(f, hint: .danish)
    try await run(f, hint: nil)
}
try out.write(toFile: args[2], atomically: true, encoding: .utf8)
print("ok \(files.count) filer")
}}
