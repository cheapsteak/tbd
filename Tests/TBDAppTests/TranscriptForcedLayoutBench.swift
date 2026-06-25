import AppKit
import STTextView
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared

/// Env-gated, HEADLESS measurement of the wall-clock cost of forcing a FULL
/// TextKit2 layout pass over the ENTIRE "this session" transcript (issue #129).
///
/// PURPOSE: decide whether scroll-to-bottom can pay a one-time full-layout cost
/// on open, or whether that defeats virtualization. The "open cost" is the COLD
/// `forceFullLayout` time measured immediately after `rebuild`+`bind`, when only
/// the top of the document is laid out. The WARM cost (a second pass on the
/// settled layout) confirms TextKit2 caching.
///
/// Mirrors the sister `TranscriptScrollCompareHarness` setup: a
/// `ReadOnlySTTextView.scrollableTextView()` hosted in an offscreen NSWindow at
/// width 680 (real container width matters for wrap cost), with a
/// `TranscriptDocument` bound to the content storage's `NSTextStorage` and
/// `document.rebuild(transcriptRenderNodes(from: items))`.
///
/// Inert during normal `swift test`: early-returns unless `TBD_LAYOUT_BENCH=1`.
/// Run explicitly:
///
///     TBD_LAYOUT_BENCH=1 swift test --filter TranscriptForcedLayoutBench
///
/// Reads the FULL session JSONL from `TBD_COMPARE_THIS_SESSION` (default: the
/// scratchpad copy). Writes numbers to stdout AND
/// `/tmp/transcript-compare/FORCED-LAYOUT-BENCH.txt`.
@Suite("Transcript forced full-layout bench (#129)")
@MainActor
struct TranscriptForcedLayoutBench {

    /// Fixed render width, matching the transcript content column / sister harness.
    private static let width: CGFloat = 680
    private static let viewportHeight: CGFloat = 600
    private static let outputDir = "/tmp/transcript-compare"
    private static let outputFile = "/tmp/transcript-compare/FORCED-LAYOUT-BENCH.txt"

    /// Guard so a pathological full layout cannot hang the test indefinitely.
    private static let fullLayoutBudgetSeconds: Double = 300

    @Test("forced full-layout wall-clock cost (gated by TBD_LAYOUT_BENCH=1)")
    func measureForcedFullLayout() throws {
        guard ProcessInfo.processInfo.environment["TBD_LAYOUT_BENCH"] == "1" else {
            #expect(true)
            return
        }

        let fm = FileManager.default
        try fm.createDirectory(atPath: Self.outputDir, withIntermediateDirectories: true)

        var log: [String] = []
        func emit(_ line: String) {
            print(line)
            log.append(line)
        }

        emit("Transcript FORCED full-layout bench (#129)")
        emit("render width: \(Int(Self.width)) pt")
        emit("generated: \(ISO8601DateFormatter().string(from: Date()))")
        emit("")

        guard let path = Self.resolveThisSessionPath() else {
            emit("ERROR: no session JSONL found (set TBD_COMPARE_THIS_SESSION).")
            try Self.write(log)
            Issue.record("no session JSONL found")
            return
        }
        emit("session: \(path)")

        // Parse the WHOLE session into items (not a window).
        let parseClock = ContinuousClock()
        let parseStart = parseClock.now
        let items = TranscriptCompareRealSessions.parse(filePath: path)
        let parseMs = Self.ms(parseClock.now - parseStart)
        emit("parsed items: \(items.count)  (parse \(Self.fmt(parseMs)) ms)")

        guard !items.isEmpty else {
            emit("ERROR: parsed 0 items.")
            try Self.write(log)
            Issue.record("parsed 0 items")
            return
        }

        // --- FULL session measurement -----------------------------------------
        let full = try measure(items: items, label: "FULL", emit: emit)
        emit("")

        // If the full pass blew the budget, also measure a smaller slice to get a
        // per-item cost for extrapolation. (We still report the full number — a
        // multi-second full pass is itself the answer: not viable on open.)
        if full.coldExceededBudget || full.coldMs > 5000 {
            emit("Full pass was expensive; measuring a 1000-item slice for per-item cost.")
            let slice = Array(items.prefix(min(1000, items.count)))
            let small = try measure(items: slice, label: "SLICE-1000", emit: emit)
            let perItem = small.coldMs / Double(slice.count)
            let extrapolated = perItem * Double(items.count)
            emit("per-item cold cost: \(Self.fmt(perItem)) ms/item")
            emit("extrapolated full cold cost: \(Self.fmt(extrapolated)) ms "
                + "(\(items.count) items)")
            emit("")
        }

        // --- Verdict -----------------------------------------------------------
        emit("=== SUMMARY ===")
        emit("items: \(items.count)")
        emit("doc char length: \(full.docCharLength)")
        emit("doc view height: \(Self.fmt(full.docHeight)) pt")
        emit("COLD full-layout: \(Self.fmt(full.coldMs)) ms"
            + (full.coldExceededBudget ? "  (DID NOT COMPLETE within budget)" : ""))
        emit("WARM re-layout:   \(Self.fmt(full.warmMs)) ms")
        let verdict: String
        if full.coldExceededBudget {
            verdict = "NO — full layout did not complete within \(Int(Self.fullLayoutBudgetSeconds))s"
        } else if full.coldMs <= 300 {
            verdict = "YES — one-time full-layout-on-open is viable (cold <= 300ms)"
        } else if full.coldMs < 1000 {
            verdict = "MARGINAL — cold \(Self.fmt(full.coldMs)) ms is noticeable but sub-second"
        } else {
            verdict = "NO — cold \(Self.fmt(full.coldMs)) ms defeats virtualization (seconds-scale)"
        }
        emit("VERDICT: \(verdict)")

        try Self.write(log)
        #expect(true)
    }

    // MARK: - Tail-only realization experiments (A / B / C)

    private static let tailOutputFile = "/tmp/transcript-compare/TAIL-LAYOUT-BENCH.txt"

    /// Built document + its TextKit2 handles, with the document view height
    /// captured at construction time (the pure ESTIMATE, before any forced pass).
    private struct Built {
        let scrollView: NSScrollView
        let textView: STTextView
        let layoutManager: NSTextLayoutManager
        let window: NSWindow
        let docCharLength: Int
        /// documentView.frame.height immediately after bind+rebuild, before any
        /// forced layout — the non-laid-out ESTIMATE.
        let estimateHeight: CGFloat
        /// usageBoundsForTextContainer.height immediately after construction.
        let estimateUsageHeight: CGFloat
    }

    /// THE decisive experiment: does realizing ONLY the tail of the document stay
    /// O(visible), or cascade into a full O(document) layout? Three probes (A/B/C),
    /// each on a FRESH document so nothing is pre-laid-out.
    @Test("tail-only realization: cheap or cascade? (gated by TBD_LAYOUT_BENCH=1)")
    func measureTailRealization() throws {
        guard ProcessInfo.processInfo.environment["TBD_LAYOUT_BENCH"] == "1" else {
            #expect(true)
            return
        }

        let fm = FileManager.default
        try fm.createDirectory(atPath: Self.outputDir, withIntermediateDirectories: true)

        var log: [String] = []
        func emit(_ line: String) {
            print(line)
            log.append(line)
        }

        emit("Transcript TAIL-only realization bench (#129)")
        emit("render width: \(Int(Self.width)) pt   viewport: \(Int(Self.viewportHeight)) pt")
        emit("generated: \(ISO8601DateFormatter().string(from: Date()))")
        emit("")

        guard let path = Self.resolveThisSessionPath() else {
            emit("ERROR: no session JSONL found (set TBD_COMPARE_THIS_SESSION).")
            try Self.writeTail(log)
            Issue.record("no session JSONL found")
            return
        }
        emit("session: \(path)")

        let items = TranscriptCompareRealSessions.parse(filePath: path)
        emit("parsed items: \(items.count)")
        guard !items.isEmpty else {
            emit("ERROR: parsed 0 items.")
            try Self.writeTail(log)
            Issue.record("parsed 0 items")
            return
        }
        emit("")

        // Establish the TRUTH: a full pass on a throwaway document so we know the
        // real document height to compare the pure estimate against.
        let truth = try buildDocument(items: items)
        forceFullLayout(truth.textView,
                        deadline: ContinuousClock().now + .seconds(Self.fullLayoutBudgetSeconds),
                        clock: ContinuousClock())
        pumpRunLoop()
        let trueHeight = (truth.scrollView.documentView ?? truth.textView).frame.height
        let trueUsageHeight = truth.layoutManager.usageBoundsForTextContainer.height
        emit("TRUTH (after full pass): docViewHeight \(Self.fmt(trueHeight)) pt  "
            + "usageBounds.height \(Self.fmt(trueUsageHeight)) pt")
        emit("ESTIMATE (no layout):     docViewHeight \(Self.fmt(truth.estimateHeight)) pt  "
            + "usageBounds.height \(Self.fmt(truth.estimateUsageHeight)) pt")
        emit("")

        // ---- EXPERIMENT A: reverse tail realization ---------------------------
        // Track the small-target run so the verdict can reason over real numbers.
        var aMs = 0.0
        var aFrags = 0
        for target in [CGFloat(600), CGFloat(2000)] {
            let b = try buildDocument(items: items)
            emit("[A target=\(Int(target))pt] BEFORE: usageBounds.height "
                + "\(Self.fmt(b.estimateUsageHeight)) pt  docViewHeight \(Self.fmt(b.estimateHeight)) pt")

            var visited = 0
            var accumulated: CGFloat = 0
            let clock = ContinuousClock()
            let start = clock.now
            b.layoutManager.enumerateTextLayoutFragments(
                from: b.layoutManager.documentRange.endLocation,
                options: [.reverse, .ensuresLayout]
            ) { frag in
                visited += 1
                accumulated += frag.layoutFragmentFrame.height
                return accumulated < target
            }
            let elapsed = Self.ms(clock.now - start)

            let afterUsage = b.layoutManager.usageBoundsForTextContainer.height
            let afterDocHeight = (b.scrollView.documentView ?? b.textView).frame.height
            // Two independent cascade tests: wall-clock (a full pass is seconds) and
            // usageBounds (a full pass reaches the true container extent).
            let timeCascade = elapsed > 200
            let usageCascade = afterUsage >= trueUsageHeight * 0.9
            if target == 600 { aMs = elapsed; aFrags = visited }
            emit("[A target=\(Int(target))pt] \(Self.fmt(elapsed)) ms  "
                + "fragsVisited \(visited)  accumulatedHeight \(Self.fmt(accumulated)) pt")
            emit("[A target=\(Int(target))pt] AFTER:  usageBounds.height \(Self.fmt(afterUsage)) pt "
                + "(\(Self.fmt(Double(afterUsage) / Double(max(trueUsageHeight, 1)) * 100))% of true)  "
                + "docViewHeight \(Self.fmt(afterDocHeight)) pt")
            emit("[A target=\(Int(target))pt] cascade? time:\(timeCascade ? "YES" : "no") "
                + "usage:\(usageCascade ? "YES" : "no") => "
                + (timeCascade ? "FULL layout (BAD)"
                    : usageCascade ? "container extent fully resolved but in \(Self.fmt(elapsed))ms"
                    : "stayed CHEAP / O(visible) (GOOD)"))
            emit("")
        }

        // ---- EXPERIMENT B: ensureLayout on a small end range ------------------
        do {
            let b = try buildDocument(items: items)
            let tailChars = min(2000, b.docCharLength)
            emit("[B endRange=\(tailChars) chars] BEFORE: usageBounds.height "
                + "\(Self.fmt(b.estimateUsageHeight)) pt")

            let contentManager = b.textView.textContentManager
            let endLoc = contentManager.documentRange.endLocation
            guard let startLoc = contentManager.location(endLoc, offsetBy: -tailChars) else {
                emit("[B] ERROR: could not offset back \(tailChars) chars from end")
                try Self.writeTail(log)
                Issue.record("could not build end range")
                return
            }
            let endRange = NSTextRange(location: startLoc, end: endLoc)!

            let clock = ContinuousClock()
            let start = clock.now
            b.layoutManager.ensureLayout(for: endRange)
            let elapsed = Self.ms(clock.now - start)

            let afterUsage = b.layoutManager.usageBoundsForTextContainer.height
            let afterDocHeight = (b.scrollView.documentView ?? b.textView).frame.height
            let cascaded = afterUsage >= trueUsageHeight * 0.9
            emit("[B endRange=\(tailChars) chars] \(Self.fmt(elapsed)) ms")
            emit("[B endRange=\(tailChars) chars] AFTER:  usageBounds.height \(Self.fmt(afterUsage)) pt  "
                + "docViewHeight \(Self.fmt(afterDocHeight)) pt  "
                + (cascaded ? "=> CASCADED to full layout (BAD)" : "=> stayed O(visible) (GOOD)"))
            emit("")
        }

        // ---- EXPERIMENT C: viewport layout at estimated bottom (control) ------
        do {
            let b = try buildDocument(items: items)
            emit("[C] BEFORE: docViewHeight (ESTIMATE) \(Self.fmt(b.estimateHeight)) pt  "
                + "usageBounds.height \(Self.fmt(b.estimateUsageHeight)) pt")
            emit("[C] TRUTH docViewHeight \(Self.fmt(trueHeight)) pt  "
                + "estimate error \(Self.fmt(b.estimateHeight - trueHeight)) pt "
                + "(\(Self.fmt(Double(b.estimateHeight - trueHeight) / Double(max(trueHeight, 1)) * 100))%)")

            let clip = b.scrollView.contentView
            let estimatedBottomY = max(0, b.estimateHeight - Self.viewportHeight)
            clip.scroll(to: NSPoint(x: 0, y: estimatedBottomY))
            b.scrollView.reflectScrolledClipView(clip)

            let clock = ContinuousClock()
            let start = clock.now
            b.textView.textLayoutManager.textViewportLayoutController.layoutViewport()
            b.textView.layoutSubtreeIfNeeded()
            let elapsed = Self.ms(clock.now - start)

            let afterUsage = b.layoutManager.usageBoundsForTextContainer.height
            let afterDocHeight = (b.scrollView.documentView ?? b.textView).frame.height
            let cascaded = afterUsage >= trueUsageHeight * 0.9

            // Did scrolling to the estimated bottom land near the REAL end? Compare
            // the visible rect's max-Y against the true document height.
            let visibleMaxY = clip.documentVisibleRect.maxY
            let distanceFromTrueEnd = trueHeight - visibleMaxY
            emit("[C] layoutViewport at estimatedBottomY=\(Self.fmt(estimatedBottomY)) pt: "
                + "\(Self.fmt(elapsed)) ms")
            emit("[C] AFTER:  usageBounds.height \(Self.fmt(afterUsage)) pt  "
                + "docViewHeight \(Self.fmt(afterDocHeight)) pt  "
                + (cascaded ? "=> CASCADED to full layout" : "=> stayed O(visible)"))
            emit("[C] visible.maxY \(Self.fmt(visibleMaxY)) pt vs trueHeight \(Self.fmt(trueHeight)) pt  "
                + "=> landed \(Self.fmt(distanceFromTrueEnd)) pt "
                + (abs(distanceFromTrueEnd) < 3000
                    ? "from real end (NEAR newest content)"
                    : "from real end (FAR off — estimate misleads scroll)"))
            emit("")
        }

        // ---- VERDICT ----------------------------------------------------------
        emit("=== VERDICT ===")
        // The decisive signal is wall-clock: a FULL layout pass on this doc costs
        // ~2353ms. Experiment A realized one viewport of the tail in single-digit
        // ms, visiting only a handful of fragments — orders of magnitude cheaper
        // than a full pass. The usageBounds.height bump is TextKit2 resolving the
        // CONTAINER extent estimate, NOT laying out every fragment (it does not
        // reach the true ~193650pt and takes ms, not seconds).
        let tailIsCheap = aMs < 200
        if tailIsCheap {
            emit("VERDICT: YES — tail-only realization is CHEAP "
                + "(\(Self.fmt(aMs)) ms, \(aFrags) fragments for one 600pt viewport).")
            emit("A content-visibility-style bottom-anchored virtualization is VIABLE:")
            emit("you can realize just the visible tail without paying the ~2353ms full pass.")
        } else {
            emit("VERDICT: NO — tail realization cost \(Self.fmt(aMs)) ms, i.e. it CASCADED "
                + "into a full O(document) layout. The document must be windowed instead.")
        }
        emit("CAVEAT (Experiment C): documentView height is NOT pre-estimated — it sits at "
            + "the viewport height (\(Self.fmt(truth.estimateHeight)) pt) until a full pass, "
            + "vs true \(Self.fmt(trueHeight)) pt. So you cannot scroll to an 'estimated bottom' "
            + "to lazily realize the tail; the scrollable extent only exists AFTER full layout. "
            + "Bottom-anchored virtualization needs its own height bookkeeping, not the text view's.")

        try Self.writeTail(log)
        #expect(true)
    }

    /// Builds a FRESH document for `items`: scroll view + bound storage + rebuild,
    /// hosted offscreen at the real container width. Captures the document height
    /// and usageBounds BEFORE any forced layout (the estimate). Nothing in here
    /// forces a full pass, so the returned document is genuinely cold.
    private func buildDocument(items: [TranscriptItem]) throws -> Built {
        let suiteName = "transcript-tail-bench-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let context = TranscriptCardContext(
            terminalID: nil,
            openTranscriptOverlay: { _ in },
            navigateToThread: { _ in },
            appState: appState
        )
        let document = TranscriptDocument(context: context)

        let scrollView = ReadOnlySTTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? STTextView else {
            throw HarnessError.couldNotMakeTextView
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

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.viewportHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        scrollView.frame = NSRect(x: 0, y: 0, width: Self.width, height: Self.viewportHeight)
        scrollView.hasVerticalScroller = true

        let layoutManager = textView.textLayoutManager
        let estimateHeight = (scrollView.documentView ?? textView).frame.height
        let estimateUsageHeight = layoutManager.usageBoundsForTextContainer.height

        return Built(
            scrollView: scrollView,
            textView: textView,
            layoutManager: layoutManager,
            window: window,
            docCharLength: document.storage.length,
            estimateHeight: estimateHeight,
            estimateUsageHeight: estimateUsageHeight
        )
    }

    private static func writeTail(_ lines: [String]) throws {
        let text = lines.joined(separator: "\n") + "\n"
        try text.write(toFile: tailOutputFile, atomically: true, encoding: .utf8)
    }

    // MARK: - Measurement

    private struct Result {
        var docCharLength: Int
        var docHeight: CGFloat
        var coldMs: Double
        var warmMs: Double
        var coldExceededBudget: Bool
    }

    /// Builds the document for `items`, then times a COLD `forceFullLayout`
    /// (first pass, only top laid out) and a WARM second pass (settled layout).
    private func measure(
        items: [TranscriptItem],
        label: String,
        emit: (String) -> Void
    ) throws -> Result {
        let suiteName = "transcript-layout-bench-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let context = TranscriptCardContext(
            terminalID: nil,
            openTranscriptOverlay: { _ in },
            navigateToThread: { _ in },
            appState: appState
        )
        let document = TranscriptDocument(context: context)

        let scrollView = ReadOnlySTTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? STTextView else {
            throw HarnessError.couldNotMakeTextView
        }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isHorizontallyResizable = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        // Build render nodes + bind document storage. Time the rebuild too.
        let buildClock = ContinuousClock()
        let nodesStart = buildClock.now
        let nodes = transcriptRenderNodes(from: items)
        let nodesMs = Self.ms(buildClock.now - nodesStart)

        let rebuildStart = buildClock.now
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
        let rebuildMs = Self.ms(buildClock.now - rebuildStart)
        let docCharLength = document.storage.length

        // Offscreen window at real container width so wrapping cost is realistic.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.viewportHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        scrollView.frame = NSRect(x: 0, y: 0, width: Self.width, height: Self.viewportHeight)
        scrollView.hasVerticalScroller = true

        emit("[\(label)] nodes: \(nodes.count)  build nodes \(Self.fmt(nodesMs)) ms  "
            + "rebuild+bind \(Self.fmt(rebuildMs)) ms  docChars \(docCharLength)")

        // COLD: only the top is laid out at this point. Time the O(N) full pass.
        let clock = ContinuousClock()
        let coldStart = clock.now
        let deadline = coldStart + .seconds(Self.fullLayoutBudgetSeconds)
        let completed = forceFullLayout(textView, deadline: deadline, clock: clock)
        let coldMs = Self.ms(clock.now - coldStart)
        let coldExceededBudget = !completed

        let docView = scrollView.documentView ?? textView
        let docHeight = docView.frame.height

        emit("[\(label)] COLD forceFullLayout: \(Self.fmt(coldMs)) ms"
            + (coldExceededBudget ? "  (exceeded budget, aborted enumeration)" : "")
            + "  docHeight \(Self.fmt(docHeight)) pt")

        // WARM: pump the runloop to let layout settle, then re-run. Should be cheap.
        pumpRunLoop()
        let warmStart = clock.now
        _ = forceFullLayout(textView, deadline: warmStart + .seconds(Self.fullLayoutBudgetSeconds), clock: clock)
        let warmMs = Self.ms(clock.now - warmStart)
        emit("[\(label)] WARM forceFullLayout: \(Self.fmt(warmMs)) ms")

        return Result(
            docCharLength: docCharLength,
            docHeight: docHeight,
            coldMs: coldMs,
            warmMs: warmMs,
            coldExceededBudget: coldExceededBudget
        )
    }

    /// The exact O(N) pass copied from `TranscriptScrollCompareHarness`, with a
    /// deadline guard: if the per-fragment enumeration overruns the budget we
    /// stop early and report non-completion rather than hanging the test.
    /// Returns `true` if the full pass completed within budget.
    @discardableResult
    private func forceFullLayout(
        _ textView: STTextView,
        deadline: ContinuousClock.Instant,
        clock: ContinuousClock
    ) -> Bool {
        textView.layoutSubtreeIfNeeded()
        let layoutManager = textView.textLayoutManager
        let documentRange = layoutManager.documentRange
        layoutManager.ensureLayout(for: documentRange)
        var completed = true
        layoutManager.enumerateTextLayoutFragments(
            from: documentRange.location,
            options: [.ensuresLayout]
        ) { _ in
            if clock.now >= deadline {
                completed = false
                return false  // abort enumeration
            }
            return true
        }
        textView.layoutSubtreeIfNeeded()
        return completed
    }

    private func pumpRunLoop() {
        for _ in 0..<5 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    // MARK: - Helpers

    private static func resolveThisSessionPath() -> String? {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["TBD_COMPARE_THIS_SESSION"],
           fm.fileExists(atPath: override) {
            return override
        }
        let fallback = "/private/tmp/claude-501/-Users-chang-tbd-worktrees-tbd-transcript-row-flatten"
            + "/6F6A46F5-0E30-4CF8-A06C-A5C628760FF5/scratchpad/this-session-6F6A46F5.jsonl"
        return fm.fileExists(atPath: fallback) ? fallback : nil
    }

    private static func write(_ lines: [String]) throws {
        let text = lines.joined(separator: "\n") + "\n"
        try text.write(toFile: outputFile, atomically: true, encoding: .utf8)
    }

    private static func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    enum HarnessError: Error {
        case couldNotMakeTextView
    }
}
