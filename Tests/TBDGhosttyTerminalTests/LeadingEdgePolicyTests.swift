import Foundation
@testable import TBDGhosttyTerminal
import TestSupport
import Testing

/// `LeadingEdgePolicy` as a pure function: one case per rule, in the order the rules are checked,
/// and the boundaries of the rules that count or measure.
@Suite(.fastPassBounded)
struct LeadingEdgePolicyTests {
    /// Facts under which every rule holds: an idle, drawable view fed one byte, its last output
    /// frame a whole second ago.
    private static let drawable = LeadingEdgeFacts(
        canBuildFrames: true,
        isLiveResizing: false,
        now: .seconds(100),
        lastOutputFrameAt: .seconds(99),
        refreshInterval: Duration.seconds(1) / 120,
        ringHasFreeSlot: true,
        drawablesAwaitingPresent: 0,
        outputBytesSinceFrame: 1,
        holdOpen: false,
        holdEnded: false)

    /// `facts` with the rule `reason` names broken, or mended as in `drawable`.
    private static func setting(
        _ reason: LeadingEdgePolicy.Reason, broken: Bool, in facts: LeadingEdgeFacts
    ) -> LeadingEdgeFacts {
        var facts = facts
        switch reason {
        case .cannotBuildFrames: facts.canBuildFrames = !broken
        case .liveResize: facts.isLiveResizing = broken
        case .holdOpen: facts.holdOpen = broken
        case .withinRefreshInterval:
            facts.lastOutputFrameAt = facts.now - (broken ? Duration.milliseconds(2) : Duration.seconds(1))
        case .ringFull: facts.ringHasFreeSlot = !broken
        case .drawablesBehind:
            facts.drawablesAwaitingPresent = broken ? TerminalRenderer.maxDrawablesAwaitingPresent : 0
        case .noOutput: facts.outputBytesSinceFrame = broken ? 0 : 1
        case .bulkOutput: facts.outputBytesSinceFrame = broken ? 2048 : 1
        }
        return facts
    }

    @Test func smallOutputIntoAnIdleViewDrawsNow() {
        let decision = LeadingEdgePolicy.decide(Self.drawable)
        let expected: LeadingEdgePolicy.Decision = .drawNow
        #expect(decision == expected, "an idle, drawable view fed one byte answered \(decision)")
    }

    /// Each rule alone sends the frame to the display link, naming itself.
    @Test(arguments: LeadingEdgePolicy.Reason.allCases)
    func eachRuleAloneCoalescesWithItsReason(_ reason: LeadingEdgePolicy.Reason) {
        let decision = LeadingEdgePolicy.decide(Self.setting(reason, broken: true, in: Self.drawable))
        let expected: LeadingEdgePolicy.Decision = .coalesce(reason)
        #expect(decision == expected, "breaking only \(reason) answered \(decision)")
    }

    /// The rules are checked in order: with every rule broken the first is named, and mending
    /// each in turn names the next. No output and bulk output cannot both hold, so the walk breaks
    /// bulk output, and `noOutputIsCheckedAfterTheGPUAndBeforeTheSize` places the other.
    @Test func theFirstBrokenRuleIsTheReason() {
        let walked = LeadingEdgePolicy.Reason.allCases.filter { $0 != .noOutput }
        var facts = Self.drawable
        for reason in walked {
            facts = Self.setting(reason, broken: true, in: facts)
        }
        for reason in walked {
            let decision = LeadingEdgePolicy.decide(facts)
            let expected: LeadingEdgePolicy.Decision = .coalesce(reason)
            #expect(decision == expected, "with every rule from \(reason) on broken, the policy answered \(decision)")
            facts = Self.setting(reason, broken: false, in: facts)
        }
        let mended = LeadingEdgePolicy.decide(facts)
        let drawNow: LeadingEdgePolicy.Decision = .drawNow
        #expect(mended == drawNow, "with every rule mended the policy answered \(mended)")
    }

    // MARK: Rule 7, small output

    /// A delivery with no output, a resize's or a reset's, is left to the tick, even when it
    /// ended a hold: the hold's end that the program writes is output. Checked after the GPU
    /// rules, and before the size of the output.
    @Test func noOutputIsCheckedAfterTheGPUAndBeforeTheSize() {
        var facts = Self.drawable
        facts.outputBytesSinceFrame = 0
        facts.holdEnded = true
        let ended = LeadingEdgePolicy.decide(facts)
        let noOutput: LeadingEdgePolicy.Decision = .coalesce(.noOutput)
        #expect(ended == noOutput, "a delivery with no output that ended a hold answered \(ended)")

        facts.ringHasFreeSlot = false
        let ringFull = LeadingEdgePolicy.decide(facts)
        let ringFullExpected: LeadingEdgePolicy.Decision = .coalesce(.ringFull)
        #expect(ringFull == ringFullExpected, "no output with the ring full answered \(ringFull)")
    }

    @Test func exactlyTheSmallOutputLimitCoalescesAndOneByteLessDraws() {
        let limit = LeadingEdgePolicy.smallOutputLimit
        #expect(limit == 1024)
        var atLimit = Self.drawable
        atLimit.outputBytesSinceFrame = limit
        var belowLimit = Self.drawable
        belowLimit.outputBytesSinceFrame = limit - 1

        let atLimitDecision = LeadingEdgePolicy.decide(atLimit)
        let bulk: LeadingEdgePolicy.Decision = .coalesce(.bulkOutput)
        #expect(atLimitDecision == bulk, "1,024 bytes answered \(atLimitDecision)")
        let belowLimitDecision = LeadingEdgePolicy.decide(belowLimit)
        let drawNow: LeadingEdgePolicy.Decision = .drawNow
        #expect(belowLimitDecision == drawNow, "1,023 bytes answered \(belowLimitDecision)")
    }

    /// A finished hold is a complete frame, the program promised, so it draws whatever its size.
    @Test func aHoldThatEndedLetsFiftyKilobytesThrough() {
        var facts = Self.drawable
        facts.outputBytesSinceFrame = 50_000
        facts.holdEnded = true
        let decision = LeadingEdgePolicy.decide(facts)
        let expected: LeadingEdgePolicy.Decision = .drawNow
        #expect(decision == expected, "50 KB after a hold ended answered \(decision)")
    }

    /// A chunk that ends one hold and begins the next leaves a hold open. The tick would skip the
    /// frame, so the delivery leaves it to the tick.
    @Test func aHoldThatEndedAndBeganAgainCoalescesAsAnOpenHold() {
        var facts = Self.drawable
        facts.holdEnded = true
        facts.holdOpen = true
        let decision = LeadingEdgePolicy.decide(facts)
        let expected: LeadingEdgePolicy.Decision = .coalesce(.holdOpen)
        #expect(decision == expected, "a hold that ended and began again answered \(decision)")
    }

    // MARK: Rule 4, the refresh interval

    @Test func exactlyOneIntervalSinceTheLastOutputFrameDraws() {
        var facts = Self.drawable
        facts.lastOutputFrameAt = facts.now - facts.refreshInterval
        let atInterval = LeadingEdgePolicy.decide(facts)
        let drawNow: LeadingEdgePolicy.Decision = .drawNow
        #expect(atInterval == drawNow, "exactly one interval after the last output frame answered \(atInterval)")

        facts.lastOutputFrameAt = facts.now - facts.refreshInterval + .microseconds(1)
        let justInside = LeadingEdgePolicy.decide(facts)
        let within: LeadingEdgePolicy.Decision = .coalesce(.withinRefreshInterval)
        #expect(justInside == within, "a microsecond inside the interval answered \(justInside)")
    }

    @Test func noOutputFrameYetDraws() {
        var facts = Self.drawable
        facts.lastOutputFrameAt = nil
        let decision = LeadingEdgePolicy.decide(facts)
        let expected: LeadingEdgePolicy.Decision = .drawNow
        #expect(decision == expected, "a view with no output frame yet answered \(decision)")
    }

    // MARK: Rule 6, drawables

    /// Two drawables awaiting their report is the limit; one is not.
    @Test func oneDrawableAwaitingItsReportStillDraws() {
        var facts = Self.drawable
        facts.drawablesAwaitingPresent = TerminalRenderer.maxDrawablesAwaitingPresent - 1
        let decision = LeadingEdgePolicy.decide(facts)
        let expected: LeadingEdgePolicy.Decision = .drawNow
        #expect(decision == expected, "one drawable awaiting its report answered \(decision)")
    }
}

/// The refresh interval rule 4 measures against: the running link's own, else the screen's, else
/// the fallback.
@Suite(.fastPassBounded)
struct LeadingEdgeRefreshIntervalTests {
    @Test func theLinksIntervalWinsWhileItRuns() {
        let interval = LeadingEdgePolicy.refreshInterval(
            linkInterval: Duration.seconds(1) / 120, screenMinimumRefreshInterval: 1.0 / 60)
        let expected = Duration.seconds(1) / 120
        #expect(interval == expected, "a running link at 120 Hz on a 60 Hz screen gave \(interval)")
    }

    @Test func theScreensIntervalStandsInWithNoLinkInterval() {
        let interval = LeadingEdgePolicy.refreshInterval(linkInterval: nil, screenMinimumRefreshInterval: 1.0 / 120)
        let expected: Duration = .seconds(1.0 / 120)
        #expect(interval == expected, "no link interval on a 120 Hz screen gave \(interval)")
    }

    @Test func theFallbackStandsInWithNoScreen() {
        let interval = LeadingEdgePolicy.refreshInterval(linkInterval: nil, screenMinimumRefreshInterval: nil)
        let expected = LeadingEdgePolicy.fallbackRefreshInterval
        #expect(interval == expected, "no link interval and no screen gave \(interval)")
        let sixtieth = Duration.seconds(1) / 60
        #expect(expected == sixtieth, "the fallback is \(expected), not a sixtieth of a second")
    }
}

/// `DisplayLinkDriver` keeps the link's interval while it runs and forgets it when the link
/// pauses, so a resumed link uses the screen's interval until its first tick.
@Suite(.fastPassBounded)
@MainActor
struct DisplayLinkIntervalTests {
    /// Gives `driver` a reason to run: a visible surface that needs a frame.
    private static func resume(_ driver: DisplayLinkDriver) {
        driver.update {
            $0.hasVisibleSurface = true
            $0.isOccluded = false
            $0.needsUpdate = true
        }
    }

    @Test func aTickOfTheRunningLinkSetsTheIntervalAndAPauseClearsIt() {
        let driver = DisplayLinkDriver()
        Self.resume(driver)
        #expect(!driver.isPaused, "the driver did not resume for a visible surface that needs a frame")
        let none: Duration? = nil
        let beforeTick = driver.linkInterval
        #expect(beforeTick == none, "a resumed link had an interval before its first tick: \(String(describing: beforeTick))")

        let tickInterval = Duration.seconds(1) / 120
        driver.noteTick(interval: tickInterval)
        let afterTick = driver.linkInterval
        let expectedAfterTick: Duration? = tickInterval
        #expect(afterTick == expectedAfterTick, "a tick at 120 Hz left the interval at \(String(describing: afterTick))")

        driver.update { $0.needsUpdate = false }
        #expect(driver.isPaused)
        let afterPause = driver.linkInterval
        #expect(afterPause == none, "a paused link kept its interval: \(String(describing: afterPause))")

        driver.update { $0.needsUpdate = true }
        #expect(!driver.isPaused)
        let afterResume = driver.linkInterval
        #expect(afterResume == none, "a link resumed again had an interval before its first tick: \(String(describing: afterResume))")
    }

    @Test func aTickWhileTheLinkIsPausedIsIgnored() {
        let driver = DisplayLinkDriver()
        #expect(driver.isPaused)
        driver.noteTick(interval: Duration.seconds(1) / 120)
        let interval = driver.linkInterval
        let none: Duration? = nil
        #expect(interval == none, "a paused link took a tick's interval: \(String(describing: interval))")
    }

    @Test func aTickWithNoIntervalIsIgnored() {
        let driver = DisplayLinkDriver()
        Self.resume(driver)
        let sixtieth = Duration.seconds(1) / 60
        driver.noteTick(interval: sixtieth)
        driver.noteTick(interval: .zero)
        let interval = driver.linkInterval
        let expected: Duration? = sixtieth
        #expect(interval == expected, "a tick with no interval replaced the last one: \(String(describing: interval))")
    }
}
