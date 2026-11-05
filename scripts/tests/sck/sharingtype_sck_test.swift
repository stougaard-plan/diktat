import AppKit
import ScreenCaptureKit

// To små paneler: A med sharingType = .none (magenta), B med .readOnly (grøn, kontrol).
// Fanger skærmen med ScreenCaptureKit (SCScreenshotManager) og tæller pixels af hver farve. Ingen lyd.
@MainActor func makePanel(color: NSColor, x: CGFloat, sharing: NSWindow.SharingType) -> NSPanel {
    let p = NSPanel(contentRect: NSRect(x: x, y: 400, width: 200, height: 200), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.backgroundColor = color; p.isOpaque = true; p.level = .statusBar; p.hasShadow = false
    p.sharingType = sharing
    p.orderFrontRegardless()
    return p
}

@MainActor func run() async {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let a = makePanel(color: NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1), x: 100, sharing: .none)
    let b = makePanel(color: NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1), x: 400, sharing: .readOnly)
    try? await Task.sleep(nanoseconds: 1_500_000_000)
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let screenID = a.screen.flatMap { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID }
        print("Skærmtilladelse (preflight): \(CGPreflightScreenCaptureAccess()), paneler på display \(screenID ?? 0), SCK-displays: \(content.displays.map { $0.displayID })")
        guard let display = content.displays.first(where: { $0.displayID == screenID }) ?? content.displays.first else { print("INGEN SKÆRM"); exit(3) }
        let ownIDs = Set([a.windowNumber, b.windowNumber].map { CGWindowID($0) })
        let inList = content.windows.filter { ownIDs.contains($0.windowID) }.map { $0.windowID }
        print("SCK-vinduesliste indeholder: A(.none)=\(inList.contains(CGWindowID(a.windowNumber))) B(.readOnly)=\(inList.contains(CGWindowID(b.windowNumber)))")
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.width = display.width * 2; cfg.height = display.height * 2
        cfg.showsCursor = false
        let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        let w = img.width, h = img.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var mag = 0, grn = 0
        for i in stride(from: 0, to: data.count, by: 4) {
            let r = Int(data[i]), g = Int(data[i+1]), bl = Int(data[i+2])
            if r > 200 && g < 80 && bl > 200 { mag += 1 }
            if g > 200 && r < 80 && bl < 80 { grn += 1 }
        }
        print("SCK-skærmbillede \(w)x\(h): magenta (.none) pixels=\(mag), grøn (.readOnly) pixels=\(grn)")
        print(mag == 0 && grn > 1000 ? "RESULTAT: .none RESPEKTERES af ScreenCaptureKit" : (mag > 1000 && grn > 1000 ? "RESULTAT: .none IGNORERES af ScreenCaptureKit (begge synlige)" : "RESULTAT: uklart (tilladelse mangler?)"))
    } catch { print("FEJL: \(error)"); exit(2) }
    exit(0)
}
Task { await run() }
NSApplication.shared.run()
