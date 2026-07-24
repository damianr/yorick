import AppKit

// Renders the DMG window background in the marketing site's palette
// (ink #16161a · bone #ece5d8 · amber #e0b458, mono eyebrow labels).
// Bone background deliberately: Finder draws icon labels in dark text when a
// background picture is set (not controllable), so the paper side of the brand
// is the readable side. Icon positions must match release.sh's AppleScript
// (app ≈ 180,190 · Applications ≈ 480,190). Output 660×400 pt @2x.
// Usage: gen-dmg-background <out.png>

let W: CGFloat = 660, H: CGFloat = 400
let img = NSImage(size: NSSize(width: W, height: H))
img.lockFocusFlipped(true)                       // top-left origin, matches Finder
let ctx = NSGraphicsContext.current!.cgContext

func hex(_ v: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: a)
}
let ink = hex(0x16161a), bone = hex(0xece5d8), boneFaint = hex(0x6d685e), amber = hex(0xe0b458)

// Bone paper with a whisper of vertical warmth.
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [hex(0xf1ebdf).cgColor, hex(0xe6ddcc).cgColor] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: .zero, end: CGPoint(x: 0, y: H), options: [])

// Amber arrow, app → Applications.
ctx.setStrokeColor(amber.cgColor)
ctx.setLineWidth(2.5)
ctx.setLineCap(.round)
let ay: CGFloat = 188
ctx.move(to: CGPoint(x: 268, y: ay)); ctx.addLine(to: CGPoint(x: 392, y: ay)); ctx.strokePath()
ctx.move(to: CGPoint(x: 380, y: ay - 8)); ctx.addLine(to: CGPoint(x: 394, y: ay)); ctx.addLine(to: CGPoint(x: 380, y: ay + 8)); ctx.strokePath()

func draw(_ text: String, font: NSFont, color: NSColor, y: CGFloat, kern: CGFloat = 0) {
    let p = NSMutableParagraphStyle(); p.alignment = .center
    NSAttributedString(string: text, attributes: [
        .font: font, .foregroundColor: color, .paragraphStyle: p, .kern: kern,
    ]).draw(in: CGRect(x: 0, y: y, width: W, height: font.pointSize * 1.7))
}

// Wordmark with the amber period (site h1 style).
let wordmark = NSMutableParagraphStyle(); wordmark.alignment = .center
let title = NSMutableAttributedString(
    string: "Yorick.",
    attributes: [.font: NSFont.systemFont(ofSize: 30, weight: .heavy),
                 .foregroundColor: ink, .paragraphStyle: wordmark, .kern: -0.6])
title.addAttribute(.foregroundColor, value: amber, range: NSRange(location: 6, length: 1))
title.draw(in: CGRect(x: 0, y: 48, width: W, height: 46))

draw("Drag into Applications", font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
     color: boneFaint, y: 322, kern: 0.5)

img.unlockFocus()

// Emit exactly 1320×800 px tagged @2x so Finder shows it at 660×400 pt.
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * 2), pixelsHigh: Int(H * 2),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
img.draw(in: NSRect(x: 0, y: 0, width: W, height: H))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("wrote \(CommandLine.arguments[1]) (\(Int(W * 2))x\(Int(H * 2)) @2x)")
