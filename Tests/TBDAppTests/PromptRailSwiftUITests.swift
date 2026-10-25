import AppKit
import Observation
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

// Tier 1 apart from the hosted cases, which mount a real offscreen window.
// Hover is fed to the model, or to `PromptRailPointer`, by hand — an offscreen
// window receives no pointer events — and the open timer runs on
// `EventDrivenTestClock`.

/// The SwiftUI prompt rail renderer: the rail beside the table, a pane that
/// is not rebuilt by active-prompt changes, the card's size, rows and
/// in-place updates, its Escape monitor and key-window close, rail hover
/// taken from the rail column's geometry, and the overflow offset.
@MainActor
@Suite("Prompt rail SwiftUI renderer", .clockDriven)
struct PromptRailSwiftUITests {
    /// The open timer is a main-actor task; see the `timeout` note on
    /// `EventDrivenTestClock.sleeperArmed`.
    private static let mainActorHop = TestDeadlines.saturatedPass
    private static let openDelay = Duration.milliseconds(80)

    // MARK: Rail and pane

    @Test("the SwiftUI renderer draws a 40-prompt transcript with the 20pt rail beside the table")
    func rendersWithEntries() async throws {
        let suiteName = "prompt-rail-swiftui-render-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(PromptRailRenderer.swiftUI.rawValue, forKey: AppState.promptRailRendererKey)
        let appState = AppState(userDefaults: defaults)
        let probe = MountProbe()
        let nodes = transcriptRenderNodes(
            from: PromptRailFixtures.conversation(prompts: 40, replySentences: { _ in 2 }))
        let root = PromptRailContainer { mount in
            let _ = probe.record(mount)
            TableTranscriptView(
                context: TranscriptCardContext(
                    terminalID: nil,
                    openTranscriptOverlay: nil,
                    appState: appState,
                    linkResolver: nil,
                    onLinkClicked: nil),
                atBottom: .constant(true),
                scrollToBottomToken: 0,
                activityToggleToken: 0,
                linkRoot: "",
                nodesProvider: { nodes },
                promptRail: mount)
        }
        .defaultAppStorage(defaults)
        let host = OffscreenHost(root: AnyView(root), size: NSSize(width: 680, height: 600))
        defer { host.tearDown() }

        let delivered = await host.settle { probe.state?.entries.count == 40 }
        try #require(delivered, "the rail's state never received the outline (entries: \(probe.state?.entries.count ?? -1))")
        await host.pump(times: 5)
        let container = try #require(host.firstDescendant(TranscriptContainerView.self))

        // The rail takes its 20pt column ahead of the table, which keeps no
        // gutter of its own.
        #expect(host.flippedWindowFrame(container).minX == PromptRailLayout.width)
        #expect(host.flippedWindowFrame(container).width == 680 - PromptRailLayout.width)
        #expect(container.leadingGutter == 0)
        #expect(host.hostingView.fittingSize.width >= PromptRailLayout.width)
    }

    /// A pane body that read the state would re-run its content — the table's
    /// `updateNSView` and its whole-transcript comparison — on every
    /// active-prompt change, in the middle of a scroll.
    @Test("an active-prompt change re-renders the rail, never the pane's content")
    func paneDoesNotReadState() async throws {
        let probe = MountProbe()
        let seen = ActiveLog()
        let mounted = try await Self.mount(
            hover: Self.makeHover(EventDrivenTestClock()), escape: EscapeTable(), probe: probe, activeLog: seen)
        defer { mounted.tearDown() }
        try await Self.deliver(Self.entries(40), to: mounted)
        await mounted.host.pump(times: 5)
        let baseline = probe.invocations
        try #require(baseline > 0, "the content closure never ran")

        for index in 0..<10 {
            mounted.state.promptRail(activeIndexDidChange: index)
            // The positive control: a view that does read the state re-renders.
            let applied = await mounted.host.settle { seen.values.last == index }
            try #require(applied, "a reader of the state never saw active index \(index) (saw \(seen.values))")
        }
        #expect(probe.invocations == baseline,
                "the pane's content ran \(probe.invocations - baseline) more times across 10 active-prompt changes")
    }

    @Test("the rail's offset keeps an overflowing active notch in view, and a pointer maps through it")
    func railOffsetAndPointedIndex() {
        let hover = Self.makeHover(EventDrivenTestClock())
        defer { hover.closeNow() }
        let pointer = PromptRailPointer()
        pointer.railLaidOut(height: 600, count: 300, active: 299)
        // 300 notches at the 4pt floor: 12 + 1200 + 12 = 1224pt of content in
        // a 600pt rail, so the offset is clamped to its 624pt maximum.
        #expect(pointer.offset == 624)
        let range = PromptRailSwiftUIView.visibleRange(
            layout: PromptRailLayout(count: 300, railHeight: 600), offset: pointer.offset)
        #expect(range == 152...299)
        #expect(PromptRailSwiftUIView.visibleRange(layout: PromptRailLayout(count: 0, railHeight: 600), offset: 0) == nil)

        pointer.windowKeyChanged(true, hover: hover)
        pointer.pointerMoved(to: CGPoint(x: 10, y: 300), count: 300, hover: hover)
        // (300 + 624 − 12) / 4 = 228.
        #expect(pointer.pointedIndex == 228)
        #expect(pointer.pointerY == 300)

        pointer.outlineChanged(count: 10, active: 9)
        #expect(pointer.offset == 0)

        // A rail not yet laid out keeps no offset into its first layout.
        let unlaid = PromptRailPointer()
        unlaid.outlineChanged(count: 300, active: 299)
        #expect(unlaid.offset == 0)
    }

    // MARK: Rail hover

    /// SwiftUI hover follows hit-testing: a handler on the rail itself would
    /// hear the pointer leave once the open card covered the rail, so Escape
    /// would lift its own suppression and the card would come back 80ms
    /// later. Rail hover is the column's geometry instead.
    @Test("the pointer over the rail column under the open card keeps the rail hovered, so Escape does not reopen it")
    func escapeUnderCardDoesNotReopen() async throws {
        let clock = EventDrivenTestClock()
        let hover = Self.makeHover(clock)
        let pointer = PromptRailPointer()
        pointer.windowKeyChanged(true, hover: hover)
        pointer.railLaidOut(height: 600, count: 5, active: nil)

        pointer.pointerMoved(to: CGPoint(x: 10, y: 50), count: 5, hover: hover)
        // Five notches at the 8pt pitch from 12pt down: y 50 is notch 4.
        #expect(pointer.pointedIndex == 4)
        try await Self.fire(clock, by: Self.openDelay, hover)
        try #require(hover.isOpen)

        // The card now covers the rail; the pointer moves over its dash
        // column, which is still the rail's column.
        pointer.pointerMoved(to: CGPoint(x: 12, y: 30), count: 5, hover: hover)
        #expect(pointer.pointedIndex == 2)
        hover.dismiss(.escape)
        #expect(!hover.isOpen)

        // Moves keep arriving over the column as the card goes.
        pointer.pointerMoved(to: CGPoint(x: 12, y: 32), count: 5, hover: hover)
        await Self.expectNoTimer(clock, by: Self.openDelay, hover, "the card rearmed under a pointer still on the rail")
        #expect(!hover.isOpen, "the card reopened after Escape with the pointer on the rail")

        // Leaving the column lifts the suppression; coming back reopens.
        pointer.pointerMoved(to: CGPoint(x: 200, y: 32), count: 5, hover: hover)
        #expect(pointer.pointedIndex == nil)
        pointer.pointerMoved(to: CGPoint(x: 12, y: 32), count: 5, hover: hover)
        try await Self.fire(clock, by: Self.openDelay, hover)
        #expect(hover.isOpen, "leaving the rail and coming back did not reopen the card")
    }

    @Test("rail hover counts only in the key window, and losing key closes the card")
    func windowKeyGatesRailHover() async throws {
        let clock = EventDrivenTestClock()
        let hover = Self.makeHover(clock)
        let pointer = PromptRailPointer()
        pointer.railLaidOut(height: 600, count: 5, active: nil)

        pointer.pointerMoved(to: CGPoint(x: 10, y: 50), count: 5, hover: hover)
        #expect(pointer.pointedIndex == nil)
        await Self.expectNoTimer(clock, by: Self.openDelay, hover, "a rail in a window that is not key armed the card")
        #expect(!hover.isOpen)

        pointer.windowKeyChanged(true, hover: hover)
        pointer.pointerMoved(to: CGPoint(x: 10, y: 50), count: 5, hover: hover)
        try await Self.fire(clock, by: Self.openDelay, hover)
        #expect(hover.isOpen, "a rail in the key window did not open the card")

        pointer.windowKeyChanged(false, hover: hover)
        #expect(!hover.isOpen, "the card stayed open in a window that is no longer key")
        #expect(pointer.pointedIndex == nil)
    }

    // MARK: Card

    @Test("a new prompt while the card is open keeps the card on screen")
    func entriesChangeWhileOpenKeepsCard() async throws {
        let clock = EventDrivenTestClock()
        let hover = Self.makeHover(clock)
        let escape = EscapeTable()
        let mounted = try await Self.mount(hover: hover, escape: escape)
        defer { mounted.tearDown() }
        try await Self.deliver(Self.entries(5), to: mounted)
        try await Self.openCard(hover, clock)
        let shown = await mounted.host.settle { escape.live == 1 }
        try #require(shown, "the open card never came on screen (Escape monitors live: \(escape.live))")

        try await Self.deliver(Self.entries(6), to: mounted)
        await mounted.host.pump(times: 10)
        #expect(hover.isOpen)
        #expect(escape.live == 1, "the card left the screen when a prompt arrived")
        // The monitor follows what is on screen: one install means the card
        // never left and came back.
        #expect(escape.installs == 1, "the card was taken down and rebuilt when a prompt arrived")
    }

    @Test("the card is 320pt wide, capped at the pane's width minus 24pt, and at most the rail's height")
    func cardWidthCaps() async throws {
        #expect(PromptRailCardView.width(paneWidth: 300) == 276)
        #expect(PromptRailCardView.width(paneWidth: 700) == 320)

        let state = PromptRailState()
        state.promptRail(entriesDidChange: Self.entries(5))
        await drainMainQueue()
        try #require(state.entries.count == 5)
        let hover = Self.makeHover(EventDrivenTestClock())

        let narrow = NSHostingView(rootView: PromptRailCardView(
            state: state, hover: hover, pointedIndex: nil, earlier: nil, maxWidth: 300, maxHeight: 600))
        // Five 22pt rows inside 6pt of padding above and below.
        #expect(narrow.fittingSize == CGSize(width: 276, height: 122))

        let wide = NSHostingView(rootView: PromptRailCardView(
            state: state, hover: hover, pointedIndex: nil, earlier: nil, maxWidth: 700, maxHeight: 600))
        #expect(wide.fittingSize.width == 320)

        state.promptRail(entriesDidChange: Self.entries(40))
        await drainMainQueue()
        let short = NSHostingView(rootView: PromptRailCardView(
            state: state, hover: hover, pointedIndex: nil, earlier: nil, maxWidth: 700, maxHeight: 300))
        #expect(short.fittingSize.height == 300)
    }

    @Test("with earlier history unloaded the card's first row is the earlier row, and opening the card loads nothing")
    func cardShowsEarlierRowWithoutLoading() async throws {
        let rows = PromptRailCardView.rows(entries: Self.entries(5), showsEarlierRow: true)
        #expect(rows.count == 6)
        #expect(rows.first?.id == .earlier)
        #expect(rows.first?.entryIndex == nil)
        // Row 0 is the earlier row, so row 2 is the second prompt.
        #expect(rows[2].entryIndex == 1)
        #expect(rows[2].id == .entry("p-1"))
        #expect(PromptRailCardView.rows(entries: Self.entries(5), showsEarlierRow: false).first?.id == .entry("p-0"))
        // The earlier row alone is a row to show.
        let earlierOnly = PromptRailEarlierHistory(hasEarlier: true, load: {})
        #expect(PromptRailCardOverlay.isShown(isOpen: true, entryCount: 0, earlier: earlierOnly))
        #expect(!PromptRailCardOverlay.isShown(isOpen: true, entryCount: 0, earlier: nil))

        let clock = EventDrivenTestClock()
        let hover = Self.makeHover(clock)
        let escape = EscapeTable()
        let loads = LoadCounter()
        let earlier = PromptRailEarlierHistory(hasEarlier: true, load: { loads.count += 1 })
        let mounted = try await Self.mount(hover: hover, escape: escape, earlier: earlier)
        defer { mounted.tearDown() }
        try await Self.deliver(Self.entries(5), to: mounted)
        try await Self.openCard(hover, clock)
        let shown = await mounted.host.settle { escape.live == 1 }
        try #require(shown, "the open card never came on screen")
        await mounted.host.pump(times: 10)
        #expect(loads.count == 0, "opening the card loaded earlier history")
    }

    @Test("a row click jumps to its prompt and closes the card at once")
    func rowClickJumpsAndCloses() async throws {
        let clock = EventDrivenTestClock()
        let hover = Self.makeHover(clock)
        let state = PromptRailState()
        let jumps = JumpRecorder()
        state.onJump = { jumps.ids.append($0) }
        try await Self.openCard(hover, clock)

        PromptRailCardView.activate("p-1", state: state, hover: hover)
        #expect(jumps.ids == ["p-1"])
        #expect(!hover.isOpen)
    }

    @Test("opening puts the pointed row under the pointer")
    func openScrollsPointedRowUnderPointer() {
        // Row 50's centre is 6 + 50 × 22 + 11 = 1117pt down the list.
        #expect(PromptRailCardView.openOffset(row: 50, under: 200, rowCount: 100, cardHeight: 600) == 917)
        // Near the top the list cannot scroll above its first row.
        #expect(PromptRailCardView.openOffset(row: 1, under: 500, rowCount: 100, cardHeight: 600) == 0)
        // Near the bottom it cannot scroll past its last: 2212pt of list in a
        // 600pt card ends at 1612.
        #expect(PromptRailCardView.openOffset(row: 99, under: 10, rowCount: 100, cardHeight: 600) == 1612)
    }

    // MARK: Escape and closing

    /// The rail reports hover with no prompts too, so the hover model can
    /// open a card that has no rows. Nothing is on screen, so nothing may take
    /// Escape: the local monitor would swallow it for every view in the
    /// window, a terminal's interrupt included.
    @Test("an open card with no rows takes no Escape until a row puts it on screen")
    func emptyCardTakesNoEscape() async throws {
        let clock = EventDrivenTestClock()
        let hover = Self.makeHover(clock)
        let escape = EscapeTable()
        let mounted = try await Self.mount(hover: hover, escape: escape)
        defer { mounted.tearDown() }

        try await Self.openCard(hover, clock)
        await mounted.host.pump(times: 10)
        #expect(escape.installs == 0, "a card with no rows installed the Escape monitor")

        try await Self.deliver(Self.entries(1), to: mounted)
        let shown = await mounted.host.settle { escape.live == 1 }
        #expect(shown, "the open card did not take Escape once its first row arrived")

        try await Self.deliver([], to: mounted)
        let hidden = await mounted.host.settle { escape.live == 0 }
        #expect(hidden, "the Escape monitor outlived the card's last row")
        #expect(hover.isOpen)

        hover.closeNow()
        await mounted.host.pump(times: 5)
        #expect(escape.installs == 1)
        #expect(escape.live == 0)
    }

    @Test("the window no longer being key closes the card and stops Escape")
    func resignKeyClosesCard() async throws {
        let clock = EventDrivenTestClock()
        let hover = Self.makeHover(clock)
        let escape = EscapeTable()
        let window = WindowBox()
        let mounted = try await Self.mount(hover: hover, escape: escape, window: window)
        defer { mounted.tearDown() }
        try await Self.deliver(Self.entries(5), to: mounted)
        try await Self.openCard(hover, clock)
        let shown = await mounted.host.settle { escape.live == 1 }
        try #require(shown, "the open card never came on screen")

        window.isActive = false
        let closed = await mounted.host.settle { !hover.isOpen && escape.live == 0 }
        #expect(closed, "the card stayed open, or kept Escape, in a window that is no longer key")
    }

    @Test("the renderer leaving the screen closes the card and stops Escape")
    func teardownClosesCard() async throws {
        let clock = EventDrivenTestClock()
        let hover = Self.makeHover(clock)
        let escape = EscapeTable()
        let window = WindowBox()
        let mounted = try await Self.mount(hover: hover, escape: escape, window: window)
        defer { mounted.tearDown() }
        try await Self.deliver(Self.entries(5), to: mounted)
        try await Self.openCard(hover, clock)
        let shown = await mounted.host.settle { escape.live == 1 }
        try #require(shown, "the open card never came on screen")

        window.isMounted = false
        let closed = await mounted.host.settle { !hover.isOpen && escape.live == 0 }
        #expect(closed, "the card outlived its pane (open: \(hover.isOpen), Escape monitors live: \(escape.live))")
    }

    // MARK: Helpers

    private static func entries(_ count: Int) -> [PromptOutlineEntry] {
        (0..<count).map { index in
            PromptOutlineEntry(
                id: "p-\(index)", rowIndex: index * 2, kind: .prompt,
                firstLine: "Prompt \(index)", tooltip: "Prompt \(index)", timestamp: nil)
        }
    }

    private static func makeHover(_ clock: EventDrivenTestClock) -> PromptRailHoverModel {
        PromptRailHoverModel(notificationCenter: NotificationCenter(), clock: clock)
    }

    /// Waits for the model's timer to arm, advances by `duration`, and joins
    /// the task it woke.
    private static func fire(
        _ clock: EventDrivenTestClock, by duration: Duration, _ hover: PromptRailHoverModel
    ) async throws {
        try await clock.requireAdvanceWhenArmed(by: duration, timeout: mainActorHop)
        try #require(!clock.hasSleeper, "the timer outlasted the advance")
        await hover._drainForTesting()
    }

    /// Hovers the rail and fires the open timer.
    private static func openCard(_ hover: PromptRailHoverModel, _ clock: EventDrivenTestClock) async throws {
        hover.railHoverChanged(true)
        try await fire(clock, by: openDelay, hover)
        try #require(hover.isOpen, "the hover model did not open")
    }

    /// Expects no timer to arm, then advances by `duration` and drains, so a
    /// timer that did arm also fires and shows up as a state change.
    private static func expectNoTimer(
        _ clock: EventDrivenTestClock,
        by duration: Duration,
        _ hover: PromptRailHoverModel,
        _ comment: Comment,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        #expect(await watchForSleeper(on: clock) == false, comment, sourceLocation: sourceLocation)
        await clock.advance(by: duration)
        await hover._drainForTesting()
    }

    private struct Mounted {
        let host: OffscreenHost<AnyView>
        let state: PromptRailState
        let defaults: UserDefaults
        let suiteName: String

        func tearDown() {
            host.tearDown()
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    /// A 680×600 `PromptRailContainer` on the SwiftUI renderer in an offscreen
    /// window, with the test's hover model and Escape table, its content a
    /// probe that hands back the container's state.
    private static func mount(
        hover: PromptRailHoverModel,
        escape: EscapeTable,
        window: WindowBox = WindowBox(),
        earlier: PromptRailEarlierHistory? = nil,
        probe: MountProbe = MountProbe(),
        activeLog: ActiveLog? = nil
    ) async throws -> Mounted {
        let suiteName = "prompt-rail-swiftui-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(PromptRailRenderer.swiftUI.rawValue, forKey: AppState.promptRailRendererKey)
        let root = SwiftUIHarness(
            window: window, defaults: defaults, hover: hover, escape: escape.makeMonitor(),
            earlier: earlier, probe: probe, activeLog: activeLog)
        let host = OffscreenHost(root: AnyView(root), size: NSSize(width: 680, height: 600))
        let mounted = await host.settle { probe.state != nil }
        guard mounted, let state = probe.state else {
            host.tearDown()
            defaults.removePersistentDomain(forName: suiteName)
            Issue.record("the container never mounted the SwiftUI renderer")
            throw MountFailure()
        }
        return Mounted(host: host, state: state, defaults: defaults, suiteName: suiteName)
    }

    /// Hands the container's state an outline and waits for it to apply.
    private static func deliver(_ entries: [PromptOutlineEntry], to mounted: Mounted) async throws {
        mounted.state.promptRail(entriesDidChange: entries)
        let applied = await mounted.host.settle { mounted.state.entries == entries }
        try #require(applied, "the state never applied \(entries.count) entries")
    }
}

private struct MountFailure: Error {}

/// The window the harness puts the container in, as a test drives it: whether
/// it is key, and whether the container is on screen at all.
@MainActor
@Observable
private final class WindowBox {
    var isActive = true
    var isMounted = true
}

/// A pane-shaped body: the container on the renderer `defaults` names, with
/// the test's seams, in a window whose key state `window` sets.
private struct SwiftUIHarness: View {
    let window: WindowBox
    let defaults: UserDefaults
    let hover: PromptRailHoverModel
    let escape: PromptRailEscapeMonitor
    let earlier: PromptRailEarlierHistory?
    let probe: MountProbe
    let activeLog: ActiveLog?

    var body: some View {
        let probe = self.probe
        let activeLog = self.activeLog
        Group {
            if window.isMounted {
                PromptRailContainer(earlier: earlier, hover: hover, escapeMonitor: escape) { mount in
                    let _ = probe.record(mount)
                    if let activeLog {
                        ActiveIndexProbe(mount: mount, log: activeLog)
                    } else {
                        Color.clear
                    }
                }
            }
        }
        .environment(\.appearsActive, window.isActive)
        .defaultAppStorage(defaults)
    }
}

/// Counts the container's content invocations and keeps the state its mount
/// carries.
@MainActor
private final class MountProbe {
    private(set) var state: PromptRailState?
    private(set) var invocations = 0

    @discardableResult
    func record(_ mount: PromptRailMount) -> Int {
        invocations += 1
        if case .swiftUI(let state) = mount { self.state = state }
        return invocations
    }
}

/// The active index each body evaluation of `ActiveIndexProbe` read.
@MainActor
private final class ActiveLog {
    private(set) var values: [Int?] = []

    @discardableResult
    func record(_ value: Int?) -> Int {
        values.append(value)
        return values.count
    }
}

/// Pane content that does read the state: it re-renders on every
/// active-prompt change, which the container itself must not.
private struct ActiveIndexProbe: View {
    let mount: PromptRailMount
    let log: ActiveLog

    private var state: PromptRailState? {
        if case .swiftUI(let state) = mount { return state }
        return nil
    }

    var body: some View {
        let _ = log.record(state?.activeIndex)
        Color.clear
    }
}

@MainActor
private final class JumpRecorder {
    var ids: [String] = []
}

@MainActor
private final class LoadCounter {
    var count = 0
}

/// AppKit's monitor table, faked: counts installs and removals, so a test can
/// ask whether the Escape monitor is running.
@MainActor
private final class EscapeTable {
    private(set) var installs = 0
    private let removals = FireRecorder<Int>()

    /// Monitors installed and not yet removed.
    var live: Int { installs - removals.values.count }

    func makeMonitor() -> PromptRailEscapeMonitor {
        let removals = self.removals
        return PromptRailEscapeMonitor(
            install: { [self] _ in
                installs += 1
                return NSObject()
            },
            remove: { _ in removals.record(1) })
    }
}
