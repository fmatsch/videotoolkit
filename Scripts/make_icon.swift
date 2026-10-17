import AppKit

// Erzeugt AppIcon.iconset-PNGs: swift Scripts/make_icon.swift <ausgabeordner.iconset>
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let rect = NSRect(x: s * 0.06, y: s * 0.06, width: s * 0.88, height: s * 0.88)
    let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(colors: [NSColor(red: 0.16, green: 0.23, blue: 0.55, alpha: 1), NSColor(red: 0.55, green: 0.25, blue: 0.85, alpha: 1)])!
        .draw(in: path, angle: -60)
    // Filmstreifen-Andeutung
    NSColor.white.withAlphaComponent(0.16).setFill()
    for i in 0..<5 {
        let y = rect.minY + rect.height * (0.12 + 0.18 * CGFloat(i))
        NSBezierPath(roundedRect: NSRect(x: rect.minX + rect.width * 0.06, y: y, width: rect.width * 0.07, height: rect.height * 0.09), xRadius: s * 0.01, yRadius: s * 0.01).fill()
        NSBezierPath(roundedRect: NSRect(x: rect.maxX - rect.width * 0.13, y: y, width: rect.width * 0.07, height: rect.height * 0.09), xRadius: s * 0.01, yRadius: s * 0.01).fill()
    }
    if let sym = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: nil) {
        let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.46, weight: .semibold).applying(.init(paletteColors: [.white]))
        let tinted = sym.withSymbolConfiguration(cfg)!
        let sz = tinted.size
        tinted.draw(in: NSRect(x: (s - sz.width) / 2, y: (s - sz.height) / 2, width: sz.width, height: sz.height))
    }
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}
for (name, px) in [("16", 16), ("16@2x", 32), ("32", 32), ("32@2x", 64), ("128", 128), ("128@2x", 256),
                   ("256", 256), ("256@2x", 512), ("512", 512), ("512@2x", 1024)] {
    let file = "\(out)/icon_\(name.replacingOccurrences(of: "@2x", with: ""))x\(name.replacingOccurrences(of: "@2x", with: ""))\(name.contains("@2x") ? "@2x" : "").png"
    try! render(px).write(to: URL(fileURLWithPath: file))
}
