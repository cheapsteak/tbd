import AppKit
import CoreGraphics
import CoreText

// MARK: - Worktree Detection

/// Returns the worktree name (without date prefix) if running from a worktree build, nil for main.
func detectWorktreeName() -> String? {
    let path = ProcessInfo.processInfo.arguments[0]
    guard let range = path.range(of: ".tbd/worktrees/") else { return nil }
    let afterPrefix = path[range.upperBound...]
    guard let slashIndex = afterPrefix.firstIndex(of: "/") else { return nil }
    let name = String(afterPrefix[afterPrefix.startIndex..<slashIndex])
    // Strip YYYYMMDD- date prefix: "20260323-familiar-sawfish" → "familiar-sawfish"
    if let dashIndex = name.firstIndex(of: "-"),
       name[name.startIndex..<dashIndex].allSatisfy(\.isNumber) {
        let afterDash = name[name.index(after: dashIndex)...]
        if !afterDash.isEmpty { return String(afterDash) }
    }
    return name
}

// MARK: - Icon Generation

func generateAppIcon(worktreeName: String?) -> NSImage {
    let sizes: [CGFloat] = [16, 32, 128, 256, 512]
    let icon = NSImage(size: NSSize(width: 512, height: 512))
    for size in sizes {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size),
            pixelsHigh: Int(size),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { continue }
        rep.size = NSSize(width: size, height: size)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        drawIcon(size: size, worktreeName: worktreeName)
        NSGraphicsContext.restoreGraphicsState()
        icon.addRepresentation(rep)
    }
    return icon
}

// MARK: - Core Drawing

private func drawIcon(size: CGFloat, worktreeName: String?) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    let bounds = CGRect(origin: .zero, size: CGSize(width: size, height: size))
    ctx.clear(bounds)

    drawBackground(ctx: ctx, size: size)
    drawTBDText(ctx: ctx, size: size)

    if let name = worktreeName {
        drawWorktreeRibbon(ctx: ctx, size: size, name: name)
    }
}

// MARK: - Background

private func drawBackground(ctx: CGContext, size: CGFloat) {
    let inset = size * 0.02
    let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let squirclePath = CGPath(roundedRect: rect, cornerWidth: size * 0.2237, cornerHeight: size * 0.2237, transform: nil)

    let cs = CGColorSpaceCreateDeviceRGB()

    // Three-panel background with curved boundaries.
    // Each panel represents a parallel worktree.
    let panelColors: [(top: [CGFloat], bottom: [CGFloat])] = [
        (top: [0.10, 0.08, 0.30], bottom: [0.14, 0.11, 0.35]),   // deep indigo
        (top: [0.30, 0.15, 0.50], bottom: [0.38, 0.20, 0.55]),   // rich purple
        (top: [0.55, 0.20, 0.48], bottom: [0.62, 0.28, 0.52]),   // magenta
    ]

    // Boundary 1: bold arc from (0.25, bottom) to (0.40, top)
    // Boundary 2: S-curve from (0.55, bottom) to (0.72, top)

    for i in 0..<3 {
        ctx.saveGState()
        ctx.addPath(squirclePath)
        ctx.clip()

        let panel = CGMutablePath()

        // Left boundary (bottom to top)
        if i == 0 {
            panel.move(to: CGPoint(x: -size * 0.2, y: -size * 0.2))
            panel.addLine(to: CGPoint(x: -size * 0.2, y: size * 1.2))
        } else if i == 1 {
            // Boundary 1: bold single arc
            panel.move(to: CGPoint(x: size * 0.25, y: -size * 0.2))
            panel.addLine(to: CGPoint(x: size * 0.25, y: 0))
            panel.addCurve(
                to: CGPoint(x: size * 0.40, y: size),
                control1: CGPoint(x: size * 0.45, y: size * 0.25),
                control2: CGPoint(x: size * 0.22, y: size * 0.65)
            )
            panel.addLine(to: CGPoint(x: size * 0.40, y: size * 1.2))
        } else {
            // Boundary 2: S-curve
            panel.move(to: CGPoint(x: size * 0.55, y: -size * 0.2))
            panel.addLine(to: CGPoint(x: size * 0.55, y: 0))
            panel.addCurve(
                to: CGPoint(x: size * 0.72, y: size),
                control1: CGPoint(x: size * 0.48, y: size * 0.35),
                control2: CGPoint(x: size * 0.80, y: size * 0.60)
            )
            panel.addLine(to: CGPoint(x: size * 0.72, y: size * 1.2))
        }

        // Right boundary (top to bottom)
        if i == 2 {
            panel.addLine(to: CGPoint(x: size * 1.2, y: size * 1.2))
            panel.addLine(to: CGPoint(x: size * 1.2, y: -size * 0.2))
        } else if i == 0 {
            // Boundary 1 reversed
            panel.addLine(to: CGPoint(x: size * 0.40, y: size * 1.2))
            panel.addLine(to: CGPoint(x: size * 0.40, y: size))
            panel.addCurve(
                to: CGPoint(x: size * 0.25, y: 0),
                control1: CGPoint(x: size * 0.22, y: size * 0.65),
                control2: CGPoint(x: size * 0.45, y: size * 0.25)
            )
            panel.addLine(to: CGPoint(x: size * 0.25, y: -size * 0.2))
        } else {
            // Boundary 2 reversed
            panel.addLine(to: CGPoint(x: size * 0.72, y: size * 1.2))
            panel.addLine(to: CGPoint(x: size * 0.72, y: size))
            panel.addCurve(
                to: CGPoint(x: size * 0.55, y: 0),
                control1: CGPoint(x: size * 0.80, y: size * 0.60),
                control2: CGPoint(x: size * 0.48, y: size * 0.35)
            )
            panel.addLine(to: CGPoint(x: size * 0.55, y: -size * 0.2))
        }

        panel.closeSubpath()
        ctx.addPath(panel)
        ctx.clip()

        let c = panelColors[i]
        let colors: [CGColor] = [
            CGColor(red: c.bottom[0], green: c.bottom[1], blue: c.bottom[2], alpha: 1.0),
            CGColor(red: c.top[0], green: c.top[1], blue: c.top[2], alpha: 1.0),
        ]
        if let g = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: [0.0, 1.0]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: size),
                                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }

        ctx.restoreGState()
    }
}

// MARK: - TBD Text

private func drawTBDText(ctx: CGContext, size: CGFloat) {
    ctx.saveGState()

    let fontSize = size * 0.46
    let font = NSFont.systemFont(ofSize: fontSize, weight: .black) as CTFont

    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
        .kern: fontSize * -0.015,
    ]
    let str = NSAttributedString(string: "TBD", attributes: attrs)
    let line = CTLineCreateWithAttributedString(str)
    let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)

    let x = (size - bounds.width) / 2 - bounds.origin.x
    let y = (size - bounds.height) / 2 - bounds.origin.y

    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.010),
                   blur: size * 0.025,
                   color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45))

    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, ctx)

    ctx.restoreGState()
}

// MARK: - Worktree Ribbon

private func drawWorktreeRibbon(ctx: CGContext, size: CGFloat, name: String) {
    ctx.saveGState()

    let ribbonColor = colorForWorktreeName(name)
    let ribbonWidth = size * 0.20

    // Translate to center of bottom-right corner area, then rotate 45°.
    // The squircle clip path (set in drawBackground) trims the edges.
    let cx = size * 0.75
    let cy = size * 0.25
    ctx.translateBy(x: cx, y: cy)
    ctx.rotate(by: .pi / 4)

    let bandLength = size * 0.8
    let ribbonRect = CGRect(
        x: -bandLength / 2,
        y: -ribbonWidth / 2,
        width: bandLength,
        height: ribbonWidth
    )
    ctx.setFillColor(ribbonColor)
    ctx.fill(ribbonRect)

    // Ribbon text — drawn in the rotated frame, centered at origin
    let abbreviatedName = abbreviateWorktreeName(name)
    let ribbonFontSize = size * 0.065
    let ribbonFont = NSFont.systemFont(ofSize: ribbonFontSize, weight: .semibold) as CTFont

    let textAttrs: [NSAttributedString.Key: Any] = [
        .font: ribbonFont,
        .foregroundColor: NSColor.white,
    ]
    let textString = NSAttributedString(string: abbreviatedName, attributes: textAttrs)
    let textLine = CTLineCreateWithAttributedString(textString)
    let textBounds = CTLineGetBoundsWithOptions(textLine, .useOpticalBounds)

    let textX = -textBounds.width / 2 - textBounds.origin.x
    let textY = -textBounds.height / 2 - textBounds.origin.y

    ctx.textPosition = CGPoint(x: textX, y: textY)
    CTLineDraw(textLine, ctx)

    ctx.restoreGState()
}

// MARK: - Helpers

private func colorForWorktreeName(_ name: String) -> CGColor {
    var hash: UInt64 = 5381
    for byte in name.utf8 {
        hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
    }
    let hue = CGFloat(hash % 360) / 360.0
    return NSColor(hue: hue, saturation: 0.75, brightness: 0.85, alpha: 1.0).cgColor
}

private func abbreviateWorktreeName(_ name: String) -> String {
    let parts = name.split(separator: "-")
    guard parts.count >= 2 else {
        return String(name.prefix(12))
    }
    let first = parts[0]
    let second = String(parts[1].prefix(4))
    let result = "\(first)-\(second)"
    return result.count > 16 ? String(result.prefix(16)) : result
}
