import Foundation
import NaturalLanguage
let data = FileHandle.standardInput.readDataToEndOfFile()
let arr = try! JSONSerialization.jsonObject(with: data) as! [String]
var res: [[String: Any]] = []
for t in arr {
    let r = NLLanguageRecognizer()
    r.languageConstraints = [.danish, .english, .french, .german, .swedish, .norwegian, .dutch, .spanish, .italian, .finnish, .icelandic]
    r.processString(t)
    let h = r.languageHypotheses(withMaximum: 3)
    let top = h.max(by: { $0.value < $1.value })
    res.append(["lang": top?.key.rawValue ?? "", "conf": top?.value ?? 0, "da": h[.danish] ?? 0])
}
print(String(data: try! JSONSerialization.data(withJSONObject: res), encoding: .utf8)!)
