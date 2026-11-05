import AppKit

var fails = 0
func check(_ c: Bool, _ m: String) { print(c ? "OK   " : "FEJL ", m); if !c { fails += 1 } }

// Syntetiske skærme: hovedskærm 0..1920, ekstern til højre 1920..4480, ekstern over hovedskærmen.
let frames = [NSRect(x: 0, y: 0, width: 1920, height: 1080), NSRect(x: 1920, y: 0, width: 2560, height: 1440), NSRect(x: 0, y: 1080, width: 1920, height: 1080)]
check(RecorderScreenResolver.screenIndex(forMouse: NSPoint(x: 100, y: 100), frames: frames) == 0, "mus på hovedskærmen giver skærm 0")
check(RecorderScreenResolver.screenIndex(forMouse: NSPoint(x: 3000, y: 700), frames: frames) == 1, "mus på ekstern skærm til højre giver skærm 1")
check(RecorderScreenResolver.screenIndex(forMouse: NSPoint(x: 500, y: 1500), frames: frames) == 2, "mus på skærm over giver skærm 2")
check(RecorderScreenResolver.screenIndex(forMouse: NSPoint(x: 9000, y: 9000), frames: frames) == nil, "mus uden for alle skærme giver nil (så falder resolve() tilbage på main)")
check(RecorderScreenResolver.screenIndex(forMouse: NSPoint(x: 1, y: 1), frames: []) == nil, "ingen skærme giver nil")

// Rigtige skærme på denne Mac: resolve() skal give skærmen under musen.
let screens = NSScreen.screens
let mouse = NSEvent.mouseLocation
let underMouse = screens.first(where: { $0.frame.contains(mouse) })
let resolved = RecorderScreenResolver.resolve()
print("INFO \(screens.count) skærme, mus ved \(Int(mouse.x)),\(Int(mouse.y)), NSScreen.main=\(NSScreen.main?.localizedName ?? "nil"), resolve()=\(resolved?.localizedName ?? "nil")")
check(resolved != nil, "resolve() giver en skærm")
if let underMouse { check(resolved == underMouse, "resolve() giver skærmen under musen (\(underMouse.localizedName))") }
print(fails == 0 ? "ALLE TESTS BESTÅET" : "\(fails) FEJL"); exit(fails == 0 ? 0 : 1)
