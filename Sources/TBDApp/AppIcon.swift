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

    drawSquircleBackground(ctx: ctx, size: size)
    drawBranchLines(ctx: ctx, size: size)
    drawTBDText(ctx: ctx, size: size)

    if let name = worktreeName {
        drawWorktreeRibbon(ctx: ctx, size: size, name: name)
    }
}

// MARK: - Background

private func drawSquircleBackground(ctx: CGContext, size: CGFloat) {
    let inset = size * 0.02
    let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let cornerRadius = size * 0.2237

    let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.addPath(path)
    ctx.clip()

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let colors: [CGColor] = [
        CGColor(red: 0.09, green: 0.11, blue: 0.27, alpha: 1.0),  // deep navy
        CGColor(red: 0.29, green: 0.15, blue: 0.50, alpha: 1.0),  // mid purple
        CGColor(red: 0.44, green: 0.22, blue: 0.65, alpha: 1.0),  // rich purple
    ]
    let locations: [CGFloat] = [0.0, 0.55, 1.0]

    if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: size / 2, y: 0),
            end: CGPoint(x: size / 2, y: size),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }
}

// MARK: - Decorative Branch Lines

private func drawBranchLines(ctx: CGContext, size: CGFloat) {
    ctx.saveGState()
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.08))
    ctx.setLineWidth(size * 0.006)
    ctx.setLineCap(.round)

    // Main trunk
    let trunkX = size * 0.38
    ctx.move(to: CGPoint(x: trunkX, y: size * 0.15))
    ctx.addLine(to: CGPoint(x: trunkX, y: size * 0.85))
    ctx.strokePath()

    // Branch 1: curves right
    let b1Start = CGPoint(x: trunkX, y: size * 0.35)
    let b1End = CGPoint(x: size * 0.65, y: size * 0.50)
    let b1Cp = CGPoint(x: trunkX + size * 0.05, y: size * 0.42)
    ctx.move(to: b1Start)
    ctx.addQuadCurve(to: b1End, control: b1Cp)
    ctx.strokePath()

    // Branch 2: curves right
    let b2Start = CGPoint(x: trunkX, y: size * 0.60)
    let b2End = CGPoint(x: size * 0.58, y: size * 0.75)
    let b2Cp = CGPoint(x: trunkX + size * 0.04, y: size * 0.67)
    ctx.move(to: b2Start)
    ctx.addQuadCurve(to: b2End, control: b2Cp)
    ctx.strokePath()

    // Commit dots
    let dotRadius = size * 0.012
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.12))
    for point in [b1Start, b1End, b2Start, b2End] {
        ctx.fillEllipse(in: CGRect(
            x: point.x - dotRadius, y: point.y - dotRadius,
            width: dotRadius * 2, height: dotRadius * 2
        ))
    }

    ctx.restoreGState()
}

// MARK: - TBD Text

private func drawTBDText(ctx: CGContext, size: CGFloat) {
    ctx.saveGState()

    let fontSize = size * 0.28
    let font = NSFont.systemFont(ofSize: fontSize, weight: .bold) as CTFont

    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
    ]
    let attrString = NSAttributedString(string: "TBD", attributes: attributes)
    let line = CTLineCreateWithAttributedString(attrString)
    let textBounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)

    let x = (size - textBounds.width) / 2 - textBounds.origin.x
    let y = (size - textBounds.height) / 2 - textBounds.origin.y - size * 0.02

    ctx.setShadow(
        offset: CGSize(width: 0, height: -size * 0.008),
        blur: size * 0.02,
        color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.4)
    )

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
    // The squircle clip path (set in drawSquircleBackground) trims the edges.
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
