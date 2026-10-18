// Renders the app icon at all required sizes into an .iconset folder.
import AppKit
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.09, rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(starting: NSColor(red: 0.95, green: 0.28, blue: 0.25, alpha: 1), ending: NSColor(red: 0.78, green: 0.10, blue: 0.22, alpha: 1))!.draw(in: bg, angle: -90)
    // Page with folded corner
    let pw = rect.width * 0.5, ph = rect.width * 0.62
    let page = NSRect(x: rect.midX - pw / 2, y: rect.midY - ph / 2 - s * 0.01, width: pw, height: ph)
    let fold = pw * 0.28
    let p = NSBezierPath()
    p.move(to: NSPoint(x: page.minX, y: page.minY)); p.line(to: NSPoint(x: page.maxX, y: page.minY))
    p.line(to: NSPoint(x: page.maxX, y: page.maxY - fold)); p.line(to: NSPoint(x: page.maxX - fold, y: page.maxY))
    p.line(to: NSPoint(x: page.minX, y: page.maxY)); p.close()
    NSShadow().apply { $0.shadowBlurRadius = s * 0.02; $0.shadowOffset = NSSize(width: 0, height: -s * 0.01); $0.shadowColor = .black.withAlphaComponent(0.3) }
    NSColor.white.setFill(); p.fill()
    NSShadow().set()
    let f = NSBezierPath()
    f.move(to: NSPoint(x: page.maxX - fold, y: page.maxY)); f.line(to: NSPoint(x: page.maxX - fold, y: page.maxY - fold)); f.line(to: NSPoint(x: page.maxX, y: page.maxY - fold)); f.close()
    NSColor(white: 0.85, alpha: 1).setFill(); f.fill()
    let text = NSAttributedString(string: "PDF", attributes: [.font: NSFont.systemFont(ofSize: pw * 0.3, weight: .heavy), .foregroundColor: NSColor(red: 0.85, green: 0.15, blue: 0.22, alpha: 1)])
    let ts = text.size()
    text.draw(at: NSPoint(x: page.midX - ts.width / 2, y: page.minY + ph * 0.22))
    for i in 0..<3 {
        let y = page.minY + ph * (0.62 + CGFloat(i) * 0.09)
        NSColor(white: 0.8, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: page.minX + pw * 0.15, y: y, width: pw * (i == 0 ? 0.45 : 0.6), height: ph * 0.035), xRadius: 2, yRadius: 2).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
extension NSShadow { func apply(_ f: (NSShadow) -> Void) { f(self); set() } }
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
