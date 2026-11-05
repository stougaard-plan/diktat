import AppKit
import Carbon.HIToolbox
struct Cfg { let id = UUID(); let name = "x" }
final class ModeManager { static let shared = ModeManager(); var configurations: [Cfg] = []; func getConfiguration(with: UUID) -> Cfg? { nil } }
enum StarterModeCatalog { static let templates: [Cfg] = [] }
enum ShortcutStore { static var store: [ShortcutAction: Shortcut] = [:]; static func shortcut(for a: ShortcutAction) -> Shortcut? { store[a] } }
var fails = 0
func check(_ c: Bool, _ m: String) { print(c ? "OK   " : "FEJL ", m); if !c { fails += 1 } }
let M = UInt16(kVK_ANSI_M)
func v(_ s: Shortcut) -> ShortcutValidationError? { ShortcutValidator.validationError(for: s, action: .meetingRecording) }
check(v(.key(keyCode: M, modifierFlags: [.control, .option])) == nil, "Ctrl+Opt+M (standard) tilladt")
check(v(.modifierOnly(keyCode: 58, modifierFlags: [.option])) == .meetingRequiresKeyCombination, "enkelt modifikatortast (Option) afvist")
check(v(.modifierOnly(keyCode: nil, modifierFlags: [.control, .option])) == .meetingRequiresKeyCombination, "kun modifikatorer (Ctrl+Opt) afvist")
check(v(.key(keyCode: M, modifierFlags: [])) == .meetingRequiresKeyCombination, "tast uden modifikator afvist")
check(v(.key(keyCode: UInt16(kVK_F5), modifierFlags: [])) == .meetingRequiresKeyCombination, "F5 uden modifikator afvist")
check(v(.mouseButton(buttonNumber: 3, modifierFlags: [.control])) == .meetingRequiresKeyCombination, "museknap afvist")
ShortcutStore.store[.primaryRecording] = .key(keyCode: M, modifierFlags: [.control, .option])
if case .alreadyUsedBy = v(.key(keyCode: M, modifierFlags: [.control, .option])) ?? .reservedBySystem { check(true, "kollision med dikteringsgenvej afvist") } else { check(false, "kollision med diktering") }
ShortcutStore.store = [.meetingRecording: .key(keyCode: M, modifierFlags: [.control, .option])]
if case .alreadyUsedBy = ShortcutValidator.validationError(for: .key(keyCode: M, modifierFlags: [.control, .option]), action: .primaryRecording) ?? .reservedBySystem { check(true, "diktering kan ikke tage mødegenvejen") } else { check(false, "omvendt kollision") }
check(ShortcutValidator.validationError(for: .modifierOnly(keyCode: 58, modifierFlags: [.option]), action: .primaryRecording) == nil, "diktering må stadig bruge enkelt modifikator (uændret)")
print(fails == 0 ? "ALLE TESTS BESTÅET" : "\(fails) FEJL"); exit(fails == 0 ? 0 : 1)
