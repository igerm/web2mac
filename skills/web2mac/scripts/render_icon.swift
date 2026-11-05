// Renders a 1024x1024 app icon PNG: a macOS-style squircle plate with a vertical
// gradient and an emoji, initials or an image on top.
//
//   render_icon --out icon.png --top '#2E323C' --bottom '#15181E' --emoji 🎨
//   render_icon --out icon.png --top ... --bottom ... --text PC [--fg '#FFFFFF']
//   render_icon --out icon.png --image logo.png [--top ... --bottom ...]
//   render_icon --out icon.png --image icon.png --raw     # use as-is, no plate
//
// Drawn with AppKit at exactly 1024 px (a bitmap rep, not lockFocus, which would
// double the size on a Retina display).

import AppKit

var opts: [String: String] = [:]
var flags = Set<String>()
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    guard a.hasPrefix("--") else { continue }
    let key = String(a.dropFirst(2))
    if key == "raw" { flags.insert(key); continue }
    if !args.isEmpty { opts[key] = args.removeFirst() }
}

guard let out = opts["out"] else {
    FileHandle.standardError.write(Data("usage: render_icon --out FILE [...]\n".utf8))
    exit(2)
}

func color(_ hex: String?, _ fallback: NSColor) -> NSColor {
    guard var h = hex else { return fallback }
    if h.hasPrefix("#") { h.removeFirst() }
    guard h.count == 6, let v = UInt32(h, radix: 16) else { return fallback }
    return NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255,
                   green: CGFloat((v >> 8) & 255) / 255,
                   blue: CGFloat(v & 255) / 255, alpha: 1)
}

let size = 1024
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0), let ctx = NSGraphicsContext(bitmapImageRep: rep)
else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
ctx.imageInterpolation = .high
let canvas = CGFloat(size)

if flags.contains("raw"), let path = opts["image"], let img = NSImage(contentsOfFile: path) {
    img.draw(in: NSRect(x: 0, y: 0, width: canvas, height: canvas))
} else {
    // Superellipse (n = 5) is macOS's rounded-rect look; the plate is inset so the
    // icon matches the visual size of other Dock icons.
    let n = 5.0
    let half = canvas / 2
    let radius = half - canvas * 0.086
    let plate = NSBezierPath()
    let steps = 720
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = half + radius * CGFloat(c.sign == .minus ? -1 : 1) * CGFloat(pow(abs(c), 2 / n))
        let y = half + radius * CGFloat(s.sign == .minus ? -1 : 1) * CGFloat(pow(abs(s), 2 / n))
        if i == 0 { plate.move(to: NSPoint(x: x, y: y)) } else { plate.line(to: NSPoint(x: x, y: y)) }
    }
    plate.close()

    let top = color(opts["top"], NSColor(srgbRed: 0.18, green: 0.20, blue: 0.24, alpha: 1))
    let bottom = color(opts["bottom"], NSColor(srgbRed: 0.08, green: 0.09, blue: 0.12, alpha: 1))

    // Soft drop shadow under the plate, like the system icons.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = canvas * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -canvas * 0.012)
    shadow.set()
    bottom.setFill()
    plate.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    plate.addClip()
    NSGradient(starting: top, ending: bottom)?.draw(in: plate.bounds, angle: -90)

    let inner = radius * 2 * 0.62  // art box, centered on the plate
    let box = NSRect(x: half - inner / 2, y: half - inner / 2, width: inner, height: inner)

    if let path = opts["image"], let img = NSImage(contentsOfFile: path) {
        let ratio = min(box.width / img.size.width, box.height / img.size.height)
        let w = img.size.width * ratio, h = img.size.height * ratio
        img.draw(in: NSRect(x: half - w / 2, y: half - h / 2, width: w, height: h))
    } else {
        let glyph = opts["emoji"] ?? opts["text"] ?? "?"
        let isEmoji = opts["emoji"] != nil
        let count = max(1, glyph.count)
        let fontSize: CGFloat = isEmoji ? inner * 0.92
            : (count == 1 ? 520 : count == 2 ? 420 : 300)
        var font = NSFont.systemFont(ofSize: fontSize, weight: isEmoji ? .regular : .heavy)
        if !isEmoji, let rounded = font.fontDescriptor.withDesign(.rounded),
           let f = NSFont(descriptor: rounded, size: fontSize) { font = f }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color(opts["fg"], .white),
        ]
        let text = NSAttributedString(string: glyph, attributes: attrs)
        let bounds = text.size()
        text.draw(at: NSPoint(x: half - bounds.width / 2, y: half - bounds.height / 2))
    }
    NSGraphicsContext.restoreGraphicsState()
}

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
do { try png.write(to: URL(fileURLWithPath: out)) } catch {
    FileHandle.standardError.write(Data("cannot write \(out): \(error)\n".utf8))
    exit(1)
}
