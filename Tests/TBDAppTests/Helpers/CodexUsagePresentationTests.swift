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
