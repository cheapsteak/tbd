import AppKit
import STTextView
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared

/// Env-gated, HEADLESS *scrolling* visual harness for issue #129.
///
/// The sister harness (`TranscriptVisualCompareHarness`) renders the WHOLE
/// document in ONE static offscreen layout pass at a tall (6000pt) frame and
/// never scrolls. That static pass hides two real LIVE bugs:
///
///   1. severe scroll LAG on long transcripts (the bubble overlay enumerates
///      the whole document and computes a `boundingRect` for every message on
///      every draw/scroll frame), and
///   2. chat-bubble OVERLAP mid-scroll (bubble rects computed from
///      not-yet-laid-out / transitional viewport ranges land in the wrong place).
///
/// This harness reproduces those by hosting the NEW `ReadOnlySTTextView` inside
/// a REAL scrollable `NSScrollView` at a FIXED viewport (680x600) in an
/// offscreen window, then scrolling the clip view to several offsets (top,
/// ~1/3, ~2/3, bottom), forcing viewport layout at each, and snapshotting the
/// VISIBLE viewport to
/// `/tmp/transcript-compare/scroll-<scenario>-<offset>__new.png`.
///
/// Inert during normal `swift test`: early-returns unless
/// `TBD_TRANSCRIPT_COMPARE=1`. Run explicitly:
///
///     TBD_TRANSCRIPT_COMPARE=1 swift test --filter TranscriptScrollCompareHarness
@Suite("Transcript scroll compare harness (#129)")
@MainActor
struct TranscriptScrollCompareHarness {

    /// Fixed render width, matching the transcript content column / sister harness.
    private static let width: CGFloat = 680
    /// Fixed viewport height — small enough that long transcripts must scroll.
    private static let viewportHeight: CGFloat = 600
    private static let outputDir = "/tmp/transcript-compare"

    @Test("scroll NEW transcript through offsets to PNG (gated by TBD_TRANSCRIPT_COMPARE=1)")
    func renderScrollComparison() throws {
        guard ProcessInfo.processInfo.environment["TBD_TRANSCRIPT_COMPARE"] == "1" else {
            #expect(true)
            return
        }

        let fm = FileManager.default
        // Do NOT wipe the dir — the sister harness may have populated it; just
        // ensure it exists and append scroll-* artifacts alongside.
        try fm.createDirectory(atPath: Self.outputDir, withIntermediateDirectories: true)

        let suiteName = "transcript-scroll-compare-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        var indexLines: [String] = []
        indexLines.append("Transcript SCROLL visual comparison (#129)")
        indexLines.append("viewport: \(Int(Self.width))x\(Int(Self.viewportHeight)) pt")
        indexLines.append("generated: \(ISO8601DateFormatter().string(from: Date()))")
        indexLines.append("")

        // A tall synthetic scenario (many alternating bubbles) guarantees the
        // document far exceeds the viewport so every offset is a real scroll.
        var scenarios: [(name: String, items: [TranscriptItem])] = [
            ("tall-synthetic", Self.tallSynthetic()),
            // The tall AskUserQuestion card that exposed the height
            // under-reservation bug — scrolled past so its full reserved extent
            // is exercised through a real viewport. (#129)
            ("tallAsk", TranscriptCompareFixtures.items(for: "tallAsk"))
        ]
        // Plus the real sessions that reportedly showed the overlap.
        for real in TranscriptCompareRealSessions.scenarios() {
            let items = TranscriptCompareRealSessions.parseWindow(for: real)
            if !items.isEmpty {
                scenarios.append((real.name, items))
            }
        }

        for (scenario, items) in scenarios {
            var paths = try renderScrolled(scenario: scenario, items: items, appState: appState)
            // Fresh-open snapshot (no manual scroll): drives the production
            // Coordinator's initial bottom-pin so we can confirm an open lands at
            // the TRUE bottom (newest content), not the middle/top. (#129)
            paths.append(try renderOpen(scenario: scenario, items: items, appState: appState))

            // For the "this session" diagnosis scenario the orchestrator expects a
            // single, stably-named scrolled NEW artifact with the reported region
            // (the `<task-notification>` user bubble) in view. The window is short,
            // so the bottom-pinned "open" snapshot already lands that region on
            // screen; alias it to the requested path so the report can reference it
            // without depending on which fractional offset happened to catch it.
            if scenario == "thisSession-phrase" {
                let alias = "\(Self.outputDir)/thisSession-phrase-scroll__new.png"
                let openPath = "\(Self.outputDir)/scroll-\(scenario)-open__new.png"
                try? fm.removeItem(atPath: alias)
                try fm.copyItem(atPath: openPath, toPath: alias)
                paths.append(alias)
            }

            indexLines.append("scenario: \(scenario) (\(items.count) items)")
            for path in paths {
                let size = (try? fm.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
                indexLines.append("  \(path)  (\(size) bytes)")
            }
            indexLines.append("")
        }

        let index = indexLines.joined(separator: "\n") + "\n"
        try index.write(toFile: "\(Self.outputDir)/SCROLL-INDEX.txt", atomically: true, encoding: .utf8)
        #expect(true)
    }

    // MARK: - Scrolling NEW path

    /// Hosts the NEW STTextView in a fixed-viewport scroll view, scrolls to four
    /// offsets, and snapshots each VISIBLE viewport. Returns the written paths.
    private func renderScrolled(
        scenario: String,
        items: [TranscriptItem],
        appState: AppState
    ) throws -> [String] {
        let context = TranscriptCardContext(
            terminalID: nil,
            openTranscriptOverlay: { _ in },
            navigateToThread: { _ in },
            appState: appState
        )
        let document = TranscriptDocument(context: context)

        let scrollView = ReadOnlySTTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? STTextView else {
            Issue.record("ReadOnlySTTextView.scrollableTextView() had no STTextView document view")
            return []
        }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isHorizontallyResizable = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let nodes = transcriptRenderNodes(from: items)
        if let contentStorage = textView.textContentManager as? NSTextContentStorage {
            let textStorage = contentStorage.textStorage ?? {
                let created = NSTextStorage()
                contentStorage.textStorage = created
                return created
            }()
            document.bind(to: textStorage)
            document.rebuild(nodes)
        } else {
            document.rebuild(nodes)
            textView.attributedText = document.storage
        }

        // FIXED viewport in an offscreen window. Unlike the sister harness, the
        // scroll view keeps a real (small) clip view so content scrolls.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.viewportHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        scrollView.frame = NSRect(x: 0, y: 0, width: Self.width, height: Self.viewportHeight)
        scrollView.hasVerticalScroller = true

        // Drive TextKit2 to lay out the WHOLE document so the document view gets
        // its real (tall) height and `contentSize` is correct before scrolling.
        forceFullLayout(textView)
        pumpRunLoop()
        forceFullLayout(textView)
        pumpRunLoop()

        let clip = scrollView.contentView
        let docView = scrollView.documentView ?? textView
        let docHeight = docView.frame.height
        let maxOffsetY = max(0, docHeight - Self.viewportHeight)

        // Top, ~1/3, ~2/3, bottom.
        let offsets: [(label: String, y: CGFloat)] = [
            ("top", 0),
            ("third", maxOffsetY / 3),
            ("twothirds", maxOffsetY * 2 / 3),
            ("bottom", maxOffsetY)
        ]

        var written: [String] = []
        for offset in offsets {
            // Scroll the clip view, reflect, then FORCE viewport layout so the
            // newly-exposed range is realized and the bubble overlay sees the
            // current viewport — mimicking a live scroll frame.
            clip.scroll(to: NSPoint(x: 0, y: offset.y))
            scrollView.reflectScrolledClipView(clip)
            forceViewportLayout(textView)
            pumpRunLoop()
            // Repaint bubbles for the new viewport (the live pane does this via
            // layout()/setBubblesNeedDisplay()).
            (textView as? ReadOnlySTTextView)?.setBubblesNeedDisplay()
            forceViewportLayout(textView)
            pumpRunLoop()

            let path = "\(Self.outputDir)/scroll-\(scenario)-\(offset.label)__new.png"
            try snapshotViewport(scrollView: scrollView, to: path)
            written.append(path)
        }
        return written
    }

    /// Fresh-open snapshot: wires a production `Coordinator` exactly as
    /// `makeNSView` does, drives its initial bottom-pin (`scrollToTrueBottom`),
    /// pumps the runloop, and snapshots the viewport. The result must show the
    /// BOTTOM (newest) content for a long transcript. (#129)
    private func renderOpen(
        scenario: String,
        items: [TranscriptItem],
        appState: AppState
    ) throws -> String {
        let context = TranscriptCardContext(
            terminalID: nil,
            openTranscriptOverlay: { _ in },
            navigateToThread: { _ in },
            appState: appState
        )
        let coordinator = STTextViewTranscriptView.Coordinator(
            document: TranscriptDocument(context: context)
        )

        let scrollView = ReadOnlySTTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? STTextView else {
            throw HarnessError.couldNotMakeBitmap
        }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isHorizontallyResizable = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let nodes = transcriptRenderNodes(from: items)
        if let contentStorage = textView.textContentManager as? NSTextContentStorage {
            let textStorage = contentStorage.textStorage ?? {
                let created = NSTextStorage()
                contentStorage.textStorage = created
                return created
            }()
            coordinator.document.bind(to: textStorage)
            coordinator.document.rebuild(nodes)
        } else {
            coordinator.document.rebuild(nodes)
            textView.attributedText = coordinator.document.storage
        }
        coordinator.textView = textView
        coordinator.scrollView = scrollView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.viewportHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        scrollView.frame = NSRect(x: 0, y: 0, width: Self.width, height: Self.viewportHeight)
        scrollView.hasVerticalScroller = true

        // Drive the production bottom-pin and let its async retries settle.
        coordinator.scrollToTrueBottom(attempts: 8)
        for _ in 0..<12 {
            forceFullLayout(textView)
            forceViewportLayout(textView)
            pumpRunLoop()
        }
        (textView as? ReadOnlySTTextView)?.setBubblesNeedDisplay()
        forceViewportLayout(textView)
        pumpRunLoop()

        let path = "\(Self.outputDir)/scroll-\(scenario)-open__new.png"
        try snapshotViewport(scrollView: scrollView, to: path)
        return path
    }

    /// Lays out the ENTIRE document so the document view's height (and thus the
    /// scrollable extent) is correct before we start scrolling.
    private func forceFullLayout(_ textView: STTextView) {
        textView.layoutSubtreeIfNeeded()
        let layoutManager = textView.textLayoutManager
        let documentRange = layoutManager.documentRange
        layoutManager.ensureLayout(for: documentRange)
        layoutManager.enumerateTextLayoutFragments(
            from: documentRange.location,
            options: [.ensuresLayout]
        ) { _ in true }
        textView.layoutSubtreeIfNeeded()
    }

    /// Forces TextKit2 to lay out just the CURRENT viewport (what a live scroll
    /// frame does) so the freshly-exposed range is realized.
    private func forceViewportLayout(_ textView: STTextView) {
        textView.textLayoutManager.textViewportLayoutController.layoutViewport()
        textView.layoutSubtreeIfNeeded()
    }

    private func pumpRunLoop() {
        for _ in 0..<5 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// Snapshots the VISIBLE viewport region (clip view bounds) by caching the
    /// document view's visible sub-rect into a viewport-sized bitmap. This is the
    /// artifact that reveals scroll-time overlap — it shows exactly what the user
    /// sees at this scroll offset.
    private func snapshotViewport(scrollView: NSScrollView, to path: String) throws {
        let clip = scrollView.contentView
        guard let docView = scrollView.documentView else { throw HarnessError.couldNotMakeBitmap }
        let visible = clip.documentVisibleRect  // sub-rect of docView currently shown

        let size = NSSize(width: Self.width, height: Self.viewportHeight)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        // Cache the document view's visible region into a bitmap, then draw it at
        // the viewport origin. Using cacheDisplay on the visible sub-rect renders
        // exactly the scrolled-into-view content (including the bubble overlay).
        if let rep = docView.bitmapImageRepForCachingDisplay(in: visible) {
            rep.size = visible.size
            docView.cacheDisplay(in: visible, to: rep)
            rep.draw(in: NSRect(origin: .zero, size: visible.size))
        }
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let merged = NSBitmapImageRep(data: tiff),
              let png = merged.representation(using: .png, properties: [:]) else {
            throw HarnessError.couldNotMakePNG
        }
        try png.write(to: URL(fileURLWithPath: path))
    }

    // MARK: - Tall synthetic scenario

    /// A tall transcript: many alternating user/assistant bubbles, each multi-
    /// line so the document is well over the 600pt viewport and every scroll
    /// offset crosses several bubble boundaries (where overlap shows up).
    private static func tallSynthetic() -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        for i in 0..<24 {
            items.append(.userPrompt(
                id: "scroll-u\(i)",
                text: "Question number \(i): can you walk me through how part \(i) of the "
                    + "transcript pipeline works, and what the main trade-offs were? "
                    + "I want enough detail that this wraps across multiple lines.",
                timestamp: nil
            ))
            items.append(.assistantText(
                id: "scroll-a\(i)",
                text: """
                ### Answer \(i)

                Part \(i) of the pipeline takes the upstream items and converts them \
                into render nodes. Each node is cached so a re-poll does not rebuild \
                the whole list. This paragraph is intentionally long so the assistant \
                card has real height and spans several wrapped lines in the viewport.

                A second paragraph for block \(i) to add vertical extent and force the \
                bubble to be tall enough that scroll offsets land in the middle of it, \
                which is exactly where mid-scroll overlap would be visible.
                """,
                timestamp: nil,
                usage: nil
            ))
        }
        return items
    }

    enum HarnessError: Error {
        case couldNotMakeBitmap
        case couldNotMakePNG
    }
}
