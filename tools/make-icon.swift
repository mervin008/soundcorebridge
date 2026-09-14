import AppKit

// SoundcoreBridge mark: the headband *is* the bridge — an arc spanning two
// pillars (the ear cups), with the EQ curve running underneath it.
// Rendered from code so the icon is reproducible and reviewable in diffs.

let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a)
}

let accent = color(74, 158, 255)

// Rounded-square body, inset like a standard macOS icon.
let inset: CGFloat = 96
let body = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let squircle = NSBezierPath(roundedRect: body, xRadius: 196, yRadius: 196)
NSGradient(colors: [color(32, 40, 56), color(12, 16, 24)])!
    .draw(in: squircle, angle: -90)

// Faint inner rim so the shape reads on a light desktop.
squircle.lineWidth = 3
color(255, 255, 255, 0.10).setStroke()
squircle.stroke()

let cx = size / 2
let cupW: CGFloat = 132, cupH: CGFloat = 236
let cupY: CGFloat = 286      // optically centred, not mathematically
let span: CGFloat = 214          // centre of each cup from the middle

// Headband: a thick arc from cup to cup.
let band = NSBezierPath()
band.move(to: NSPoint(x: cx - span, y: cupY + cupH * 0.62))
band.curve(to: NSPoint(x: cx + span, y: cupY + cupH * 0.62),
           controlPoint1: NSPoint(x: cx - span, y: cupY + cupH + 250),
           controlPoint2: NSPoint(x: cx + span, y: cupY + cupH + 250))
band.lineWidth = 58
band.lineCapStyle = .round
NSColor.white.setStroke()
band.stroke()

// Ear cups / bridge pillars.
for dx in [-span, span] {
    let cup = NSBezierPath(roundedRect: NSRect(x: cx + dx - cupW / 2, y: cupY,
                                               width: cupW, height: cupH),
                           xRadius: 58, yRadius: 58)
    NSColor.white.setFill()
    cup.fill()
}

// EQ curve, sitting in the opening between the cups — the signal passing
// under the bridge. Smoothed through its points rather than drawn as a zigzag.
let innerHalf = span - cupW / 2 - 6
let midY = cupY + cupH * 0.44
let samples: [CGFloat] = [-0.30, 0.55, -0.15, 0.85, 0.10, -0.45]
var pts: [NSPoint] = []
for (i, v) in samples.enumerated() {
    let t = CGFloat(i) / CGFloat(samples.count - 1)
    pts.append(NSPoint(x: cx - innerHalf + t * innerHalf * 2, y: midY + v * 78))
}

let curve = NSBezierPath()
curve.move(to: pts[0])
for i in 0..<(pts.count - 1) {
    let p0 = i > 0 ? pts[i - 1] : pts[0]
    let p1 = pts[i], p2 = pts[i + 1]
    let p3 = (i + 2 < pts.count) ? pts[i + 2] : p2
    let c1 = NSPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
    let c2 = NSPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
    curve.curve(to: p2, controlPoint1: c1, controlPoint2: c2)
}
curve.lineWidth = 32
curve.lineCapStyle = .round
curve.lineJoinStyle = .round
accent.setStroke()
curve.stroke()

NSGraphicsContext.restoreGraphicsState()

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
