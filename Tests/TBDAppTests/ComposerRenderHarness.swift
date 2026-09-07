import AppKit
import Foundation
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared

/// Env-gated **render** harness for the transcript composer: one PNG per state
/// it can be in, at 2x, for a person to look at.
///
/// Its subject is the half of a UI that assertions are bad at. Every other
/// composer suite asks a question with a right answer — does the list open
/// upward, is the send button reachable — and none of them can tell you that the
/// blocked banner's icon collides with its message, or that the attachment
/// thumbnail sits a hair below the text baseline. A render can, and the last one
/// of these caught exactly that class of defect (#829, the completion list
/// covering the words being typed) before it shipped.
///
/// Inert during a normal run: every test early-returns unless
/// `TBD_COMPOSER_SHOTS_DIR` names a directory to write into.
///
///     TBD_COMPOSER_SHOTS_DIR=/tmp/composer-shots scripts/test.sh \
///         --filter ComposerRenderHarness
///
/// **Each shot asserts it is not blank.** A view that was never laid out renders
/// as a large, perfectly plausible white rectangle, and a harness that wrote one
/// out would report success and hand over a picture of nothing. The luminance
/// variance of the capture has to clear `minLuminanceVariance` before the file
/// is written, so a broken render fails instead.
@MainActor
@Suite("composer render harness")
struct ComposerRenderHarness {

    /// The four states, as their file names. Numbered so a directory listing
    /// reads in the order somebody would want to look at them.
    private enum Shot: String {
        case menu = "1-menu"
        case attachment = "2-attachment"
        case notRunning = "3-not-running"
        case blocked = "4-blocked"
    }

    /// Where the PNGs go, or `nil` when the harness is inert.
    private static var outputDirectory: URL? {
        let path = ProcessInfo.processInfo.environment["TBD_COMPOSER_SHOTS_DIR"] ?? ""
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Pixels per point. 2x because these are read on a Retina display and a 1x
    /// capture of 9pt caption text is unreadable.
    private static let captureScale: CGFloat = 2

    /// Far below anything a real render produces, far above the zero a flat
    /// field scores. See `OffscreenHost.Capture.luminanceVariance()`.
    private static let minLuminanceVariance = 0.0005

    /// Pumps spent after the state under test has settled, so the asynchronous
    /// parts of a composer — a thumbnail decoding off the main thread, the
    /// strip's own layout pass — have arrived before the shutter.
    private static let extraDrawPumps = 40

    // MARK: - The four shots

    /// The completion list, open over the transcript, with a half-typed message
    /// under it — the state the placement suite measures and this one shows.
    @Test("the open completion menu (gated by TBD_COMPOSER_SHOTS_DIR)")
    func renderOpenMenu() async throws {
        guard let directory = Self.outputDirectory else { return }
        let harness = try ComposerHarness(
            name: "ComposerRenderHarness", backdrop: .transcriptPreview)
        defer { harness.tearDown() }

        let opened = await harness.openMenu(typing: "please /comp")
        try #require(opened, .init(rawValue: """
            the completion list never reached its full height. \(harness.diagnostics())
            """))

        try await Self.write(.menu, of: harness, into: directory)
    }

    /// A staged image: its thumbnail in the strip, and the `[Image #1]` token
    /// that anchors it in the message.
    @Test("a staged attachment (gated by TBD_COMPOSER_SHOTS_DIR)")
    func renderStagedAttachment() async throws {
        guard let directory = Self.outputDirectory else { return }
        let png = try Self.sampleImagePNG()
        let harness = try ComposerHarness(
            name: "ComposerRenderHarness", backdrop: .transcriptPreview,
            prepare: { setup in
                let number = try setup.stage(png: png)
                setup.draft.text = "What do you make of this? "
                setup.appendToken(number)
            })
        defer { harness.tearDown() }

        let ready = await harness.host.settle {
            harness.textView?.string.contains(ComposerTokens.text(for: 1)) ?? false
        }
        try #require(ready, .init(rawValue: """
            the staged image's token never reached the text view. \(harness.diagnostics())
            """))

        try await Self.write(.attachment, of: harness, into: directory)
    }

    /// A parked session: the note saying a send resumes it, and a send button
    /// that says so too.
    @Test("the not-running state (gated by TBD_COMPOSER_SHOTS_DIR)")
    func renderNotRunning() async throws {
        guard let directory = Self.outputDirectory else { return }
        let harness = try ComposerHarness(
            name: "ComposerRenderHarness",
            terminal: { ComposerHarness.parkedTerminal(worktreeID: $0, exited: true) },
            backdrop: .transcriptPreview,
            prepare: { $0.draft.text = "pick this back up where it stopped" })
        defer { harness.tearDown() }
        try await Self.settleField(harness)
        try await Self.write(.notRunning, of: harness, into: directory)
    }

    /// A session sitting on a dialog: the banner the daemon's message produced,
    /// the Reveal Terminal button beside it, and a disabled field.
    @Test("the blocked state (gated by TBD_COMPOSER_SHOTS_DIR)")
    func renderBlocked() async throws {
        guard let directory = Self.outputDirectory else { return }
        let harness = try ComposerHarness(
            name: "ComposerRenderHarness",
            terminal: {
                ComposerHarness.blockedTerminal(
                    worktreeID: $0,
                    message: "Claude needs permission to run `git push`. Answer in the "
                        + "terminal — the highlighted option is the one Enter commits.")
            },
            backdrop: .transcriptPreview)
        defer { harness.tearDown() }
        try await Self.settleField(harness)
        try await Self.write(.blocked, of: harness, into: directory)
    }

    // MARK: - Shared machinery

    /// Wait for the composer to have mounted at all — the text view is the last
    /// piece of it to arrive.
    private static func settleField(_ harness: ComposerHarness) async throws {
        let mounted = await harness.host.settle { harness.textView != nil }
        try #require(mounted, .init(rawValue: """
            the composer never mounted. \(harness.diagnostics())
            """))
    }

    /// Capture, check the capture is a picture of something, and write it.
    private static func write(
        _ shot: Shot, of harness: ComposerHarness, into directory: URL
    ) async throws {
        await harness.host.pump(times: extraDrawPumps)
        let capture = try harness.host.capture(scale: captureScale)
        let variance = capture.luminanceVariance()
        #expect(
            variance >= minLuminanceVariance,
            .init(rawValue: """
                \(shot.rawValue).png is a flat field (luminance variance \(variance)) — \
                the composer rendered blank rather than being captured
                """))
        try capture.writePNG(to: directory.appendingPathComponent("\(shot.rawValue).png"))
    }

    /// A small, deliberately recognisable PNG for the attachment thumbnail:
    /// coloured quarters, so a thumbnail that decoded is obvious in the render
    /// and a placeholder is obvious too. Drawn rather than committed as a
    /// fixture — it is four rectangles, and a binary in the repository would
    /// have to be justified.
    private static func sampleImagePNG() throws -> Data {
        let side = 128
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: rep)
        else { throw OffscreenHostError.couldNotMakeBitmap }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let half = CGFloat(side) / 2
        let quarters: [(NSRect, NSColor)] = [
            (NSRect(x: 0, y: 0, width: half, height: half), .systemTeal),
            (NSRect(x: half, y: 0, width: half, height: half), .systemIndigo),
            (NSRect(x: 0, y: half, width: half, height: half), .systemOrange),
            (NSRect(x: half, y: half, width: half, height: half), .systemPink),
        ]
        for (rect, color) in quarters {
            color.setFill()
            rect.fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw OffscreenHostError.couldNotEncodePNG
        }
        return data
    }
}
