import AppKit
import Foundation
import Testing
@testable import TBDApp
import TestSupport

// Tier 1: virtual time only. Hover is fed by hand; no window, no tracking area.

/// `PromptRailHoverModel` against `EventDrivenTestClock`: the 80ms open, the
/// 100ms grace, suppression after Escape but not after a click off the rail,
/// and the close on app deactivation.
///
/// Every model takes its default delays, so the suite pins the shipped
/// timings. A timer that should fire goes through `fire(_:by:_:)`, which joins
/// the task it woke. A timer that must not exist is ruled out with
/// `watchForSleeper`, and the test then advances and drains anyway, so a timer
/// that did arm also fires and shows up as a state change.
@MainActor
@Suite("Prompt rail hover model", .clockDriven)
struct PromptRailHoverModelTests {
    /// The timers are main-actor tasks, so they arm only once they have had a
    /// turn on the main actor; see the `timeout` note on
    /// `EventDrivenTestClock.sleeperArmed`.
    private static let mainActorHop = TestDeadlines.saturatedPass
    private static let openDelay = Duration.milliseconds(80)
    private static let closeGrace = Duration.milliseconds(100)

    private static func makeModel(
        _ clock: EventDrivenTestClock,
        center: NotificationCenter = NotificationCenter()
    ) -> PromptRailHoverModel {
        PromptRailHoverModel(notificationCenter: center, clock: clock)
    }

    /// Waits for the model's timer to arm, advances by `duration`, and joins
    /// the task it woke. The `#require` turns a timer longer than `duration`
    /// into a failure here, instead of a drain that waits on a sleeper nobody
    /// will advance.
    private static func fire(
        _ clock: EventDrivenTestClock,
        by duration: Duration,
        _ model: PromptRailHoverModel
    ) async throws {
        try await clock.requireAdvanceWhenArmed(by: duration, timeout: mainActorHop)
        try #require(!clock.hasSleeper, "the timer outlasted the advance")
        await model._drainForTesting()
    }

    /// Hovers the rail and fires the open timer, leaving the card open with
    /// the pointer on the rail.
    private static func openCard(_ model: PromptRailHoverModel, _ clock: EventDrivenTestClock) async throws {
        model.railHoverChanged(true)
        try await fire(clock, by: openDelay, model)
        try #require(model.isOpen)
    }

    /// Expects no timer to arm, then advances by `duration` and drains.
    private static func expectNoTimer(
        _ clock: EventDrivenTestClock,
        by duration: Duration,
        _ model: PromptRailHoverModel,
        _ comment: Comment,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        #expect(await watchForSleeper(on: clock) == false, comment, sourceLocation: sourceLocation)
        await clock.advance(by: duration)
        await model._drainForTesting()
    }

    /// Delivers the notification and lets the observer's `queue: .main` hop
    /// run. Posting from the main thread runs it inline; the yields cover a
    /// center that enqueues it instead.
    private static func postDeactivation(to center: NotificationCenter) async {
        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        for _ in 0..<10 { await Task.yield() }
    }

    @Test("the card opens 80ms after the pointer enters the rail")
    func opensAfterDelay() async throws {
        let clock = EventDrivenTestClock()
        let model = Self.makeModel(clock)
        model.railHoverChanged(true)

        try await clock.requireAdvanceWhenArmed(by: .milliseconds(79), timeout: Self.mainActorHop)
        #expect(clock.hasSleeper, "the open timer fired before 80ms")
        #expect(!model.isOpen)

        await clock.advance(by: .milliseconds(1))
        try #require(!clock.hasSleeper, "the open timer outlasted 80ms")
        await model._drainForTesting()
        #expect(model.isOpen)
    }

    @Test("a hover that ends before the delay never opens the card")
    func briefHoverNeverOpens() async {
        let clock = EventDrivenTestClock()
        let model = Self.makeModel(clock)

        model.railHoverChanged(true)
        model.railHoverChanged(false)
        await Self.expectNoTimer(clock, by: Self.openDelay, model, "a hover that ended left the open timer running")
        #expect(!model.isOpen)
    }

    @Test("the card closes 100ms after the pointer leaves")
    func closesAfterGrace() async throws {
        let clock = EventDrivenTestClock()
        let model = Self.makeModel(clock)
        try await Self.openCard(model, clock)

        model.railHoverChanged(false)
        try await clock.requireAdvanceWhenArmed(by: .milliseconds(99), timeout: Self.mainActorHop)
        #expect(clock.hasSleeper, "the close grace ended before 100ms")
        #expect(model.isOpen)

        await clock.advance(by: .milliseconds(1))
        try #require(!clock.hasSleeper, "the close grace outlasted 100ms")
        await model._drainForTesting()
        #expect(!model.isOpen)
    }

    @Test("reaching the card within the grace keeps it open")
    func cardHoverWithinGraceKeepsOpen() async throws {
        let clock = EventDrivenTestClock()
        let model = Self.makeModel(clock)
        try await Self.openCard(model, clock)

        // The pointer leaves the rail and is on its way to the card: the close
        // timer is running when it arrives.
        model.railHoverChanged(false)
        try await clock.requireAdvanceWhenArmed(by: .milliseconds(50), timeout: Self.mainActorHop)
        model.cardHoverChanged(true)
        // Cancelling a sleep removes it from the ledger synchronously.
        #expect(!clock.hasSleeper, "reaching the card left the close timer running")

        await clock.advance(by: .milliseconds(50))
        await model._drainForTesting()
        #expect(model.isOpen)
    }

    @Test("after Escape the card stays shut until the pointer leaves the rail")
    func escapeSuppressesUntilRailExit() async throws {
        let clock = EventDrivenTestClock()
        let model = Self.makeModel(clock)
        try await Self.openCard(model, clock)

        model.dismiss(.escape)
        #expect(!model.isOpen, "Escape closes the card at once")

        // The pointer is still on the rail, and the rail reports it again.
        model.railHoverChanged(true)
        await Self.expectNoTimer(clock, by: Self.openDelay, model, "the card rearmed while the pointer stayed on the rail")
        #expect(!model.isOpen)

        model.railHoverChanged(false)
        model.railHoverChanged(true)
        try await Self.fire(clock, by: Self.openDelay, model)
        #expect(model.isOpen, "leaving the rail and coming back reopens the card")
    }

    @Test("a row click off the rail does not hold the card shut")
    func clickOffRailDoesNotSuppress() async throws {
        let clock = EventDrivenTestClock()
        let model = Self.makeModel(clock)
        try await Self.openCard(model, clock)

        model.railHoverChanged(false)
        model.cardHoverChanged(true)
        model.dismiss(.click)
        #expect(!model.isOpen, "a row click closes the card at once")

        model.railHoverChanged(true)
        try await Self.fire(clock, by: Self.openDelay, model)
        #expect(model.isOpen)
    }

    @Test("the app resigning active closes the card with the pointer still on the rail")
    func appDeactivationCloses() async throws {
        let clock = EventDrivenTestClock()
        let center = NotificationCenter()
        let model = Self.makeModel(clock, center: center)
        try await Self.openCard(model, clock)

        // The pointer stays on the rail: no exit event will come.
        await Self.postDeactivation(to: center)
        #expect(!model.isOpen)

        // The hover state went with it. A stray hover event must not reopen
        // the card from a rail flag that no exit event will ever clear.
        model.cardHoverChanged(false)
        await Self.expectNoTimer(clock, by: Self.openDelay, model, "a stale rail flag rearmed the card after deactivation")
        #expect(!model.isOpen)
    }

    @Test("onOpenChange reports transitions only")
    func onOpenChangeFiresOnTransitionsOnly() async throws {
        let clock = EventDrivenTestClock()
        let model = Self.makeModel(clock)
        let changes = FireRecorder<Bool>()
        model.onOpenChange = { changes.record($0) }

        try await Self.openCard(model, clock)
        model.railHoverChanged(true)
        model.cardHoverChanged(true)
        model.cardHoverChanged(false)
        #expect(changes.values == [true], "a hover that changed nothing was reported")

        model.railHoverChanged(false)
        try await Self.fire(clock, by: Self.closeGrace, model)
        model.closeNow()
        model.dismiss(.escape)
        #expect(changes.values == [true, false])
    }
}

/// `PromptRailEscapeMonitor` over a fake monitor table: Escape is consumed
/// and reported, other keys pass through, and at most one monitor is ever
/// installed.
@MainActor
@Suite("Prompt rail Escape monitor")
struct PromptRailEscapeMonitorTests {
    /// AppKit's monitor table, faked: `install` keeps the handler under a
    /// fresh token, `remove` records the token it was handed.
    @MainActor
    private final class FakeMonitorTable {
        private(set) var installed: [(token: NSObject, handler: (NSEvent) -> NSEvent?)] = []
        let removed = FireRecorder<ObjectIdentifier>()

        /// Handlers whose tokens have not been removed.
        var live: [(NSEvent) -> NSEvent?] {
            let gone = Set(removed.values)
            return installed.filter { !gone.contains(ObjectIdentifier($0.token)) }.map { $0.handler }
        }

        func makeMonitor() -> PromptRailEscapeMonitor {
            let removals = self.removed
            return PromptRailEscapeMonitor(
                install: { [self] handler in
                    let token = NSObject()
                    installed.append((token: token, handler: handler))
                    return token
                },
                remove: { removals.record(ObjectIdentifier($0 as AnyObject)) }
            )
        }
    }

    private static func keyDown(_ keyCode: UInt16, _ characters: String) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        ))
    }

    @Test("Escape reaches onEscape and is consumed; other keys pass through")
    func escapeIsConsumed() throws {
        let table = FakeMonitorTable()
        let monitor = table.makeMonitor()
        let escapes = FireRecorder<Bool>()
        monitor.start { escapes.record(true) }
        defer { monitor.stop() }
        let handler = try #require(table.live.first)

        let other = try Self.keyDown(0, "a")
        #expect(handler(other) === other, "a key other than Escape was swallowed")
        #expect(escapes.values.isEmpty)

        let escape = try Self.keyDown(PromptRailEscapeMonitor.escapeKeyCode, "\u{1B}")
        #expect(handler(escape) == nil, "Escape was dispatched on to the app")
        #expect(escapes.values == [true])
    }

    @Test("starting again replaces the monitor, and stop removes it once")
    func restartReplacesTheMonitor() {
        let table = FakeMonitorTable()
        let monitor = table.makeMonitor()
        monitor.start {}
        monitor.start {}
        #expect(table.installed.count == 2)
        #expect(table.live.count == 1, "a second start left two monitors consuming Escape")

        monitor.stop()
        #expect(table.live.isEmpty)
        monitor.stop()
        #expect(table.removed.values.count == 2, "a second stop removed a monitor again")
    }

    @Test("a monitor still installed is removed when its owner lets go")
    func deinitRemovesTheMonitor() {
        let table = FakeMonitorTable()
        var monitor: PromptRailEscapeMonitor? = table.makeMonitor()
        monitor?.start {}
        #expect(table.live.count == 1)

        monitor = nil
        #expect(table.live.isEmpty, "a released monitor kept consuming Escape")
    }
}
