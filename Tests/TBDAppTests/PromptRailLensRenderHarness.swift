#if TBD_HARNESSES
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import TBDApp
import TestSupport

/// Env-gated **render** harness for the prompt rail's lens: one PNG per
/// scenario per appearance, at 2x, for a person to look at.
///
/// The lens exists only under a hovering pointer, and hover cannot be driven on
/// the live app from automation, so this mounts the rail offscreen and drives
/// it the way `PromptRailLensViewTests` does: synthesized mouse moves reach the
/// hover model, its 80ms open delay runs on an `EventDrivenTestClock`, and
/// frames are stepped by hand through `advanceFrame(to:)`, since the rail is
/// built with no display link. Those tests assert the lens's geometry; this
/// one shows what it looks like.
///
/// Compiled only when the `TBD_HARNESSES` condition is set (see
/// `Tests/CLAUDE.md`), so a normal run neither builds nor schedules it, and
/// even then every test early-returns unless `TBD_PROMPT_RAIL_SHOTS_DIR` names a
/// directory to write into:
///
///     TBD_PROMPT_RAIL_SHOTS_DIR=/tmp/rail-shots scripts/test.sh \
///         -Xswiftc -DTBD_HARNESSES --filter PromptRailLensRenderHarness
///
/// Nothing in CI compiles this file, so a refactor elsewhere can leave it
/// failing to build; fix it when you next enable it.
///
/// **The scene.** Each shot mounts a pane, 420 × 600pt unless its scenario
/// says otherwise, in an offscreen window. At the bottom is a fake transcript:
/// the window background and thirty lines of grey 13pt body text from x 28.
/// Over it sits a real `TranscriptContainerView` with the rail installed
/// through `installPromptRail`, so the container frames the rail exactly as
/// the app does — the 20pt gutter at rest, the open width while a lens exists
/// (`wantsOpenWidth`, reported through `onOpenWidthChange`) — and lays it out
/// again after every frame. The prompts are generic coding-agent prompts with
/// varied work counts, a peer message every sixth entry, and one active entry
/// a little past the middle. The pointer itself is not drawn; each
/// `PromptRailLensShot` says where it is. Files are named
/// `<nn>-<scenario>-<light|dark>.png`.
///
/// **What a capture leaves out.** Shots go through
/// `OffscreenHost.capture(scale:)`, which renders with
/// `displayIgnoringOpacity(_:in:)`, the explicit-scale spelling of
/// `cacheDisplay(in:to:)`. Both run each view's `draw(_:)` into a bitmap rather
/// than compositing the layer tree, so effects that live on a layer may not
/// appear:
/// - **The overflow fade** is a `CAGradientLayer` set as the rail layer's mask
///   (`PromptRailNSView.setFade`). Where the column is clipped — the 450-prompt
///   shot — its ends may stop hard here, where the app fades them over 24pt.
/// - **The box's shadow** is drawn with `CGContext.setShadow` inside
///   `draw(_:)`, not as a layer shadow, so it should appear. If it is missing,
///   suspect this capture path before the lens.
///
/// **Each shot checks what it captured** before writing: that the render is
/// not blank (`OffscreenHostDefaults.minLuminanceVariance`, as
/// `ComposerRenderHarness` checks), and that the lens is in the state its
/// scenario names — fully open and settled, or part way through its grow. A
/// shot that cannot be made is recorded as an issue naming its file, and the
/// harness goes on to the next.
@MainActor
@Suite("Prompt rail lens render harness", .clockDriven, .serialized)
struct PromptRailLensRenderHarness {

    /// The two appearances each shot is rendered in, as their file-name
    /// suffixes.
    private enum Look: String, CaseIterable {
        case light
        case dark

        var appearanceName: NSAppearance.Name { self == .light ? .aqua : .darkAqua }
    }

    /// Where the PNGs go, or `nil` when the harness is inert.
    private static var outputDirectory: URL? {
        let path = ProcessInfo.processInfo.environment["TBD_PROMPT_RAIL_SHOTS_DIR"] ?? ""
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Pixels per point. 2x because these are read on a Retina display, and a
    /// 1x capture of the lens's 13pt rows loses the detail worth looking at.
    private static let captureScale: CGFloat = 2
    private static let paneHeight: CGFloat = 600

    @Test("renders the prompt rail lens (gated by TBD_PROMPT_RAIL_SHOTS_DIR)", arguments: PromptRailLensShot.allCases)
    func render(_ scenario: PromptRailLensShot) async {
        guard let directory = Self.outputDirectory else { return }
        for look in Look.allCases {
            let file = "\(scenario.rawValue)-\(look.rawValue).png"
            do {
                try await Self.shoot(scenario, look: look, to: directory.appendingPathComponent(file))
            } catch {
                Issue.record(ShotFailure(file: file, cause: error))
            }
        }
    }

    /// Mounts the scenario in `look`, drives the lens to the state it names,
    /// checks the capture is a picture of something, and writes it to `url`.
    private static func shoot(_ scenario: PromptRailLensShot, look: Look, to url: URL) async throws {
        let count = scenario.promptCount
        let mount = RailShotMount(
            size: NSSize(width: scenario.paneWidth, height: paneHeight),
            appearance: NSAppearance(named: look.appearanceName),
            entries: RailShotContent.entries(count),
            workCounts: RailShotContent.workCounts(count),
            activeIndex: RailShotContent.activeIndex(count))
        defer { mount.host.tearDown() }

        if let spot = scenario.pointer {
            let point = NSPoint(x: RailShotMount.onRailX, y: mount.notchY(spot))
            try await mount.open(at: point)
            switch scenario {
            case .opening40:
                try mount.growHalfway()
            case .openHoverRow:
                try mount.settle()
                try mount.moveIntoBox(atY: point.y)
                try mount.settle()
                guard mount.rail.hoveredRow != nil else { throw RailShotError.noHoveredRow }
            default:
                try mount.settle()
            }
        }

        await mount.host.pump()
        let capture = try mount.host.capture(scale: captureScale)
        let variance = capture.luminanceVariance()
        guard variance >= OffscreenHostDefaults.minLuminanceVariance else {
            throw RailShotError.blankRender(variance: variance)
        }
        try capture.writePNG(to: url)
    }
}

// MARK: - The shots

/// `PromptRailLensRenderHarness`'s shots, as their file-name stems, numbered so
/// a directory listing reads in order. Notch numbers count from 1. "Mid-rail"
/// is the notch nearest the middle of the notch column as it shows, which for
/// a short session ends well above the rail's foot.
enum PromptRailLensShot: String, CaseIterable, Sendable, CustomTestStringConvertible {
    /// 40 prompts at rest, no pointer.
    case rest40 = "01-rest-40"
    /// 8 prompts at rest, no pointer: the taller pitch a short session rests
    /// at.
    case rest8 = "02-rest-8"
    /// 40 prompts, pointer at mid-rail, fully open and settled. The hovered
    /// row's fill shows here too, under a pointer on the rail column.
    case open40Mid = "03-open-40-mid"
    /// 40 prompts, pointer on notch 1.
    case open40Top = "04-open-40-top"
    /// 40 prompts, pointer on the last notch.
    case open40Bottom = "05-open-40-bottom"
    /// 40 prompts, pointer at mid-rail, 75ms into the 150ms grow.
    case opening40 = "06-opening-40"
    /// 5 prompts, pointer on notch 2: the few-prompts rule.
    case open5 = "07-open-5"
    /// 120 prompts, pointer at mid-rail: squeezed slivers.
    case open120 = "08-open-120"
    /// 450 prompts, pointer at mid-rail: past the minimum pitch, so the rail
    /// windows its notches.
    case open450 = "09-open-450"
    /// 40 prompts, opened at mid-rail, then the pointer moved straight across
    /// into the box on the same row, so the hovered row's fill sits under a
    /// pointer on the box's text.
    case openHoverRow = "10-open-hover-row"
    /// 40 prompts, pointer at mid-rail, in a pane 180pt wide.
    case openNarrow = "11-open-narrow"

    var testDescription: String { rawValue }

    var promptCount: Int {
        switch self {
        case .rest8: return 8
        case .open5: return 5
        case .open120: return 120
        case .open450: return 450
        case .rest40, .open40Mid, .open40Top, .open40Bottom, .opening40, .openHoverRow, .openNarrow:
            return 40
        }
    }

    var paneWidth: CGFloat { self == .openNarrow ? 180 : 420 }

    /// Where the pointer rests on the rail column; nil for a rail at rest.
    var pointer: PromptRailLensShotPointer? {
        switch self {
        case .rest40, .rest8: return nil
        case .open40Top: return .notch(1)
        case .open40Bottom: return .last
        case .open5: return .notch(2)
        case .open40Mid, .opening40, .open120, .open450, .openHoverRow, .openNarrow: return .mid
        }
    }
}

/// A notch for a `PromptRailLensShot`'s pointer to rest on.
enum PromptRailLensShotPointer: Sendable {
    /// The notch nearest the middle of the column as it shows.
    case mid
    /// Notch `number`, counting from 1.
    case notch(Int)
    /// The last notch.
    case last
}

// MARK: - The mount

/// A pane in an offscreen window: the fake transcript, and over it a
/// `TranscriptContainerView` with the rail installed as `makeNSView` installs
/// it, but with `PromptRailLensViewTests`' seams — an event-driven clock, a
/// private notification center, a fake Escape monitor, no display link, and
/// Reduce Motion off.
@MainActor
private final class RailShotMount {
    /// A point on the rail column, in rail coordinates.
    static let onRailX: CGFloat = 8
    /// The hover model's open delay.
    static let openDelay = Duration.milliseconds(80)
    /// One frame of a 60Hz display.
    static let frameInterval: TimeInterval = 1.0 / 60
    /// Two seconds of 60Hz frames: a lens still moving after that never settles.
    static let maxSettleFrames = 120

    let host: OffscreenHost<EmptyView>
    let container: TranscriptContainerView
    let rail: PromptRailNSView
    let hover: PromptRailHoverModel
    let clock: EventDrivenTestClock
    /// The last frame's timestamp.
    private var frameTime: TimeInterval = 0

    init(
        size: NSSize, appearance: NSAppearance?,
        entries: [PromptOutlineEntry], workCounts: [Int], activeIndex: Int?
    ) {
        let clock = EventDrivenTestClock()
        let center = NotificationCenter()
        let host = OffscreenHost(
            root: EmptyView(), size: size, appearance: appearance,
            background: NSColor.windowBackgroundColor)
        let transcript = FakeTranscriptView(frame: host.contentView.bounds)
        host.contentView.addSubview(transcript)

        // The scroll view draws nothing of its own, so the fake transcript
        // under the container shows through it.
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        let container = TranscriptContainerView(scrollView: scrollView, leadingGutter: PromptRailLayout.width)
        container.frame = host.contentView.bounds
        host.contentView.addSubview(container)

        let hover = PromptRailHoverModel(notificationCenter: center, clock: clock)
        let rail = PromptRailNSView(
            hover: hover,
            onJump: { _ in },
            reduceMotion: { false },
            usesDisplayLink: false)
        container.installPromptRail(
            rail: rail, hover: hover,
            escapeMonitor: PromptRailEscapeMonitor(install: { _ in NSObject() }, remove: { _ in }),
            notificationCenter: center)
        container.layoutSubtreeIfNeeded()
        rail.promptRail(entriesDidChange: entries)
        rail.promptRail(workCountsDidChange: workCounts)
        rail.promptRail(activeIndexDidChange: activeIndex)

        self.host = host
        self.container = container
        self.rail = rail
        self.hover = hover
        self.clock = clock
    }

    /// The y, in rail coordinates, of the centre of the notch `spot` names, as
    /// the resting rail shows it.
    func notchY(_ spot: PromptRailLensShotPointer) -> CGFloat {
        let layout = rail.currentLayout()
        let offset = rail.offset
        let last = max(layout.count - 1, 0)
        let index: Int
        switch spot {
        case .notch(let number):
            index = min(max(number - 1, 0), last)
        case .last:
            index = last
        case .mid:
            let top = max(PromptRailLayout.topInset - offset, 0)
            let bottom = min(layout.contentHeight - PromptRailLayout.bottomInset - offset, rail.bounds.height)
            index = layout.index(atRailY: (top + bottom) / 2, offset: offset) ?? 0
        }
        return layout.notchCenterY(index) - offset
    }

    /// The pointer moves to `point`, in rail coordinates.
    func move(to point: NSPoint) throws {
        guard let event = NSEvent.mouseEvent(
            with: .mouseMoved, location: rail.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: host.window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 0, pressure: 0)
        else { throw RailShotError.couldNotMakeEvent(x: point.x, y: point.y) }
        rail.mouseMoved(with: event)
    }

    /// Moves the pointer onto the rail at `point` and fires the open timer:
    /// the lens exists, not yet grown.
    func open(at point: NSPoint) async throws {
        try move(to: point)
        // The hover model's timers are main-actor tasks; see the `timeout`
        // note on `EventDrivenTestClock.sleeperArmed`.
        try await clock.requireAdvanceWhenArmed(by: Self.openDelay, timeout: TestDeadlines.saturatedPass)
        await hover._drainForTesting()
        guard hover.isOpen, rail.lens != nil else {
            throw RailShotError.lensDidNotOpen(hoverOpen: hover.isOpen)
        }
    }

    /// Steps 60Hz frames until the rail wants none, then checks the lens is
    /// fully open.
    func settle() throws {
        var frames = 0
        while rail.isRunningFrames {
            guard frames < Self.maxSettleFrames else { throw RailShotError.neverSettled(frames: frames) }
            frame(after: Self.frameInterval)
            frames += 1
        }
        guard rail.lens != nil, rail.openFraction == 1 else {
            throw RailShotError.notFullyOpen(fraction: rail.openFraction)
        }
    }

    /// Steps the lens to half way through its grow, in time: 75ms of 150ms.
    func growHalfway() throws {
        // The first frame of a run counts `firstFrameInterval` whatever its
        // timestamp; the second brings the elapsed time to half the grow.
        frame(after: PromptRailLensAnimation.firstFrameInterval)
        frame(after: PromptRailLensAnimation.fullDuration / 2 - PromptRailLensAnimation.firstFrameInterval)
        let fraction = rail.openFraction
        guard rail.isRunningFrames, fraction > 0, fraction < 1 else {
            throw RailShotError.notMidGrow(fraction: fraction)
        }
    }

    /// Moves the pointer off the rail column into the box, half way across
    /// it, at `y`.
    func moveIntoBox(atY y: CGFloat) throws {
        guard let box = rail.boxRect else { throw RailShotError.noBox }
        let point = NSPoint(x: (PromptRailLayout.width + box.maxX) / 2, y: y)
        guard box.contains(point) else {
            throw RailShotError.pointOutsideBox(x: point.x, y: point.y, box: "\(box)")
        }
        try move(to: point)
    }

    /// One frame, `interval` after the last, and the container's layout after
    /// it, so the overlay's width follows `wantsOpenWidth` frame by frame.
    private func frame(after interval: TimeInterval) {
        frameTime += interval
        rail.advanceFrame(to: frameTime)
        container.needsLayout = true
        container.layoutSubtreeIfNeeded()
    }
}

// MARK: - The fake transcript

/// The transcript the lens sits over: the window background, and lines of
/// grey 13pt body text from x 28.
private final class FakeTranscriptView: NSView {
    private static let textLeading: CGFloat = 28
    private static let trailingMargin: CGFloat = 16
    private static let firstLineTop: CGFloat = 14
    private static let linePitch: CGFloat = 19

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let area = bounds
        let leading = Self.textLeading
        let top = Self.firstLineTop
        let pitch = Self.linePitch
        let width = max(0, area.width - leading - Self.trailingMargin)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: style,
        ]
        effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            area.fill()
            for (index, line) in RailShotContent.transcriptLines.enumerated() where !line.isEmpty {
                let rect = NSRect(x: leading, y: top + CGFloat(index) * pitch, width: width, height: pitch)
                (line as NSString).draw(in: rect, withAttributes: attributes)
            }
        }
    }
}

// MARK: - Content

/// The rail's prompts and the transcript's text. Generic on purpose: this
/// repository is public.
private enum RailShotContent {
    static let prompts = [
        "Fix the flaky login test",
        "Why does the build fail on CI but not locally?",
        "Add a dark mode toggle to settings",
        "Rename the user service to account service everywhere",
        "Write tests for the date parser, including leap years and time zones",
        "Can you explain what this regex does?",
        "Bump the HTTP client to the latest minor version and fix whatever breaks",
        "The search page is slow with more than a thousand results, profile it",
        "Revert the last commit",
        "Split the settings view into smaller components",
        "Add retry with backoff to the webhook sender",
        "Why is the cache returning stale entries after a deploy?",
        "Document the config file format in the README",
        "Make the sidebar collapsible",
        "Run the linter and fix the warnings",
        "Add pagination to the orders endpoint",
        "Look at the failing migration and tell me what went wrong before changing anything",
        "Decode images on a background queue",
        "Remove the unused feature flag",
        "Open a PR",
        "Add an empty state to the inbox",
        "Why does the app crash when the network drops mid-upload?",
        "Rewrite the CSV export to stream rows instead of building the whole file in memory",
        "Check that keyboard navigation works in the date picker",
        "Cut the cold start time in half if you can",
        "Address the review comments",
        "Make the error messages friendlier",
        "Squash the fixups and push",
        "Add a health check endpoint",
        "What's the difference between these two retry helpers? Can we keep one?",
    ]

    static let peerSenders = ["reviewer", "build-bot"]

    static let peerLines = [
        "Review done: two nits in the parser, otherwise ready to merge",
        "CI is green on the retry branch",
        "I'm editing the same file, hold off on the settings refactor",
        "Benchmarks attached: the new cache is about 30% faster",
    ]

    /// Tool calls per turn, cycled, so the notch lengths vary across the
    /// whole range.
    static let workPattern = [0, 3, 12, 1, 27, 6, 0, 9, 45, 2, 15, 4, 0, 21, 7, 1, 33, 5, 11, 2, 60, 8, 3, 0, 17]

    /// Minutes between consecutive prompts, cycled.
    static let gapMinutes = [3, 7, 2, 11, 5, 4, 9, 6, 14, 3]

    static let transcriptLines = [
        "I'll start by reading the test to see how the sign-in flow is set up.",
        "The test signs in, waits for the dashboard, then checks the greeting.",
        "It fails about one run in five, always on the greeting check.",
        "",
        "The session store writes the token on a background queue, so the",
        "dashboard can load before the write lands and greet a signed-out user.",
        "That fits the timing: the failure only shows when the machine is busy.",
        "",
        "Two ways to fix it:",
        "1. Wait for the token write before navigating to the dashboard.",
        "2. Have the dashboard observe the session and redraw when it changes.",
        "",
        "The first is smaller and matches what the sign-out path already does,",
        "so I'll go with that and leave the dashboard alone.",
        "",
        "Edited SessionStore.swift: the write completes before sign-in returns.",
        "Edited SignInFlowTests.swift: removed the sleep that hid the race.",
        "",
        "Running the sign-in tests 50 times in a row to check the flake is gone.",
        "50 of 50 passed. Before the change, 11 of 50 failed on this machine.",
        "",
        "Running the full suite to check nothing else relied on the old timing.",
        "All 412 tests passed.",
        "",
        "Summary: sign-in now waits for the session token to be stored before",
        "it returns, which removes the race the flaky test kept hitting. The",
        "sleep in the test is gone as well, so the suite runs two seconds faster.",
        "",
        "Want me to open a PR, or is there anything else to check first?",
        "",
    ]

    /// `count` entries: prompts, with a peer message every sixth entry.
    static func entries(_ count: Int) -> [PromptOutlineEntry] {
        let stamps = timestamps(count)
        return (0..<count).map { index -> PromptOutlineEntry in
            let kind: PromptOutlineEntry.Kind
            let line: String
            if index % 6 == 3 {
                let peer = index / 6
                kind = .peer(sender: peerSenders[peer % peerSenders.count])
                line = peerLines[peer % peerLines.count]
            } else {
                kind = .prompt
                line = prompts[index % prompts.count]
            }
            return PromptOutlineEntry(
                id: "p-\(index)", rowIndex: index * 3, kind: kind, firstLine: line, timestamp: stamps[index])
        }
    }

    static func workCounts(_ count: Int) -> [Int] {
        (0..<count).map { workPattern[$0 % workPattern.count] }
    }

    /// A prompt a little past the middle, so it lands inside or beside a lens
    /// opened at mid-rail.
    static func activeIndex(_ count: Int) -> Int? {
        count > 0 ? count * 11 / 20 : nil
    }

    /// Stamps ending at 17:30 today and running back a few minutes per entry,
    /// so a long session reaches into earlier days and the time column shows
    /// both times and dates. They follow the machine's clock, calendar and
    /// locale, as the app's do.
    static func timestamps(_ count: Int) -> [Date] {
        let end = Calendar.current.startOfDay(for: Date()).addingTimeInterval(17.5 * 3600)
        var stamps: [Date] = []
        stamps.reserveCapacity(count)
        var minutesBack = 0
        for index in stride(from: count - 1, through: 0, by: -1) {
            stamps.append(end.addingTimeInterval(-Double(minutesBack) * 60))
            minutesBack += gapMinutes[index % gapMinutes.count]
        }
        return Array(stamps.reversed())
    }
}

// MARK: - Errors

/// A shot that could not be made, named by its file so the issue says which.
private struct ShotFailure: Error, CustomStringConvertible {
    let file: String
    let cause: any Error

    var description: String { "\(file) was not written: \(cause)" }
}

/// Why a shot could not be made. Each case describes itself, so the
/// diagnostic lands on the issue's primary line.
private enum RailShotError: Error, CustomStringConvertible {
    case couldNotMakeEvent(x: CGFloat, y: CGFloat)
    case lensDidNotOpen(hoverOpen: Bool)
    case neverSettled(frames: Int)
    case notFullyOpen(fraction: CGFloat)
    case notMidGrow(fraction: CGFloat)
    case noBox
    case pointOutsideBox(x: CGFloat, y: CGFloat, box: String)
    case noHoveredRow
    case blankRender(variance: Double)

    var description: String {
        switch self {
        case let .couldNotMakeEvent(x, y):
            return "AppKit would not make a mouse-moved event at (\(x), \(y))"
        case let .lensDidNotOpen(hoverOpen):
            return hoverOpen
                ? "the hover model opened, but the rail grew no lens"
                : "the hover model did not open 80ms after the pointer reached the rail"
        case let .neverSettled(frames):
            return "the lens still wanted frames after \(frames) frames, 2s at 60Hz"
        case let .notFullyOpen(fraction):
            return "the lens settled \(fraction) open, not fully open"
        case let .notMidGrow(fraction):
            return "75ms into the grow the lens was \(fraction) open, not part way"
        case .noBox:
            return "the open lens drew no box to move the pointer into"
        case let .pointOutsideBox(x, y, box):
            return "the point (\(x), \(y)) half way across the box lies outside the box \(box)"
        case .noHoveredRow:
            return "the pointer on the box's text left no row hovered"
        case let .blankRender(variance):
            return "the capture is a flat field (luminance variance \(variance)); the rail rendered blank"
        }
    }
}
#endif
