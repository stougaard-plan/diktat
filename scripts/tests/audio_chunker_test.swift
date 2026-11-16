import Foundation
var fails = 0
func check(_ ok: Bool, _ name: String) { if ok { print("ok   \(name)") } else { print("FEJL \(name)"); fails += 1 } }
let sr = AudioChunker.sampleRate
func tone(_ s: Double) -> [Float] { (0..<Int(s * Double(sr))).map { _ in 0.3 } }
func quiet(_ s: Double) -> [Float] { [Float](repeating: 0, count: Int(s * Double(sr))) }

// Kort lyd: ét stykke, uændret
let short = tone(25)
check(AudioChunker.ranges(samples: short) == [0..<short.count], "25 s giver ét stykke")
check(AudioChunker.ranges(samples: tone(28)).count == 1, "præcis 28 s giver ét stykke")
check(AudioChunker.ranges(samples: []) == [0..<0], "tom lyd giver ét tomt stykke")

// 41 s med stilhed ved 24 s: snit i stilheden
let a = tone(24) + quiet(1) + tone(16)
let r = AudioChunker.ranges(samples: a)
check(r.count == 2, "41 s giver to stykker")
check(r[0].upperBound >= 24 * sr && r[0].upperBound <= 25 * sr, "snit ligger i stilheden")
check(r.last!.upperBound == a.count && r[0].lowerBound == 0 && r[0].upperBound == r[1].lowerBound, "stykkerne dækker lyden uden hul")

// 83 s: ingen stykker over 28 s, ingen under 2 s til sidst, fuld dækning
let b = tone(23) + quiet(0.5) + tone(25) + quiet(0.5) + tone(26) + quiet(0.5) + tone(7.5)
let rb = AudioChunker.ranges(samples: b)
check(rb.allSatisfy { $0.count <= 28 * sr }, "intet stykke over 28 s")
check(rb.reduce(0) { $0 + $1.count } == b.count, "samlet længde bevaret")
check(rb.count >= 3, "83 s giver mindst tre stykker")

// Lyd lige over grænsen: halen bliver mindst 2 s
let c = tone(28.2)
let rc = AudioChunker.ranges(samples: c)
check(rc.count == 2 && rc[1].count >= 2 * sr, "28,2 s: halen er mindst 2 s")
check(rc.allSatisfy { $0.count <= 28 * sr }, "28,2 s: intet stykke over 28 s")

// Støj uden stilhed: stadig gyldig deling
let d = (0..<(60 * sr)).map { Float(sin(Double($0) * 0.01)) * 0.5 }
let rd = AudioChunker.ranges(samples: d)
check(rd.reduce(0) { $0 + $1.count } == d.count && rd.allSatisfy { $0.count <= 28 * sr && !$0.isEmpty }, "60 s tone deles korrekt")
if fails > 0 { print("\(fails) fejl"); exit(1) }
print("alle grønne")
