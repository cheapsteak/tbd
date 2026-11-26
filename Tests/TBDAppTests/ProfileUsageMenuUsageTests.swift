import AppKit
import Foundation
import Testing
@testable import TBDApp
import TBDShared

// MARK: - Fixtures

private enum MenuUsageFixture {
    /// A fixed clock, so ages and elapsed fractions are deterministic.
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let utc = TimeZone(identifier: "UTC")!

    static let session40 = ClaudeUsageLimitBucket(
        kind: "session", percent: 40, severity: "normal",
        resetsAt: now.addingTimeInterval(3 * 3600))
    static let weekly16 = ClaudeUsageLimitBucket(
        kind: "weekly_all", percent: 16, severity: "normal",
        resetsAt: now.addingTimeInterval(4 * 24 * 3600))
    /// A bucket kind the menu rows never draw.
    static let otherKind = ClaudeUsageLimitBucket(
        kind: "weekly_scoped", percent: 90, severity: "warning")

    static func snapshot(_ buckets: [ClaudeUsageLimitBucket],
                         fetchedAt: Date? = MenuUsageFixture.now,
                         status: String = "ok",
                         statusKind: ProfileUsageStatusKind = .ok) -> ProfileUsageSnapshot {
        ProfileUsageSnapshot(buckets: buckets, fetchedAt: fetchedAt,
                             lastAttemptAt: now, status: status,
                             statusKind: statusKind)
    }

    static func entry(kind: CredentialKind = .oauth,
                      snapshot: ProfileUsageSnapshot?) -> ModelProfileWithUsage {
        ModelProfileWithUsage(
            profile: ModelProfile(id: UUID(), name: "Work", kind: kind),
            usage: nil,
            loginIdentity: "dev@acme.example",
            usageSnapshot: snapshot
        )
    }

    static func usage(_ entry: ModelProfileWithUsage,
                      style: ProfileUsagePresentation.ResetTimeStyle = .timeOfReset)
        -> ProfileUsagePresentation.MenuUsage {
        ProfileUsagePresentation.menuUsage(for: entry, style: style, now: now, timeZone: utc)
    }

    static func presentation(_ bucket: ClaudeUsageLimitBucket,
                             style: ProfileUsagePresentation.ResetTimeStyle = .timeOfReset)
        -> ProfileUsagePresentation.BucketPresentation {
        ProfileUsagePresentation.bucketPresentation(bucket, style: style, now: now, timeZone: utc)
    }
}

// MARK: - menuUsage

@Suite("ProfileUsagePresentation — menu usage")
struct ProfileUsageMenuUsageTests {
    private typealias Fix = MenuUsageFixture
    private typealias MenuUsage = ProfileUsagePresentation.MenuUsage

    @Test func healthyFreshSnapshotShowsBarsWithoutNote() {
        let usage = Fix.usage(Fix.entry(snapshot: Fix.snapshot([Fix.session40, Fix.weekly16])))
        guard case let .bars(session, weekly, ageNote) = usage else {
            Issue.record("expected bars, got \(usage)")
            return
        }
        #expect(session?.percent == 40)
        #expect(weekly?.percent == 16)
        #expect(ageNote == nil)
    }

    @Test func weeklyOnlySnapshotShowsBarsWithNilSession() {
        let usage = Fix.usage(Fix.entry(snapshot: Fix.snapshot([Fix.weekly16])))
        guard case let .bars(session, weekly, ageNote) = usage else {
            Issue.record("expected bars, got \(usage)")
            return
        }
        #expect(session == nil)
        #expect(weekly?.percent == 16)
        #expect(ageNote == nil)
    }

    @Test func healthyStaleSnapshotShowsBarsWithAgeNote() {
        // Ten minutes old: past the five-minute threshold for a signed-in profile.
        let snapshot = Fix.snapshot([Fix.session40, Fix.weekly16],
                                    fetchedAt: Fix.now.addingTimeInterval(-600))
        let usage = Fix.usage(Fix.entry(snapshot: snapshot))
        #expect(usage == .bars(session: Fix.presentation(Fix.session40),
                               weekly: Fix.presentation(Fix.weekly16),
                               ageNote: "10m ago"))
    }

    /// Beside the bars the age stands alone: "1d ago", never the longer
    /// "updated 1d ago" that `stalenessNote` gives other surfaces.
    @Test func ageNoteIsTheAgeAloneWithoutUpdated() throws {
        let snapshot = Fix.snapshot([Fix.session40], fetchedAt: Fix.now.addingTimeInterval(-26 * 3600))
        let staleness = try #require(
            ProfileUsagePresentation.stalenessNote(for: snapshot, kind: .oauth, now: Fix.now))
        #expect(staleness == "updated 1d ago")

        let usage = Fix.usage(Fix.entry(snapshot: snapshot))
        guard case let .bars(_, _, ageNote) = usage else {
            Issue.record("expected bars, got \(usage)")
            return
        }
        #expect(ageNote == "1d ago")
        #expect(ageNote?.contains("updated") == false)
    }

    /// With no fetch time, `stalenessNote` says "no usage data yet", which
    /// the bars beside it would contradict, so the row shows no note.
    @Test func okSnapshotWithoutFetchTimeShowsBarsWithoutNote() {
        let snapshot = Fix.snapshot([Fix.session40], fetchedAt: nil)
        let note = ProfileUsagePresentation.stalenessNote(for: snapshot, kind: .oauth, now: Fix.now)
        #expect(note == "no usage data yet")
        let usage = Fix.usage(Fix.entry(snapshot: snapshot))
        #expect(usage == .bars(session: Fix.presentation(Fix.session40), weekly: nil, ageNote: nil))
    }

    @Test func ageNoteFollowsTheProfileKind() {
        // Ten minutes is within a token profile's fifteen-minute threshold.
        let snapshot = Fix.snapshot([Fix.session40], fetchedAt: Fix.now.addingTimeInterval(-600))
        let usage = Fix.usage(Fix.entry(kind: .oauthToken, snapshot: snapshot))
        #expect(usage == .bars(session: Fix.presentation(Fix.session40), weekly: nil, ageNote: nil))
    }

    @Test func failingSnapshotWithBucketsShowsNoteNotBars() throws {
        let snapshot = Fix.snapshot([Fix.session40, Fix.weekly16],
                                    fetchedAt: Fix.now.addingTimeInterval(-3 * 3600),
                                    status: "fetch failed: rate limited",
                                    statusKind: .rateLimited)
        let note = try #require(
            ProfileUsagePresentation.stalenessNote(for: snapshot, kind: .oauth, now: Fix.now))
        let usage = Fix.usage(Fix.entry(snapshot: snapshot))
        #expect(usage == .note(note))
    }

    @Test func noSnapshotShowsNothing() {
        let usage = Fix.usage(Fix.entry(snapshot: nil))
        #expect(usage == MenuUsage.none)
    }

    @Test func okSnapshotWithoutSessionOrWeeklyAllFallsBackToNote() throws {
        // Fresh: no note to give, so the row shows the name alone.
        let fresh = Fix.snapshot([Fix.otherKind])
        #expect(ProfileUsagePresentation.stalenessNote(for: fresh, kind: .oauth, now: Fix.now) == nil)
        #expect(Fix.usage(Fix.entry(snapshot: fresh)) == MenuUsage.none)

        // Old: the age note carries the row.
        let old = Fix.snapshot([Fix.otherKind], fetchedAt: Fix.now.addingTimeInterval(-600))
        let note = try #require(
            ProfileUsagePresentation.stalenessNote(for: old, kind: .oauth, now: Fix.now))
        #expect(Fix.usage(Fix.entry(snapshot: old)) == .note(note))
    }

    /// The 5h window reset an hour ago, after the reading two hours ago; the
    /// weekly one has not. Only the 5h bar shows a fresh window, and the age
    /// note is the one the same reading gets with both windows open.
    @Test func endedWindowShowsFreshBesideAnOpenOne() {
        let fetchedAt = Fix.now.addingTimeInterval(-2 * 3600)
        let endedSession = ClaudeUsageLimitBucket(
            kind: "session", percent: 40, severity: "normal",
            resetsAt: Fix.now.addingTimeInterval(-3600))
        let usage = Fix.usage(Fix.entry(snapshot: Fix.snapshot([endedSession, Fix.weekly16],
                                                               fetchedAt: fetchedAt)))
        #expect(usage == .bars(
            session: ProfileUsagePresentation.BucketPresentation(
                kind: "session", percent: 0, percentText: "0%", fill: .normal,
                resetDisplay: .clock, resetInline: nil, resetPhrase: "reset at 7am",
                elapsedFraction: nil, windowEnded: true),
            weekly: Fix.presentation(Fix.weekly16),
            ageNote: "2h ago"))
        #expect(Fix.presentation(Fix.weekly16).percentText == "16%")

        let openSession = ClaudeUsageLimitBucket(
            kind: "session", percent: 40, severity: "normal",
            resetsAt: Fix.now.addingTimeInterval(3600))
        let open = Fix.usage(Fix.entry(snapshot: Fix.snapshot([openSession, Fix.weekly16],
                                                              fetchedAt: fetchedAt)))
        #expect(open == .bars(session: Fix.presentation(openSession),
                              weekly: Fix.presentation(Fix.weekly16),
                              ageNote: "2h ago"))
        #expect(Fix.presentation(openSession).percentText == "40%")
    }

    /// A token profile refreshes only when a session on it finishes a turn,
    /// so its reading can be days old. Both windows reset since this one, so
    /// both bars show fresh windows beside the age.
    @Test func daysOldTokenReadingShowsBothEndedWindowsFresh() {
        let session = ClaudeUsageLimitBucket(
            kind: "session", percent: 12, severity: "normal",
            resetsAt: Fix.now.addingTimeInterval(-45 * 3600))
        let weekly = ClaudeUsageLimitBucket(
            kind: "weekly_all", percent: 86, severity: "warning",
            resetsAt: Fix.now.addingTimeInterval(-24 * 3600))
        let snapshot = Fix.snapshot([session, weekly], fetchedAt: Fix.now.addingTimeInterval(-2 * 24 * 3600))
        let usage = Fix.usage(Fix.entry(kind: .oauthToken, snapshot: snapshot))
        guard case let .bars(sessionBar, weeklyBar, ageNote) = usage else {
            Issue.record("expected bars, got \(usage)")
            return
        }
        #expect(sessionBar?.percentText == "0%")
        #expect(sessionBar?.fill == .normal)
        #expect(sessionBar?.elapsedFraction == nil)
        #expect(weeklyBar?.percentText == "0%")
        #expect(weeklyBar?.fill == .normal)
        #expect(weeklyBar?.elapsedFraction == nil)
        #expect(weeklyBar?.resetPhrase == "reset at Thu 8am")
        #expect(ageNote == "2d ago")
    }

    @Test func bucketPresentationsMatchBucketPresentation() {
        // A non-default style must reach the presentations too.
        let usage = Fix.usage(Fix.entry(snapshot: Fix.snapshot([Fix.session40, Fix.weekly16])),
                              style: .timeUntilReset)
        #expect(usage == .bars(session: Fix.presentation(Fix.session40, style: .timeUntilReset),
                               weekly: Fix.presentation(Fix.weekly16, style: .timeUntilReset),
                               ageNote: nil))
    }
}

// MARK: - nsBarColor

@MainActor
@Suite("FillLevel — AppKit bar colors")
struct UsageFillNSColorTests {
    private typealias FillLevel = ProfileUsagePresentation.FillLevel

    private func expectSRGB(_ color: NSColor, _ red: CGFloat, _ green: CGFloat, _ blue: CGFloat,
                            sourceLocation: SourceLocation = #_sourceLocation) throws {
        let srgb = try #require(color.usingColorSpace(.sRGB), sourceLocation: sourceLocation)
        #expect(abs(srgb.redComponent - red / 255) < 0.002, sourceLocation: sourceLocation)
        #expect(abs(srgb.greenComponent - green / 255) < 0.002, sourceLocation: sourceLocation)
        #expect(abs(srgb.blueComponent - blue / 255) < 0.002, sourceLocation: sourceLocation)
    }

    @Test func nsBarColorValues() throws {
        try expectSRGB(FillLevel.normal.nsBarColor(isDark: false), 27, 107, 52)
        try expectSRGB(FillLevel.normal.nsBarColor(isDark: true), 60, 199, 95)
        for isDark in [false, true] {
            #expect(FillLevel.caution.nsBarColor(isDark: isDark) == NSColor.systemOrange)
            #expect(FillLevel.warning.nsBarColor(isDark: isDark) == NSColor.systemOrange)
            #expect(FillLevel.critical.nsBarColor(isDark: isDark) == NSColor.systemRed)
        }
    }
}
