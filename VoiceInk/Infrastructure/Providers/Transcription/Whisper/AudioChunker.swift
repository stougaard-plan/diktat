import Foundation

/// Deler lang lyd i stykker på højst `maxSeconds` ved den stilleste ramme.
/// Bruges fordi dikteringen kører whisper uden tidsstempler (`no_timestamps`): uden dem
/// rykker whisper altid et helt 30 s-vindue frem og taber tekst, der falder over vinduesgrænsen.
enum AudioChunker {
    static let sampleRate = 16_000
    static let maxSeconds = 28
    static let minSeconds = 20
    static let frame = 800 // 50 ms
    static let minTail = 2 * sampleRate

    /// Halvåbne intervaller [start, slut) over hele lyden i rækkefølge.
    static func ranges(samples: [Float]) -> [Range<Int>] {
        let maxLen = maxSeconds * sampleRate
        let minLen = minSeconds * sampleRate
        var out: [Range<Int>] = []
        var start = 0
        while samples.count - start > maxLen {
            let from = start + minLen
            let to = min(start + maxLen, samples.count - minTail)
            var best = from
            var bestEnergy = Float.greatestFiniteMagnitude
            var pos = from
            while pos + frame <= to {
                var sum: Float = 0
                for i in pos..<(pos + frame) { sum += samples[i] * samples[i] }
                if sum < bestEnergy { bestEnergy = sum; best = pos }
                pos += frame
            }
            let cut = best + frame / 2
            out.append(start..<cut)
            start = cut
        }
        out.append(start..<samples.count)
        return out
    }
}
