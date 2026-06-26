import AppKit
import STTextView
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared

/// Env-gated, HEADLESS visual-comparison harness for issue #129.
///
/// For each content scenario it renders BOTH transcript paths — the OLD SwiftUI
/// `TranscriptItemsView` and the NEW TextKit2 `STTextView` document — to PNG
/// files at the SAME fixed width and writes them to `/tmp/transcript-compare/`,
/// plus an `INDEX.txt` enumerating every pair. The orchestrator opens the PNGs
/// to ground visual regressions, so the fidelity of the rendered image is the
/// whole point.
///
/// Inert during normal `swift test`: the test early-returns unless
/// `TBD_TRANSCRIPT_COMPARE=1`. Run explicitly:
///
///     TBD_TRANSCRIPT_COMPARE=1 swift test --filter TranscriptVisualCompareHarness
@Suite("Transcript visual compare harness (#129)")
@MainActor
struct TranscriptVisualCompareHarness {

    /// Fixed render width both paths use, matching the transcript content column.
    private static let width: CGFloat = 680
    /// Tall ceiling for the NEW-path window/text view so all content lays out.
    private static let tallHeight: CGFloat = 6_000
    private static let outputDir = "/tmp/transcript-compare"

    @Test("render old vs new transcript to PNG pairs (gated by TBD_TRANSCRIPT_COMPARE=1)")
    func renderComparison() throws {
        guard ProcessInfo.processInfo.environment["TBD_TRANSCRIPT_COMPARE"] == "1" else {
            #expect(true)
            return
        }

        let fm = FileManager.default
        try? fm.removeItem(atPath: Self.outputDir)
        try fm.createDirectory(atPath: Self.outputDir, withIntermediateDirectories: true)

        // Shared test AppState — isolated UserDefaults suite so we never touch
        // the developer's real TBDApp.plist (and no daemon socket task spawns
        // under tests).
        let suiteName = "transcript-compare-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        var indexLines: [String] = []
        indexLines.append("Transcript old-vs-new visual comparison")
        indexLines.append("render width: \(Int(Self.width)) pt")
        indexLines.append("generated: \(ISO8601DateFormatter().string(from: Date()))")
        indexLines.append("")

        // Synthetic fixture scenarios + any REAL on-disk session windows. Real
        // scenarios feed actual Claude JSONL content through the same two render
        // paths to hunt the reported "overlapping bubbles" defect that synthetic
        // fixtures did not reproduce. They are skipped silently when the files
        // aren't present on this machine.
        var scenarios: [(name: String, items: [TranscriptItem])] = TranscriptCompareFixtures.scenarioNames.map {
            ($0, TranscriptCompareFixtures.items(for: $0))
        }
        for real in TranscriptCompareRealSessions.scenarios() {
            let items = TranscriptCompareRealSessions.parseWindow(for: real)
            if items.isEmpty {
                indexLines.append("scenario: \(real.name) — SKIPPED (parsed 0 items from \(real.jsonlPath))")
                indexLines.append("")
                continue
            }
            scenarios.append((real.name, items))
        }

        for (scenario, items) in scenarios {
            let oldPath = "\(Self.outputDir)/\(scenario)__old.png"
            let newPath = "\(Self.outputDir)/\(scenario)__new.png"

            let oldHeight = try renderOldPath(items: items, appState: appState, to: oldPath)
            let newHeight = try renderNewPath(items: items, appState: appState, to: newPath)

            let oldSize = (try? fm.attributesOfItem(atPath: oldPath)[.size] as? Int) ?? 0
            let newSize = (try? fm.attributesOfItem(atPath: newPath)[.size] as? Int) ?? 0

            // A blank/degenerate render is the failure mode this harness exists
            // to avoid — assert non-trivial size for both paths.
            #expect(oldHeight > 1, "OLD \(scenario) measured height \(oldHeight)")
            #expect(newHeight > 1, "NEW \(scenario) measured height \(newHeight)")
            #expect(oldSize > 1000, "OLD \(scenario) PNG only \(oldSize) bytes")
            #expect(newSize > 1000, "NEW \(scenario) PNG only \(newSize) bytes")

            indexLines.append("scenario: \(scenario) (\(items.count) items)")
            indexLines.append("  old: \(oldPath)  (\(Int(Self.width))x\(Int(oldHeight)), \(oldSize) bytes)")
            indexLines.append("  new: \(newPath)  (\(Int(Self.width))x\(Int(newHeight)), \(newSize) bytes)")
            indexLines.append("")
        }

        indexLines.append("NOTE on the NEW (TextKit2) path:")
        indexLines.append("  The STTextView is added to an offscreen NSWindow before forcing layout,")
        indexLines.append("  because TextKit2 places NSTextAttachmentViewProvider subviews (the embedded")
        indexLines.append("  tool cards) only during viewport layout, which requires a hosting window.")
        indexLines.append("  If a `toolcards`/`mixed` NEW png shows gaps where cards should be, the")
        indexLines.append("  attachment views did not place in time — inspect those two scenarios first.")

        let index = indexLines.joined(separator: "\n") + "\n"
        try index.write(toFile: "\(Self.outputDir)/INDEX.txt", atomically: true, encoding: .utf8)

        #expect(true)
    }

    // MARK: - OLD (SwiftUI) path

    /// Hosts `TranscriptItemsView` in an `NSHostingView` at the fixed width, lays
    /// it out, and renders to a PNG. Returns the measured fitting height.
    private func renderOldPath(
        items: [TranscriptItem],
        appState: AppState,
        to path: String
    ) throws -> CGFloat {
        let root = TranscriptItemsView(items: items, terminalID: nil, atBottom: .constant(true))
            .environment(\.openTranscriptOverlay, { _ in })
            .environment(\.openFilePreview, { _ in })
            .environmentObject(appState)
            .frame(width: Self.width)

        let hostingView = NSHostingView(rootView: root)
        // Width is fixed; height starts tall so fitting height resolves the real
        // content extent.
        hostingView.frame = NSRect(x: 0, y: 0, width: Self.width, height: Self.tallHeight)
        hostingView.layoutSubtreeIfNeeded()
        let fittingHeight = max(hostingView.fittingSize.height, 1)
        hostingView.frame = NSRect(x: 0, y: 0, width: Self.width, height: fittingHeight)
        hostingView.layoutSubtreeIfNeeded()

        try renderView(hostingView, to: path)
        return fittingHeight
    }

    // MARK: - NEW (TextKit2) path

    /// Builds a `TranscriptDocument` + `ReadOnlySTTextView` configured exactly as
    /// the production representable, adds the scroll view to an offscreen
    /// `NSWindow` (required for attachment-view placement), forces layout, and
    /// renders the document view to a PNG. Returns the laid-out document height.
    private func renderNewPath(
        items: [TranscriptItem],
        appState: AppState,
        to path: String
    ) throws -> CGFloat {
        let context = TranscriptCardContext(
            terminalID: nil,
            openTranscriptOverlay: { _ in },
            appState: appState
        )
        let document = TranscriptDocument(context: context)

        // Mirror STTextViewTranscriptView.makeNSView exactly.
        let scrollView = ReadOnlySTTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? STTextView else {
            Issue.record("ReadOnlySTTextView.scrollableTextView() had no STTextView document view")
            return 0
        }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isHorizontallyResizable = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let nodes = transcriptRenderNodes(from: items)
        if let contentStorage = textView.textContentManager as? NSTextContentStorage {
            let textStorage: NSTextStorage
            if let existing = contentStorage.textStorage {
                textStorage = existing
            } else {
                let created = NSTextStorage()
                contentStorage.textStorage = created
                textStorage = created
            }
            document.bind(to: textStorage)
            document.rebuild(nodes)
        } else {
            document.rebuild(nodes)
            textView.attributedText = document.storage
        }

        // Offscreen window: TextKit2 places NSTextAttachmentViewProvider subviews
        // (the embedded tool cards) during viewport layout, which needs a window.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.tallHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        scrollView.frame = NSRect(x: 0, y: 0, width: Self.width, height: Self.tallHeight)

        // Force the text view tall enough to lay out all content (no clipping),
        // then drive TextKit2 layout to completion.
        textView.frame = NSRect(x: 0, y: 0, width: Self.width, height: Self.tallHeight)
        forceTextKitLayout(textView)

        // Pump the run loop so deferred attachment-view placement + hosting-view
        // sizing settle before we snapshot.
        pumpRunLoop()
        forceTextKitLayout(textView)
        pumpRunLoop()

        let docView = scrollView.documentView ?? textView
        let docHeight = max(docView.frame.height, 1)
        // Snapshot the document view (the laid-out text + cards), not the clipped
        // scroll viewport, so the PNG shows the full transcript.
        try renderView(docView, to: path)
        return docHeight
    }

    /// Drives TextKit2 to lay out the entire document (not just the visible
    /// viewport) so the rendered extent and all attachment views are realized.
    private func forceTextKitLayout(_ textView: STTextView) {
        textView.layoutSubtreeIfNeeded()
        let layoutManager = textView.textLayoutManager
        let documentRange = layoutManager.documentRange
        layoutManager.ensureLayout(for: documentRange)
        // Walk every fragment with `.ensuresLayout` so the whole document — and
        // each attachment-view provider — is realized, not just the viewport.
        layoutManager.enumerateTextLayoutFragments(
            from: documentRange.location,
            options: [.ensuresLayout]
        ) { _ in true }
        textView.layoutSubtreeIfNeeded()
    }

    /// Spins the current run loop briefly so DispatchQueue.main.async work
    /// (attachment placement, hosting-view sizing) drains before snapshot.
    private func pumpRunLoop() {
        for _ in 0..<5 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    // MARK: - Shared rendering

    /// Renders an `NSView` (already laid out at its final frame) to a PNG file
    /// via `bitmapImageRepForCachingDisplay` + `cacheDisplay`.
    private func renderView(_ view: NSView, to path: String) throws {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw HarnessError.couldNotMakeBitmap
        }
        // White backing so transparent regions render as a readable page, not
        // black (cacheDisplay does not clear the rep).
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)

        let composited = NSImage(size: bounds.size)
        composited.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: bounds.size)).fill()
        rep.draw(in: NSRect(origin: .zero, size: bounds.size))
        composited.unlockFocus()

        guard let tiff = composited.tiffRepresentation,
              let merged = NSBitmapImageRep(data: tiff),
              let png = merged.representation(using: .png, properties: [:]) else {
            throw HarnessError.couldNotMakePNG
        }
        try png.write(to: URL(fileURLWithPath: path))
    }

    enum HarnessError: Error {
        case couldNotMakeBitmap
        case couldNotMakePNG
    }
}
