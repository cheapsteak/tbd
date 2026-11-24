import AppKit
import Foundation
import Testing
@testable import TBDApp
import TBDShared

// MARK: - Fixtures

private enum BarsImageFixture {
    typealias Presentation = ProfileUsagePresentation.BucketPresentation

    /// A fixed clock, so elapsed fractions and fill levels are deterministic.
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let utc = TimeZone(identifier: "UTC")!

    static func presentation(kind: String, percent: Double, severity: String?,
                             resetsIn: TimeInterval?) -> Presentation {
        let resetsAt = resetsIn.map { BarsImageFixture.now.addingTimeInterval($0) }
        let bucket = ClaudeUsageLimitBucket(kind: kind, percent: percent,
                                            severity: severity, resetsAt: resetsAt)
        return ProfileUsagePresentation.bucketPresentation(bucket, now: now, timeZone: utc)
    }

    static func session(_ percent: Double, severity: String? = "normal",
                        resetsIn: TimeInterval? = 2.5 * 3600) -> Presentation {
        presentation(kind: "session", percent: percent, severity: severity, resetsIn: resetsIn)
    }

    static func weekly(_ percent: Double, severity: String? = "normal",
                       resetsIn: TimeInterval? = 4 * 24 * 3600) -> Presentation {
        presentation(kind: "weekly_all", percent: percent, severity: severity, resetsIn: resetsIn)
    }
}

private extension UsageBarsMenuImage.Mark {
    var isTrack: Bool {
        if case .track = kind { return true } else { return false }
    }

    var isTick: Bool {
        if case .tick = kind { return true } else { return false }
    }

    var labelText: String? {
        if case let .label(text) = kind { return text } else { return nil }
    }

    var fillLevel: ProfileUsagePresentation.FillLevel? {
        if case let .fill(level) = kind { return level } else { return nil }
    }

    var percentText: String? {
        if case let .percent(text, _) = kind { return text } else { return nil }
    }

    var percentLevel: ProfileUsagePresentation.FillLevel? {
        if case let .percent(_, level) = kind { return level } else { return nil }
    }
}

// MARK: - UsageBarsMenuImage

@MainActor
@Suite("UsageBarsMenuImage")
struct UsageBarsMenuImageTests {
    private typealias Fix = BarsImageFixture
    private typealias Bars = UsageBarsMenuImage

    @Test func sizeIs200By13() {
        #expect(Bars.size == NSSize(width: 200, height: 13))
        let session = Fix.session(40)
        let weekly = Fix.weekly(16)
        let combinations: [(Fix.Presentation?, Fix.Presentation?)] = [
            (nil, nil), (session, nil), (nil, weekly), (session, weekly),
        ]
        for (sessionBucket, weeklyBucket) in combinations {
            let size = Bars.image(session: sessionBucket, weekly: weeklyBucket).size
            #expect(size == Bars.size)
        }
    }

    @Test func weeklySlotStartsAtSameXWithoutSession() throws {
        let weekly = Fix.weekly(16)
        for session in [Fix.session(40), nil] {
            let marks = Bars.marks(session: session, weekly: weekly)
            let found = marks.first { $0.labelText == "wk" }
            let label = try #require(found)
            #expect(label.rect.minX == 107)
        }
        let weeklyOnly = Bars.marks(session: nil, weekly: weekly)
        let inSessionSlot = weeklyOnly.filter { $0.rect.minX < 93 }
        #expect(inSessionSlot.isEmpty)
    }

    @Test func fillWidthFollowsPercent() throws {
        let marks = Bars.marks(session: Fix.session(40), weekly: nil)
        let foundTrack = marks.first { $0.isTrack }
        let foundFill = marks.first { $0.fillLevel != nil }
        let track = try #require(foundTrack)
        let fill = try #require(foundFill)
        #expect(track.rect.minX == 18)
        #expect(track.rect.width == 44)
        #expect(fill.rect.minX == track.rect.minX)
        #expect(fill.rect.width == 44 * 0.4)
    }

    @Test func fillClampsAtFullWidth() throws {
        let marks = Bars.marks(session: Fix.session(130, severity: "critical"), weekly: nil)
        let foundFill = marks.first { $0.fillLevel != nil }
        let fill = try #require(foundFill)
        #expect(fill.rect.width == 44)
    }

    @Test func fillAndPercentTakeThePresentationFillLevel() {
        // 55% with 3h15m of the 5h gone projects to about 85%: caution, though
        // the API says normal.
        let caution = Fix.session(55, resetsIn: 1.75 * 3600)
        let critical = Fix.weekly(94, severity: "critical")
        #expect(caution.fill == .caution)
        #expect(critical.fill == .critical)

        let marks = Bars.marks(session: caution, weekly: critical)
        let fills = marks.compactMap { $0.fillLevel }
        let percentTexts = marks.compactMap { $0.percentText }
        let percentLevels = marks.compactMap { $0.percentLevel }
        #expect(fills == [caution.fill, critical.fill])
        #expect(percentTexts == [caution.percentText, critical.percentText])
        #expect(percentLevels == [caution.fill, critical.fill])
    }

    @Test func tickSitsAtElapsedFraction() throws {
        // 2.5h left of a 5h window: halfway.
        let session = Fix.session(40, resetsIn: 2.5 * 3600)
        let elapsed = try #require(session.elapsedFraction)
        #expect(elapsed == 0.5)

        let marks = Bars.marks(session: session, weekly: nil)
        let foundTrack = marks.first { $0.isTrack }
        let foundTick = marks.first { $0.isTick }
        let track = try #require(foundTrack)
        let tick = try #require(foundTick)
        let expectedMinX = track.rect.minX + (44 * 0.5).rounded() - 0.75
        #expect(tick.rect.width == 2.5)
        #expect(tick.rect.height == 9)
        #expect(tick.rect.minX == expectedMinX)
        #expect(tick.rect.midY == track.rect.midY)
    }

    @Test func noTickWithoutElapsedFraction() {
        let session = Fix.session(40, resetsIn: nil)
        #expect(session.elapsedFraction == nil)
        let marks = Bars.marks(session: session, weekly: nil)
        let ticks = marks.filter { $0.isTick }
        #expect(ticks.isEmpty)
    }

    @Test func accessibilityTextNamesPresentBuckets() {
        let session = Fix.session(40)
        let weekly = Fix.weekly(16)

        #expect(Bars.accessibilityText(session: session, weekly: weekly) == "5-hour 40%, weekly 16%")
        #expect(Bars.accessibilityText(session: nil, weekly: Fix.weekly(22)) == "weekly 22%")

        let image = Bars.image(session: session, weekly: weekly)
        #expect(image.accessibilityDescription == "5-hour 40%, weekly 16%")
        #expect(image.isTemplate == false)
    }
}
