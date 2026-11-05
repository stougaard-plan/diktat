import AppKit

// Tegner Diktat-ikonet: mørk flade, tre lydstreger, midterste i accentfarven.
func render(size: Int, template: Bool) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let dark = NSColor(srgbRed: 0x0F/255, green: 0x0F/255, blue: 0x0F/255, alpha: 1)
    let accent = NSColor(srgbRed: 0x4A/255, green: 0x6B/255, blue: 0x5C/255, alpha: 1)
    if !template {
        let inset = s * 0.098
        let r = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
        dark.setFill()
        NSBezierPath(roundedRect: r, xRadius: r.width * 0.225, yRadius: r.width * 0.225).fill()
    }
    // tre streger: relative højder
    let heights: [CGFloat] = [0.26, 0.46, 0.26]
    let barW = s * (template ? 0.17 : 0.105)
    let gap = s * (template ? 0.10 : 0.075)
    let total = 3 * barW + 2 * gap
    var x = (s - total) / 2
    for (i, h) in heights.enumerated() {
        let bh = s * h * (template ? 1.5 : 1.0)
        let rect = NSRect(x: x, y: (s - bh) / 2, width: barW, height: bh)
        if template { NSColor.black.setFill() } else { (i == 1 ? accent : NSColor.white).setFill() }
        NSBezierPath(roundedRect: rect, xRadius: barW / 2, yRadius: barW / 2).fill()
        x += barW + gap
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments[1]
for n in [16, 32, 64, 128, 256, 512, 1024] {
    try! render(size: n, template: false).write(to: URL(fileURLWithPath: "\(out)/AppIcon.appiconset/\(n)-mac.png"))
}
let menuSize = Int(CommandLine.arguments[2])!
try! render(size: menuSize, template: true).write(to: URL(fileURLWithPath: "\(out)/menuBarIcon.imageset/menuBarIcon.png"))
