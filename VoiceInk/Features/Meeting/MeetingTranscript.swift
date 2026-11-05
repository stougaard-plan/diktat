import Foundation

/// Et læst transskript (`transskript.txt` fra moede_transcribe.py). Rent tekstarbejde, ingen afhængigheder.
struct MeetingTranscript {
    struct Line: Identifiable, Equatable {
        let id: Int
        let time: String
        let speaker: String
        let text: String
    }

    var title: String
    /// Overskriftslinjer (dato, forklaring af Mig/De, forbehold).
    var info: [String]
    /// Bemærkninger fra kørslen, fx at De ikke er delt op i talere.
    var notes: [String]
    var lines: [Line]
    /// Hele filen, uændret. Det er den, "Kopiér transskript" lægger på udklipsholderen.
    var fullText: String

    private static let lineRegex = try! NSRegularExpression(
        pattern: #"^\[(\d{2,}:\d{2}:\d{2})\]\s+([^:\[\]]{1,40}):\s?(.*)$"#)

    static func parse(_ text: String) -> MeetingTranscript {
        var title = ""
        var info: [String] = []
        var notes: [String] = []
        var lines: [Line] = []
        var inNotes = false
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let range = NSRange(line.startIndex..., in: line)
            if let m = lineRegex.firstMatch(in: line, range: range),
                let t = Range(m.range(at: 1), in: line), let s = Range(m.range(at: 2), in: line),
                let x = Range(m.range(at: 3), in: line)
            {
                inNotes = false
                lines.append(Line(id: lines.count, time: String(line[t]), speaker: String(line[s]), text: String(line[x])))
                continue
            }
            // Tekstlinjer efter første tidsstempel hører til forrige replik (tekst kan indeholde linjeskift).
            if !lines.isEmpty {
                if !line.isEmpty {
                    let last = lines.removeLast()
                    lines.append(Line(id: last.id, time: last.time, speaker: last.speaker, text: last.text + " " + line))
                }
                continue
            }
            if line.hasPrefix("# ") {
                title = String(line.dropFirst(2))
            } else if line == "Bemærkninger:" {
                inNotes = true
            } else if inNotes, line.hasPrefix("- ") {
                notes.append(String(line.dropFirst(2)))
            } else if !line.isEmpty {
                info.append(line)
            }
        }
        return MeetingTranscript(title: title, info: info, notes: notes, lines: lines, fullText: text)
    }
}
