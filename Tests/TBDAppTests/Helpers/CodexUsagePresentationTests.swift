import Foundation
import Testing
import TBDShared
@testable import TBDApp

/// The worktree picker's Codex bars: a window whose reset has passed draws as
/// a fresh one, 0% and when it reset; an open one draws its reading.
@Suite("CodexUsagePresentation")
struct CodexUsagePresentationTests {
    private typealias Window = CodexUsagePresentation.Window

    /// 2027-01-15 08:00 UTC.
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let utc = TimeZone(identifier: "UTC")!

    private func codexWindow(usedPercent: Int, resetsIn: TimeInterval?) -> CodexRateLimitWindow {
        CodexRateLimitWindow(
            usedPercent: usedPercent, windowDurationMins: 300,
            resetsAt: resetsIn.map { Int(Self.now.timeIntervalSince1970 + $0) })
    }

    private func presentation(_ window: CodexRateLimitWindow) -> Window {
        CodexUsagePresentation.window(window, now: Self.now, timeZone: Self.utc)
    }

    @Test func endedWindowDrawsZeroAndWhenItReset() {
        #expect(presentation(codexWindow(usedPercent: 87, resetsIn: -2 * 3600))
                == Window(percent: 0, resetLabel: "reset 2h ago", windowEnded: true))
        #expect(presentation(codexWindow(usedPercent: 87, resetsIn: 0))
                == Window(percent: 0, resetLabel: "reset just now", windowEnded: true))
        #expect(presentation(codexWindow(usedPercent: 100, resetsIn: -3 * 86_400))
                == Window(percent: 0, resetLabel: "reset 3d ago", windowEnded: true))
    }

    @Test func openWindowDrawsItsPercentAndResetTime() {
        let resetDate = Self.now.addingTimeInterval(3 * 3600)
        let time = resetDate.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened, timeZone: Self.utc))
        #expect(presentation(codexWindow(usedPercent: 87, resetsIn: 3 * 3600))
                == Window(percent: 87, resetLabel: "at \(time)", windowEnded: false))
    }

    @Test func windowWithoutResetTimeDrawsItsPercent() {
        #expect(presentation(codexWindow(usedPercent: 42, resetsIn: nil))
                == Window(percent: 42, resetLabel: "", windowEnded: false))
    }
}

/// When the Codex row shows "Limit reached" over its bars: a window's limit
/// until every window it has has reset, spend control and other limit types
/// whatever the windows say.
@Suite("CodexUsagePresentation.showsLimitReached")
struct CodexLimitReachedLabelTests {
    /// 2027-01-15 08:00 UTC.
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func window(resetsIn: TimeInterval?) -> CodexRateLimitWindow {
        CodexRateLimitWindow(
            usedPercent: 100, windowDurationMins: 300,
            resetsAt: resetsIn.map { Int(now.timeIntervalSince1970 + $0) })
    }

    private static let ended = window(resetsIn: -2 * 3600)
    private static let open = window(resetsIn: 3 * 3600)
    private static let undated = window(resetsIn: nil)

    private static func shows(reachedType: String? = CodexUsagePresentation.windowLimitReachedType,
                              spendControl: Bool? = nil,
                              primary: CodexRateLimitWindow?,
                              secondary: CodexRateLimitWindow?) -> Bool {
        let snapshot = CodexRateLimitSnapshot(
            limitId: "codex", rateLimitReachedType: reachedType,
            spendControlReached: spendControl, primary: primary, secondary: secondary)
        return CodexUsagePresentation.showsLimitReached(snapshot, now: now)
    }

    @Test func noLimitReachedShowsNoLabel() {
        #expect(Self.shows(reachedType: nil, primary: Self.open, secondary: Self.open) == false)
        #expect(Self.shows(reachedType: nil, spendControl: false,
                           primary: Self.ended, secondary: nil) == false)
    }

    /// A window's limit shows while any window it has is still open.
    @Test func windowLimitShowsWhileAWindowIsOpen() {
        #expect(Self.shows(primary: Self.open, secondary: Self.open))
        #expect(Self.shows(primary: Self.ended, secondary: Self.open))
        #expect(Self.shows(primary: Self.open, secondary: Self.ended))
        #expect(Self.shows(primary: Self.open, secondary: nil))
    }

    /// Once every window the snapshot has has reset, the bars draw fresh
    /// windows at 0%, and the label goes.
    @Test func windowLimitHidesOnceEveryWindowHasEnded() {
        #expect(Self.shows(primary: Self.ended, secondary: Self.ended) == false)
        #expect(Self.shows(primary: Self.ended, secondary: nil) == false)
        #expect(Self.shows(primary: nil, secondary: Self.ended) == false)
        let resetJustNow = Self.window(resetsIn: 0)
        #expect(Self.shows(primary: resetJustNow, secondary: nil) == false)
    }

    /// Nothing says the limit has reset: no window at all, or one with no
    /// reset time.
    @Test func windowLimitShowsWithoutAWindowThatHasEnded() {
        #expect(Self.shows(primary: nil, secondary: nil))
        #expect(Self.shows(primary: Self.ended, secondary: Self.undated))
    }

    /// Spend control caps spending, not a window, so a window's reset does not
    /// lift it.
    @Test func spendControlShowsWhateverTheWindowsSay() {
        #expect(Self.shows(reachedType: nil, spendControl: true,
                           primary: Self.ended, secondary: Self.ended))
        #expect(Self.shows(spendControl: true, primary: Self.ended, secondary: Self.ended))
        #expect(Self.shows(reachedType: nil, spendControl: true, primary: nil, secondary: nil))
    }

    /// A limit type that is not one of the windows, such as credits running
    /// out, shows whatever the windows say.
    @Test func otherLimitTypesShowWhateverTheWindowsSay() {
        #expect(Self.shows(reachedType: "workspace_member_credits_depleted",
                           primary: Self.ended, secondary: Self.ended))
        #expect(Self.shows(reachedType: "workspace_owner_usage_limit_reached",
                           primary: Self.ended, secondary: nil))
    }
}
