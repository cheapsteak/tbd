import AppKit
import Foundation
import TBDAppIcon

// IconBaker — renders the default TBD app icon (no worktree ribbon) and writes
// a multi-representation .icns file to the path passed as argv[1].
//
// Usage:
//   swift run IconBaker <output-path>
//
// Re-bake after changing Sources/TBDAppIcon/AppIcon.swift, then commit the
// updated Resources/AppIcon.icns. The on-disk icns is what macOS reads for
// notification banners, System Settings → Notifications, and Finder; the
// runtime NSApp.applicationIconImage path still draws the per-worktree
// ribbon variant for the Dock + app switcher.

struct BakerError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { self.description = message }
}

// .icns expects PNGs at these (logical size, scale) pairs.
let iconsetSpec: [(name: String, pixelSize: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

func renderPNG(pixelSize: Int) throws -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw BakerError("Failed to create bitmap rep for \(pixelSize)x\(pixelSize)")
    }
    rep.size = NSSize(width: pixelSize, height: pixelSize)

    // Render the icon at this exact pixel size by piggybacking on a fresh
    // NSImage scoped to one rep. We can't just iterate generateAppIcon()'s
    // existing reps because it tops out at 512×512 — we need 1024 for @2x of
    // the 512 slot — and its 16/32/128/256 reps don't include the 64 we need
    // for 32×32@2x. Re-rendering at each requested pixel size guarantees a
    // crisp glyph at every level instead of upscaling.
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // generateAppIcon adds five reps (16/32/128/256/512). Draw the one whose
    // size matches our target into the current context. For pixelSize=64 or
    // 1024 we fall back to drawing the 512 rep scaled — but generateAppIcon
    // itself only goes up to 512, so for 1024 we use NSImage's high-quality
    // scaling. For 64 we draw the 128 rep scaled down.
    let icon = generateAppIcon(worktreeName: nil)
    let target = NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
    NSGraphicsContext.current?.imageInterpolation = .high
    icon.draw(in: target, from: .zero, operation: .copy, fraction: 1.0)

    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        throw BakerError("Failed to encode PNG for \(pixelSize)x\(pixelSize)")
    }
    return pngData
}

func bake(outputPath: String) throws {
    let fm = FileManager.default
    let tmpDir = fm.temporaryDirectory.appendingPathComponent("tbd-iconbaker-\(UUID().uuidString)")
    let iconsetDir = tmpDir.appendingPathComponent("AppIcon.iconset")
    try fm.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpDir) }

    for spec in iconsetSpec {
        let data = try renderPNG(pixelSize: spec.pixelSize)
        let fileURL = iconsetDir.appendingPathComponent(spec.name)
        try data.write(to: fileURL)
    }

    let outputURL = URL(fileURLWithPath: outputPath)
    try? fm.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if fm.fileExists(atPath: outputURL.path) {
        try fm.removeItem(at: outputURL)
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", iconsetDir.path, "-o", outputURL.path]
    let stderrPipe = Pipe()
    process.standardError = stderrPipe
    try process.run()
    process.waitUntilExit()

    if process.terminationStatus != 0 {
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let errStr = String(data: errData, encoding: .utf8) ?? "<no stderr>"
        throw BakerError("iconutil failed (\(process.terminationStatus)): \(errStr)")
    }

    let attrs = try fm.attributesOfItem(atPath: outputURL.path)
    let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
    FileHandle.standardOutput.write(Data("Wrote \(outputURL.path) (\(size) bytes)\n".utf8))
}

let args = CommandLine.arguments
guard args.count == 2 else {
    let msg = "Usage: IconBaker <output-icns-path>\n"
    FileHandle.standardError.write(Data(msg.utf8))
    exit(2)
}

do {
    try bake(outputPath: args[1])
} catch {
    let msg = "IconBaker error: \(error)\n"
    FileHandle.standardError.write(Data(msg.utf8))
    exit(1)
}
