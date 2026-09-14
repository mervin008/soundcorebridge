import SwiftUI
import AppKit

// MARK: - Spline helpers

/// Catmull-Rom through the given points, emitted as cubic Béziers. Used by the
/// EQ curve view.
func smoothSplinePath(points: [CGPoint]) -> Path {
    var path = Path()
    guard points.count > 1 else { return path }
    path.move(to: points[0])
    appendSpline(&path, points)
    return path
}

/// The same curve, closed down to `baselineY` so it can be filled.
func smoothSplineAreaPath(points: [CGPoint], baselineY: CGFloat) -> Path {
    var path = Path()
    guard let first = points.first, let last = points.last else { return path }
    path.move(to: CGPoint(x: first.x, y: baselineY))
    path.addLine(to: first)
    appendSpline(&path, points)
    path.addLine(to: CGPoint(x: last.x, y: baselineY))
    path.closeSubpath()
    return path
}

private func appendSpline(_ path: inout Path, _ pts: [CGPoint]) {
    for i in 0..<(pts.count - 1) {
        let p0 = i > 0 ? pts[i - 1] : CGPoint(x: 2 * pts[0].x - pts[1].x, y: 2 * pts[0].y - pts[1].y)
        let p1 = pts[i], p2 = pts[i + 1]
        let p3 = (i + 2 < pts.count) ? pts[i + 2] : CGPoint(x: 2 * p2.x - p1.x, y: 2 * p2.y - p1.y)
        let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
        let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
        path.addCurve(to: p2, control1: c1, control2: c2)
    }
}

/// The UI is tinted by the active listening mode, so the popover tells you what
/// the headset is doing at a glance.
///
/// Each tint is appearance-aware: a single fixed colour is either washed out on
/// a light background or muddy on a dark one. "Off" especially — a mid grey was
/// nearly invisible in both.
func modeTint(_ mode: UInt8?, connected: Bool) -> Color {
    guard connected else {
        return adaptive(light: NSColor(white: 0.42, alpha: 1), dark: NSColor(white: 0.62, alpha: 1))
    }
    switch mode {
    case 0x00:  // noise cancelling
        return adaptive(light: NSColor(srgbRed: 0.09, green: 0.42, blue: 0.94, alpha: 1),
                        dark:  NSColor(srgbRed: 0.36, green: 0.65, blue: 1.00, alpha: 1))
    case 0x01:  // ambient
        return adaptive(light: NSColor(srgbRed: 0.00, green: 0.55, blue: 0.42, alpha: 1),
                        dark:  NSColor(srgbRed: 0.20, green: 0.87, blue: 0.68, alpha: 1))
    case 0x02:  // off
        return adaptive(light: NSColor(srgbRed: 0.30, green: 0.33, blue: 0.40, alpha: 1),
                        dark:  NSColor(srgbRed: 0.80, green: 0.83, blue: 0.89, alpha: 1))
    default:
        return adaptive(light: NSColor(white: 0.40, alpha: 1), dark: NSColor(white: 0.70, alpha: 1))
    }
}

private func adaptive(light: NSColor, dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    })
}
