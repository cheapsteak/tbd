import Foundation
import Testing
@testable import TBDApp
import TBDShared

// MARK: - Fixtures

private let utc = TimeZone(identifier: "UTC")!

/// 2026-07-03 23:10:00 UTC (a Friday) — renders as "11:10pm" in the UTC
/// fixtures below ("Fri 11:10pm" in the weekday form).
private let resetDate: Date = {
    var components = DateComponents()
    components.year = 2026
    components.month = 7
    components.day = 3
    components.hour = 23
    components.minute = 10
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    return calendar.date(from: components)!
}()

private func bucket(kind: String, percent: Double, severity: String? = nil,
                    resetsAt: Date? = nil, family: String? = nil) -> ClaudeUsageLimitBucket {
    ClaudeUsageLimitBucket(kind: kind, percent: percent, severity: severity,
                           resetsAt: resetsAt, modelDisplayName: family)
}

private func snapshot(buckets: [ClaudeUsageLimitBucket],
                      fetchedAt: Date? = Date(),
                      status: String = "ok",
                      statusKind: ProfileUsageStatusKind = .ok) -> ProfileUsageSnapshot {
    ProfileUsageSnapshot(buckets: buckets, fetchedAt: fetchedAt,
                         lastAttemptAt: Date(), status: status,
                         statusKind: statusKind)
}

private func entry(name: String,
                   kind: CredentialKind = .oauth,
                   loginIdentity: String? = nil,
                   usageSnapshot: ProfileUsageSnapshot? = nil) -> ModelProfileWithUsage {
    ModelProfileWithUsage(
        profile: ModelProfile(id: UUID(), name: name, kind: kind),
        usage: nil,
        loginIdentity: loginIdentity,
        usageSnapshot: usageSnapshot
    )
}

/// The live-verified Gmail shape: 5h 0% resetting 11:10pm, weekly 76%, Fable 100%.
private let gmailSnapshot = snapshot(buckets: [
    bucket(kind: "session", percent: 0, severity: "normal", resetsAt: resetDate),
    bucket(kind: "weekly_all", percent: 76, severity: "warning"),
    bucket(kind: "weekly_scoped", percent: 100, severity: "critical", family: "Fable"),
])

private func claudeTerminal(profileID: UUID? = nil,
                            createdAt: Date = Date(timeIntervalSince1970: 0),
                            kind: TerminalKind? = .claude,
                            claudeSessionID: String? = nil) -> Terminal {
    Terminal(worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
             createdAt: createdAt, claudeSessionID: claudeSessionID,
             profileID: profileID, kind: kind)
}

// MARK: - Usage suffix composition

@Suite("ProfileUsagePresentation — menu suffix")
struct UsageSuffixTests {
    @Test func fullSnapshotComposesCompactSuffix() {
        let suffix = ProfileUsagePresentation.usageSuffix(for: gmailSnapshot, timeZone: utc)
        #expect(suffix == " · 5h 0% ↺11:10pm · wk 76% · F 100%")
    }

    @Test func missingSnapshotProducesEmptySuffix() {
        #expect(ProfileUsagePresentation.usageSuffix(for: nil) == "")
    }

    @Test func emptyBucketsProduceEmptySuffix() {
        #expect(ProfileUsagePresentation.usageSuffix(for: snapshot(buckets: [])) == "")
    }

    @Test func missingScopedBucketOmitsFamilySegment() {
        // No data for the family on this account → segment absent, not "F 0%".
        let noFable = snapshot(buckets: [
            bucket(kind: "session", percent: 19),
            bucket(kind: "weekly_all", percent: 24),
        ])
        #expect(ProfileUsagePresentation.usageSuffix(for: noFable, timeZone: utc)
                == " · 5h 19% · wk 24%")
    }

    @Test func sessionWithoutResetOmitsClockFragment() {
        let noReset = snapshot(buckets: [bucket(kind: "session", percent: 29)])
        #expect(ProfileUsagePresentation.usageSuffix(for: noReset, timeZone: utc) == " · 5h 29%")
    }

    @Test func percentsRoundToWholeNumbers() {
        let fractional = snapshot(buckets: [bucket(kind: "session", percent: 75.6)])
        #expect(ProfileUsagePresentation.usageSuffix(for: fractional, timeZone: utc) == " · 5h 76%")
    }

    @Test func menuItemTitleCombinesIdentityAndUsage() {
        let gmail = entry(name: "Gmail", loginIdentity: "g@x.co", usageSnapshot: gmailSnapshot)
        #expect(ProfileUsagePresentation.menuItemTitle(for: gmail, timeZone: utc)
                == "Gmail — g@x.co · 5h 0% ↺11:10pm · wk 76% · F 100%")
    }

    @Test func menuItemTitleWithoutSnapshotIsIdentityOnly() {
        let bare = entry(name: "Work", loginIdentity: "a@b.co")
        #expect(ProfileUsagePresentation.menuItemTitle(for: bare) == "Work — a@b.co")
    }

    @Test func familyAbbreviationTakesFirstLetterUppercased() {
        #expect(ProfileUsagePresentation.familyAbbreviation("Fable") == "F")
        #expect(ProfileUsagePresentation.familyAbbreviation("opus") == "O")
        #expect(ProfileUsagePresentation.familyAbbreviation(nil) == "?")
        #expect(ProfileUsagePresentation.familyAbbreviation("  ") == "?")
    }
}

// MARK: - Two-line menu composition

@Suite("ProfileUsagePresentation — two-line menu")
struct TwoLineMenuTests {
    @Test func fullSnapshotSpellsOutUsageWithUsedLabelOnce() {
        let line = ProfileUsagePresentation.usageDetailLine(for: gmailSnapshot, timeZone: utc)
        #expect(line == "5h 0% used · resets 11:10pm · week 76% · Fable 100%")
    }

    @Test func usedLabelAppearsExactlyOnceOnTheFirstPercentage() {
        let line = ProfileUsagePresentation.usageDetailLine(for: gmailSnapshot, timeZone: utc) ?? ""
        #expect(line.components(separatedBy: "used").count - 1 == 1)
        // It rides the first (5h) segment, not the weekly/family ones.
        #expect(line.hasPrefix("5h 0% used"))
    }

    @Test func missingSnapshotHasNoDetailLine() {
        #expect(ProfileUsagePresentation.usageDetailLine(for: nil) == nil)
    }

    @Test func emptyBucketsHaveNoDetailLine() {
        #expect(ProfileUsagePresentation.usageDetailLine(for: snapshot(buckets: [])) == nil)
    }

    @Test func withoutScopedFamilyBucketOmitsFamilySegment() {
        let noFable = snapshot(buckets: [
            bucket(kind: "session", percent: 16, resetsAt: resetDate),
            bucket(kind: "weekly_all", percent: 79),
        ])
        #expect(ProfileUsagePresentation.usageDetailLine(for: noFable, timeZone: utc)
                == "5h 16% used · resets 11:10pm · week 79%")
    }

    @Test func sessionWithoutResetOmitsClockFragmentButKeepsUsed() {
        let noReset = snapshot(buckets: [bucket(kind: "session", percent: 29)])
        #expect(ProfileUsagePresentation.usageDetailLine(for: noReset, timeZone: utc)
                == "5h 29% used")
    }

    @Test func usedLabelRidesWeeklyWhenNoSessionBucket() {
        // If the session bucket is absent, "used" attaches to the first segment
        // that does appear (weekly) so the line still disambiguates once.
        let weeklyOnly = snapshot(buckets: [bucket(kind: "weekly_all", percent: 40)])
        #expect(ProfileUsagePresentation.usageDetailLine(for: weeklyOnly, timeZone: utc)
                == "week 40% used")
    }

    @Test func menuLineSplitsIdentityAndUsage() {
        let gmail = entry(name: "Gmail", loginIdentity: "g@x.co", usageSnapshot: gmailSnapshot)
        let line = ProfileUsagePresentation.menuLine(for: gmail, timeZone: utc)
        #expect(line.primary == "Gmail — g@x.co")
        #expect(line.secondary == "5h 0% used · resets 11:10pm · week 76% · Fable 100%")
    }

    @Test func menuLineWithoutSnapshotHasNilSecondary() {
        let bare = entry(name: "Work", loginIdentity: "a@b.co")
        let line = ProfileUsagePresentation.menuLine(for: bare)
        #expect(line.primary == "Work — a@b.co")
        #expect(line.secondary == nil)
    }

    @Test func menuLineForNotLoggedInProfileKeepsSingleLineTreatment() {
        // oauth profile, no identity → "needs /login" primary, no usage line.
        let needsLogin = entry(name: "Spare")
        let line = ProfileUsagePresentation.menuLine(for: needsLogin)
        #expect(line.primary == "Spare — needs /login")
        #expect(line.secondary == nil)
    }

    @Test func familyNameSpellsOutTheDisplayNameOrFallsBack() {
        #expect(ProfileUsagePresentation.familyName("Fable") == "Fable")
        #expect(ProfileUsagePresentation.familyName("  Opus  ") == "Opus")
        #expect(ProfileUsagePresentation.familyName(nil) == "?")
        #expect(ProfileUsagePresentation.familyName("  ") == "?")
    }
}

// MARK: - Severity mapping

@Suite("ProfileUsagePresentation — severity")
struct SeverityLevelTests {
    @Test func apiSeverityLabelsMapDirectly() {
        #expect(ProfileUsagePresentation.severityLevel(severity: "normal", percent: 99) == .normal)
        #expect(ProfileUsagePresentation.severityLevel(severity: "warning", percent: 0) == .warning)
        #expect(ProfileUsagePresentation.severityLevel(severity: "critical", percent: 0) == .critical)
    }

    @Test func missingSeverityFallsBackToPercentThresholds() {
        #expect(ProfileUsagePresentation.severityLevel(severity: nil, percent: 10) == .normal)
        #expect(ProfileUsagePresentation.severityLevel(severity: nil, percent: 75) == .warning)
        #expect(ProfileUsagePresentation.severityLevel(severity: nil, percent: 90) == .critical)
        // Unknown future label also falls through to percent.
        #expect(ProfileUsagePresentation.severityLevel(severity: "exotic", percent: 100) == .critical)
    }
}

// MARK: - Pace-aware fill tier

@Suite("ProfileUsagePresentation — fillLevel (pace)")
struct FillLevelTests {
    @Test func underPaceProjectionStaysNormal() {
        // 20% used at half-window → projected 0.40 < 0.75 → green.
        #expect(ProfileUsagePresentation.fillLevel(
            severity: "normal", percent: 20, elapsedFraction: 0.5) == .normal)
    }

    @Test func projectionInWarmingBandIsCaution() {
        // 55% used at 0.65 elapsed → projected ≈ 0.846 → caution.
        #expect(ProfileUsagePresentation.fillLevel(
            severity: "normal", percent: 55, elapsedFraction: 0.65) == .caution)
        // Band edges: exactly 0.75 is caution, just below is normal.
        #expect(ProfileUsagePresentation.fillLevel(
            severity: "normal", percent: 37.5, elapsedFraction: 0.5) == .caution)
        #expect(ProfileUsagePresentation.fillLevel(
            severity: "normal", percent: 37.4, elapsedFraction: 0.5) == .normal)
    }

    @Test func projectionInPressingBandIsWarning() {
        // 45% used at 0.475 elapsed → projected ≈ 0.947 → orange.
        #expect(ProfileUsagePresentation.fillLevel(
            severity: "normal", percent: 45, elapsedFraction: 0.475) == .warning)
        // Lower band edge: exactly 0.90.
        #expect(ProfileUsagePresentation.fillLevel(
            severity: "normal", percent: 45, elapsedFraction: 0.5) == .warning)
    }

    @Test func projectionAtOrAboveOneIsCritical() {
        // 50% used at 0.5 elapsed → projected exactly 1.0 → red.
        #expect(ProfileUsagePresentation.fillLevel(
            severity: "normal", percent: 50, elapsedFraction: 0.5) == .critical)
        // 70% at 0.3 elapsed → projected ≈ 2.33 → red.
        #expect(ProfileUsagePresentation.fillLevel(
            severity: "normal", percent: 70, elapsedFraction: 0.3) == .critical)
    }

    @Test func gateOffBelowFifteenPercentElapsedFallsBackToFloor() {
        // Burning insanely fast, but the window barely started: projection is
        // too noisy, so the plain severity floor rules (normal here).
        #expect(ProfileUsagePresentation.fillLevel(
            severity: "normal", percent: 30, elapsedFraction: 0.10) == .normal)
        // At exactly the gate the projection turns on.
        #expect(ProfileUsagePresentation.fillLevel(
            severity: "normal", percent: 30, elapsedFraction: 0.15) == .critical)
    }

    @Test func windowOverOrNoFractionFallsBackToFloor() {
        // elapsedFraction == 1.0 (window over) → floor only.
        #expect(ProfileUsagePresentation.fillLevel(
            severity: "normal", percent: 60, elapsedFraction: 1.0) == .normal)
        // No reset date → nil fraction → exactly today's severity mapping.
        #expect(ProfileUsagePresentation.fillLevel(
            severity: "normal", percent: 60, elapsedFraction: nil) == .normal)
        #expect(ProfileUsagePresentation.fillLevel(
            severity: nil, percent: 80, elapsedFraction: nil) == .warning)
        #expect(ProfileUsagePresentation.fillLevel(
            severity: nil, percent: 95, elapsedFraction: nil) == .critical)
    }

    @Test func severityFloorWinsWhenWorseThanPaceTier() {
        // Pace says green (10% at 0.8 elapsed → projected 0.125), but the API
        // says warning/critical — the floor keeps the bar honest.
        #expect(ProfileUsagePresentation.fillLevel(
            severity: "warning", percent: 10, elapsedFraction: 0.8) == .warning)
        #expect(ProfileUsagePresentation.fillLevel(
            severity: "critical", percent: 10, elapsedFraction: 0.8) == .critical)
        // Percent-threshold fallback floors too: 76% used late in the window
        // projects under 1.0 but still can't render below warning.
        #expect(ProfileUsagePresentation.fillLevel(
            severity: nil, percent: 76, elapsedFraction: 0.99) == .warning)
    }

    @Test func paceTierWinsWhenWorseThanSeverityFloor() {
        // API still says normal but the burn rate projects past the limit.
        #expect(ProfileUsagePresentation.fillLevel(
            severity: "normal", percent: 55, elapsedFraction: 0.286) == .critical)
    }

    @Test func zeroPercentStaysNormalRegardlessOfElapsed() {
        #expect(ProfileUsagePresentation.fillLevel(
            severity: "normal", percent: 0, elapsedFraction: 0.9) == .normal)
        #expect(ProfileUsagePresentation.fillLevel(
            severity: nil, percent: 0, elapsedFraction: 0.5) == .normal)
    }

    @Test func fillLevelsAreOrderedByUrgency() {
        #expect(ProfileUsagePresentation.FillLevel.normal
                < ProfileUsagePresentation.FillLevel.caution)
        #expect(ProfileUsagePresentation.FillLevel.caution
                < ProfileUsagePresentation.FillLevel.warning)
        #expect(ProfileUsagePresentation.FillLevel.warning
                < ProfileUsagePresentation.FillLevel.critical)
    }
}

// MARK: - Reset display policy

@Suite("ProfileUsagePresentation — resetDisplay policy")
struct ResetDisplayPolicyTests {
    // Default style (timeOfReset): absolute times inline.

    @Test func sessionKindUsesClockDisplayByDefault() {
        #expect(ProfileUsagePresentation.resetDisplay(forKind: "session") == .clock)
    }

    @Test func weeklyAllKindUsesWeekdayClockDisplayByDefault() {
        #expect(ProfileUsagePresentation.resetDisplay(forKind: "weekly_all") == .weekdayClock)
    }

    @Test func scopedKindUsesTooltipOnlyDisplay() {
        #expect(ProfileUsagePresentation.resetDisplay(forKind: "weekly_scoped") == .tooltipOnly)
    }

    @Test func unknownKindDefaultsToTooltipOnly() {
        #expect(ProfileUsagePresentation.resetDisplay(forKind: "future_kind") == .tooltipOnly)
    }

    // timeUntilReset style: relative countdowns inline.

    @Test func sessionKindUsesCountdownUnderTimeUntilStyle() {
        #expect(ProfileUsagePresentation.resetDisplay(forKind: "session",
                                                      style: .timeUntilReset) == .countdown)
    }

    @Test func weeklyAllKindUsesCountdownUnderTimeUntilStyle() {
        #expect(ProfileUsagePresentation.resetDisplay(forKind: "weekly_all",
                                                      style: .timeUntilReset) == .countdown)
    }

    @Test func scopedAndUnknownKindsStayTooltipOnlyUnderTimeUntilStyle() {
        #expect(ProfileUsagePresentation.resetDisplay(forKind: "weekly_scoped",
                                                      style: .timeUntilReset) == .tooltipOnly)
        #expect(ProfileUsagePresentation.resetDisplay(forKind: "future_kind",
                                                      style: .timeUntilReset) == .tooltipOnly)
    }
}

@Suite("ProfileUsagePresentation — windowDuration")
struct WindowDurationTests {
    @Test func sessionKindUsesSessionWindow() {
        #expect(ProfileUsagePresentation.windowDuration(forKind: "session") == ProfileUsagePresentation.sessionWindow)
    }

    @Test func weeklyAllKindUsesWeeklyWindow() {
        #expect(ProfileUsagePresentation.windowDuration(forKind: "weekly_all") == ProfileUsagePresentation.weeklyWindow)
    }

    @Test func scopedKindUsesWeeklyWindow() {
        #expect(ProfileUsagePresentation.windowDuration(forKind: "weekly_scoped") == ProfileUsagePresentation.weeklyWindow)
    }

    @Test func unknownKindDefaultsToSessionWindow() {
        #expect(ProfileUsagePresentation.windowDuration(forKind: "future_kind") == ProfileUsagePresentation.sessionWindow)
    }
}

// MARK: - Unified bucket presentation

@Suite("ProfileUsagePresentation — BucketPresentation")
struct BucketPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func sessionBucketBuildsClockDisplay() {
        // Use a reset date in the future relative to the test's 'now'.
        // 45% early in the window (10% elapsed) → pace projection off (< 15% threshold), fill = normal floor
        let futureReset = now.addingTimeInterval(0.9 * ProfileUsagePresentation.sessionWindow)  // 90% remaining
        let sessionBucket = bucket(kind: "session", percent: 45, severity: "normal", resetsAt: futureReset)
        let presentation = ProfileUsagePresentation.bucketPresentation(sessionBucket, now: now, timeZone: utc)
        #expect(presentation.kind == "session")
        #expect(presentation.percent == 45)
        #expect(presentation.percentText == "45%")
        #expect(presentation.resetDisplay == .clock)
        #expect(presentation.resetInline != nil)  // Clock display should have reset inline
        #expect(presentation.resetPhrase != nil)  // Should have reset phrase
        #expect(presentation.fill == .normal)  // 10% elapsed, below gate
        #expect(presentation.elapsedFraction != nil)
    }

    @Test func weeklyBucketBuildsWeekdayClockDisplay() {
        let weeklyBucket = bucket(kind: "weekly_all", percent: 76, severity: "warning")
        let presentation = ProfileUsagePresentation.bucketPresentation(weeklyBucket, now: now, timeZone: utc)
        #expect(presentation.kind == "weekly_all")
        #expect(presentation.percent == 76)
        #expect(presentation.percentText == "76%")
        #expect(presentation.resetDisplay == .weekdayClock)
        #expect(presentation.resetInline == nil)  // No reset date on weekly bucket
        #expect(presentation.resetPhrase == nil)
        #expect(presentation.fill == .warning)
        #expect(presentation.elapsedFraction == nil)
    }

    @Test func scopedBucketBuildsTooltipDisplay() {
        let scopedBucket = bucket(kind: "weekly_scoped", percent: 100, severity: "critical", family: "Fable")
        let presentation = ProfileUsagePresentation.bucketPresentation(scopedBucket, now: now, timeZone: utc)
        #expect(presentation.kind == "weekly_scoped")
        #expect(presentation.percent == 100)
        #expect(presentation.percentText == "100%")
        #expect(presentation.resetDisplay == .tooltipOnly)
        #expect(presentation.resetInline == nil)
        #expect(presentation.resetPhrase == nil)
        #expect(presentation.fill == .critical)
        #expect(presentation.elapsedFraction == nil)
    }

    @Test func paceAwareCautionTierInPresentation() {
        // 55% at 0.65 elapsed on a session bucket → caution.
        // elapsed = 0.65 * window means remaining = 0.35 * window
        let sessionBucket = bucket(kind: "session", percent: 55, severity: "normal",
                                   resetsAt: now.addingTimeInterval(0.35 * ProfileUsagePresentation.sessionWindow))
        let presentation = ProfileUsagePresentation.bucketPresentation(sessionBucket, now: now, timeZone: utc)
        #expect(presentation.fill == .caution)
    }

    @Test func countdownInResetPhraseWhenValid() {
        // Weekly bucket with a reset date, under the time-until preference.
        let weekly = bucket(kind: "weekly_all", percent: 50, resetsAt: now.addingTimeInterval(2 * 24 * 3600))
        let presentation = ProfileUsagePresentation.bucketPresentation(
            weekly, style: .timeUntilReset, now: now, timeZone: utc)
        #expect(presentation.resetDisplay == .countdown)
        #expect(presentation.resetInline != nil)
        #expect(presentation.resetPhrase?.hasPrefix("resets in") ?? false)
    }

    // MARK: Preference modes — exact inline strings per bucket kind.

    @Test func sessionTimeOfResetInlineIsAtClockTime() {
        // now two hours before the 11:10pm fixture reset.
        let now = resetDate.addingTimeInterval(-2 * 3600)
        let session = bucket(kind: "session", percent: 20, resetsAt: resetDate)
        let presentation = ProfileUsagePresentation.bucketPresentation(
            session, style: .timeOfReset, now: now, timeZone: utc)
        #expect(presentation.resetInline == "at 11:10pm")
        #expect(presentation.resetPhrase == "resets at 11:10pm")
    }

    @Test func weeklyTimeOfResetInlineIsAtWeekdayTime() {
        // resetDate is a Friday; 4 days out → weekday + 12h time.
        let now = resetDate.addingTimeInterval(-4 * 24 * 3600)
        let weekly = bucket(kind: "weekly_all", percent: 50, resetsAt: resetDate)
        let presentation = ProfileUsagePresentation.bucketPresentation(
            weekly, style: .timeOfReset, now: now, timeZone: utc)
        #expect(presentation.resetInline == "at Fri 11:10pm")
        #expect(presentation.resetPhrase == "resets at Fri 11:10pm")
    }

    @Test func sessionTimeUntilInlineKeepsMinutePrecision() {
        let session = bucket(kind: "session", percent: 20,
                             resetsAt: now.addingTimeInterval((2 * 60 + 10) * 60))
        let presentation = ProfileUsagePresentation.bucketPresentation(
            session, style: .timeUntilReset, now: now, timeZone: utc)
        #expect(presentation.resetInline == "in 2h 10m")
        #expect(presentation.resetPhrase == "resets in 2h 10m")
    }

    @Test func weeklyTimeUntilInlineIsDayHourCountdown() {
        let weekly = bucket(kind: "weekly_all", percent: 50,
                            resetsAt: now.addingTimeInterval((4 * 24 + 2) * 3600))
        let presentation = ProfileUsagePresentation.bucketPresentation(
            weekly, style: .timeUntilReset, now: now, timeZone: utc)
        #expect(presentation.resetInline == "in 4d 2h")
        #expect(presentation.resetPhrase == "resets in 4d 2h")
    }

    @Test func scopedStaysTooltipOnlyInBothStyles() {
        let scoped = bucket(kind: "weekly_scoped", percent: 45,
                            resetsAt: now.addingTimeInterval(2 * 24 * 3600), family: "Fable")
        for style in ProfileUsagePresentation.ResetTimeStyle.allCases {
            let presentation = ProfileUsagePresentation.bucketPresentation(
                scoped, style: style, now: now, timeZone: utc)
            #expect(presentation.resetDisplay == .tooltipOnly)
            #expect(presentation.resetInline == nil)
            #expect(presentation.resetPhrase == "resets in 2d")
        }
    }
}

@Suite("ProfileUsagePresentation — hoverCardTint mapping")
struct HoverCardTintMappingTests {
    @Test func normalFillMapsToNormalTint() {
        #expect(ProfileUsagePresentation.hoverCardTint(for: .normal) == .normal)
    }

    @Test func cautionFillMapsToCautionTint() {
        #expect(ProfileUsagePresentation.hoverCardTint(for: .caution) == .caution)
    }

    @Test func warningFillMapsToWarningTint() {
        #expect(ProfileUsagePresentation.hoverCardTint(for: .warning) == .warning)
    }

    @Test func criticalFillMapsToCriticalTint() {
        #expect(ProfileUsagePresentation.hoverCardTint(for: .critical) == .critical)
    }
}

// MARK: - Pace projection: elapsed-time fraction

@Suite("ProfileUsagePresentation — elapsedFraction")
struct ElapsedFractionTests {
    /// Fixed instant so no test touches the wall clock.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func windowConstantsAreFiveHoursAndSevenDays() {
        #expect(ProfileUsagePresentation.sessionWindow == 5 * 60 * 60)
        #expect(ProfileUsagePresentation.weeklyWindow == 7 * 24 * 60 * 60)
    }

    @Test func noResetDateYieldsNil() {
        #expect(ProfileUsagePresentation.elapsedFraction(
            resetsAt: nil,
            windowDuration: ProfileUsagePresentation.sessionWindow,
            now: now) == nil)
    }

    @Test func nonPositiveWindowDurationYieldsNil() {
        // A zero/negative denominator has no meaningful fraction.
        #expect(ProfileUsagePresentation.elapsedFraction(
            resetsAt: now.addingTimeInterval(3600),
            windowDuration: 0,
            now: now) == nil)
    }

    @Test func resetBehindNowMeansPeriodOverYieldsNil() {
        // reset already passed → the daemon just hasn't rolled a new window yet.
        #expect(ProfileUsagePresentation.elapsedFraction(
            resetsAt: now.addingTimeInterval(-100),
            windowDuration: ProfileUsagePresentation.sessionWindow,
            now: now) == nil)
    }

    @Test func resetExactlyNowIsPeriodOverYieldsNil() {
        // Boundary: remaining == 0 fails the `remaining > 0` guard.
        #expect(ProfileUsagePresentation.elapsedFraction(
            resetsAt: now,
            windowDuration: ProfileUsagePresentation.sessionWindow,
            now: now) == nil)
    }

    @Test func midWindowIsHalfElapsed() throws {
        // 2.5h remaining of a 5h window → half the window has elapsed.
        let fraction = try #require(ProfileUsagePresentation.elapsedFraction(
            resetsAt: now.addingTimeInterval(2.5 * 60 * 60),
            windowDuration: ProfileUsagePresentation.sessionWindow,
            now: now))
        #expect(abs(fraction - 0.5) < 1e-9)
    }

    @Test func resetBeyondTheWindowClampsToZeroNotNegative() throws {
        // reset 10h out on a 5h window → elapsed is negative; clamp to 0, stay in 0...1.
        let fraction = try #require(ProfileUsagePresentation.elapsedFraction(
            resetsAt: now.addingTimeInterval(10 * 60 * 60),
            windowDuration: ProfileUsagePresentation.sessionWindow,
            now: now))
        #expect(fraction >= 0)
        #expect(fraction <= 1)
        #expect(abs(fraction - 0) < 1e-9)
    }
}

// MARK: - Picker sort ordering

@Suite("ProfileUsagePresentation — picker sort")
struct PickerSortTests {
    @Test func healthiestSessionWindowSortsFirst() {
        let busy = entry(name: "Busy", loginIdentity: "b@x.co", usageSnapshot: snapshot(
            buckets: [bucket(kind: "session", percent: 80)]))
        let idle = entry(name: "Idle", loginIdentity: "i@x.co", usageSnapshot: snapshot(
            buckets: [bucket(kind: "session", percent: 5)]))

        let sorted = ProfileUsagePresentation.sortedForPicker([busy, idle])
        #expect(sorted.map(\.profile.name) == ["Idle", "Busy"])
    }

    @Test func equalPercentTieBreaksOnSoonestReset() {
        let later = entry(name: "Later", loginIdentity: "l@x.co", usageSnapshot: snapshot(
            buckets: [bucket(kind: "session", percent: 20, resetsAt: resetDate.addingTimeInterval(3600))]))
        let sooner = entry(name: "Sooner", loginIdentity: "s@x.co", usageSnapshot: snapshot(
            buckets: [bucket(kind: "session", percent: 20, resetsAt: resetDate)]))

        let sorted = ProfileUsagePresentation.sortedForPicker([later, sooner])
        #expect(sorted.map(\.profile.name) == ["Sooner", "Later"])
    }

    @Test func snapshotlessLoggedInProfilesFollowDataBackedOnes() {
        let noData = entry(name: "NoData", loginIdentity: "n@x.co")
        let withData = entry(name: "WithData", loginIdentity: "w@x.co", usageSnapshot: snapshot(
            buckets: [bucket(kind: "session", percent: 99)]))

        let sorted = ProfileUsagePresentation.sortedForPicker([noData, withData])
        #expect(sorted.map(\.profile.name) == ["WithData", "NoData"])
    }

    @Test func notLoggedInProfilesSortLastAndAreNotSelectable() {
        let needsLogin = entry(name: "Spare")   // oauth, no identity
        let loggedIn = entry(name: "Work", loginIdentity: "a@b.co")

        let sorted = ProfileUsagePresentation.sortedForPicker([needsLogin, loggedIn])
        #expect(sorted.map(\.profile.name) == ["Work", "Spare"])
        #expect(ProfileUsagePresentation.isSelectable(needsLogin) == false)
        #expect(ProfileUsagePresentation.isSelectable(loggedIn))
    }

    @Test func nonOAuthProfilesAreSelectableWithoutIdentity() {
        // apiKey/bedrock profiles have no login concept — never disabled.
        let proxy = entry(name: "Router", kind: .apiKey)
        #expect(ProfileUsagePresentation.isSelectable(proxy))
    }

    @Test func equalRanksPreserveOriginalOrder() {
        let first = entry(name: "First", loginIdentity: "f@x.co")
        let second = entry(name: "Second", loginIdentity: "s@x.co")
        let sorted = ProfileUsagePresentation.sortedForPicker([first, second])
        #expect(sorted.map(\.profile.name) == ["First", "Second"])
    }
}

// MARK: - Staleness

@Suite("ProfileUsagePresentation — staleness / honest states")
struct StalenessNoteTests {
    @Test func freshHealthySnapshotHasNoNote() {
        let now = Date()
        let fresh = snapshot(buckets: [], fetchedAt: now.addingTimeInterval(-30))
        #expect(ProfileUsagePresentation.stalenessNote(for: fresh, now: now) == nil)
    }

    @Test func neverFetchedSnapshotSaysNoDataYet() {
        let never = snapshot(buckets: [], fetchedAt: nil)
        #expect(ProfileUsagePresentation.stalenessNote(for: never) == "no usage data yet")
    }

    @Test func oldSnapshotReportsAgeInMinutes() {
        let now = Date()
        let old = snapshot(buckets: [], fetchedAt: now.addingTimeInterval(-600))
        #expect(ProfileUsagePresentation.stalenessNote(for: old, now: now) == "updated 10m ago")
    }

    @Test func missingSnapshotHasNoNote() {
        #expect(ProfileUsagePresentation.stalenessNote(for: nil) == nil)
    }

    // MARK: Typed failure states — each renders distinct, explicit copy.

    @Test func needsLoginRendersActionableNote() {
        let failing = snapshot(buckets: [], fetchedAt: nil,
                               status: "fetch failed: needs re-login (refresh token expired)",
                               statusKind: .needsLogin)
        #expect(ProfileUsagePresentation.stalenessNote(for: failing) == "needs re-login")
    }

    @Test func noCredentialsRendersNotLoggedIn() {
        let failing = snapshot(buckets: [], fetchedAt: nil,
                               status: "fetch failed: no credentials", statusKind: .noCredentials)
        #expect(ProfileUsagePresentation.stalenessNote(for: failing) == "not logged in")
    }

    @Test func rateLimitedWithoutPriorDataSaysRetrying() {
        let failing = snapshot(buckets: [], fetchedAt: nil,
                               status: "fetch failed: rate limited", statusKind: .rateLimited)
        #expect(ProfileUsagePresentation.stalenessNote(for: failing)
                == "usage unavailable — retrying")
    }

    @Test func rateLimitedWithPriorDataAppendsLastKnownAge() {
        let now = Date()
        // Older successful buckets exist; status now reflects a 429.
        let failing = snapshot(buckets: [bucket(kind: "session", percent: 20)],
                               fetchedAt: now.addingTimeInterval(-7200),
                               status: "stale since …; fetch failed: rate limited",
                               statusKind: .rateLimited)
        #expect(ProfileUsagePresentation.stalenessNote(for: failing, now: now)
                == "usage unavailable — retrying · last data 2h ago")
    }

    @Test func networkErrorSaysRetrying() {
        let failing = snapshot(buckets: [], fetchedAt: nil,
                               status: "fetch failed: network error: timed out",
                               statusKind: .networkError)
        #expect(ProfileUsagePresentation.stalenessNote(for: failing)
                == "usage unavailable — retrying")
    }

    @Test func unknownStatusFromOlderDaemonSaysRetrying() {
        // Older daemon: no statusKind field → inferred .unknown on decode.
        let failing = snapshot(buckets: [], fetchedAt: nil,
                               status: "fetch failed: HTTP 503", statusKind: .unknown)
        #expect(ProfileUsagePresentation.stalenessNote(for: failing)
                == "usage unavailable — retrying")
    }

    @Test func ageTextGranularity() {
        let now = Date()
        #expect(ProfileUsagePresentation.ageText(since: now.addingTimeInterval(-30), now: now) == "just now")
        #expect(ProfileUsagePresentation.ageText(since: now.addingTimeInterval(-180), now: now) == "3m")
        #expect(ProfileUsagePresentation.ageText(since: now.addingTimeInterval(-7200), now: now) == "2h")
        #expect(ProfileUsagePresentation.ageText(since: now.addingTimeInterval(-172800), now: now) == "2d")
    }
}

// MARK: - Secondary menu line honesty (menuLine composition)

@Suite("ProfileUsagePresentation — secondary line honesty")
struct SecondaryLineHonestyTests {
    @Test func healthyFreshShowsUsageNumbers() {
        let line = ProfileUsagePresentation.secondaryLine(for: gmailSnapshot, timeZone: utc)
        #expect(line == "5h 0% used · resets 11:10pm · week 76% · Fable 100%")
    }

    @Test func rateLimitedProfileShowsRetryNoteNotStaleNumbers() {
        // Even though old buckets exist, a 429 snapshot must not present them as
        // current — the retry note carries the row.
        let now = Date()
        let stale = ProfileUsageSnapshot(
            buckets: gmailSnapshot.buckets,
            fetchedAt: now.addingTimeInterval(-3600),
            lastAttemptAt: now,
            status: "stale since …; fetch failed: rate limited",
            statusKind: .rateLimited)
        let line = ProfileUsagePresentation.secondaryLine(for: stale, timeZone: utc, now: now)
        #expect(line == "usage unavailable — retrying · last data 1h ago")
    }

    @Test func needsLoginProfileShowsReloginNote() {
        let needs = ProfileUsageSnapshot(
            buckets: [], fetchedAt: nil, lastAttemptAt: Date(),
            status: "fetch failed: needs re-login", statusKind: .needsLogin)
        #expect(ProfileUsagePresentation.secondaryLine(for: needs) == "needs re-login")
    }

    @Test func noSnapshotHasNoSecondaryLine() {
        #expect(ProfileUsagePresentation.secondaryLine(for: nil) == nil)
    }

    @Test func healthyButAgingAppendsAgeNote() {
        let now = Date()
        let aging = ProfileUsageSnapshot(
            buckets: [bucket(kind: "session", percent: 12)],
            fetchedAt: now.addingTimeInterval(-600),
            lastAttemptAt: now, status: "ok", statusKind: .ok)
        #expect(ProfileUsagePresentation.secondaryLine(for: aging, timeZone: utc, now: now)
                == "5h 12% used · updated 10m ago")
    }

    @Test func menuLineForFailingProfileHasHonestSecondary() {
        let entry = entry(name: "Gmail", loginIdentity: "g@x.co",
                          usageSnapshot: ProfileUsageSnapshot(
                            buckets: [], fetchedAt: nil, lastAttemptAt: Date(),
                            status: "fetch failed: needs re-login", statusKind: .needsLogin))
        let line = ProfileUsagePresentation.menuLine(for: entry)
        #expect(line.primary == "Gmail — g@x.co")
        #expect(line.secondary == "needs re-login")
    }
}

// MARK: - Session tooltips

@Suite("ProfileUsagePresentation — session tooltip")
struct SessionTooltipTests {
    @Test func pinnedLoggedInSessionShowsAccountUsageAndSpawnTime() {
        let gmail = entry(name: "Gmail", loginIdentity: "g@x.co", usageSnapshot: gmailSnapshot)
        let terminal = claudeTerminal(profileID: gmail.profile.id,
                                      createdAt: resetDate)

        let tooltip = ProfileUsagePresentation.sessionTooltip(
            terminal: terminal, profiles: [gmail], timeZone: utc
        )
        #expect(tooltip == """
        Account: g@x.co (Gmail)
        Usage: 5h 0% ↺11:10pm · wk 76% · F 100%
        Spawned: 2026-07-03 23:10
        """)
    }

    @Test func ambientSessionShowsDriftWarning() {
        let terminal = claudeTerminal(profileID: nil, createdAt: resetDate,
                                      kind: nil, claudeSessionID: "abc")
        let tooltip = ProfileUsagePresentation.sessionTooltip(
            terminal: terminal, profiles: [], timeZone: utc
        )
        #expect(tooltip == """
        Account: ambient (terminal login)
        May drift to a different account on token refresh
        Spawned: 2026-07-03 23:10
        """)
    }

    @Test func pinnedSessionWithoutSnapshotOmitsUsageLine() {
        let work = entry(name: "Work", loginIdentity: "a@b.co")
        let terminal = claudeTerminal(profileID: work.profile.id, createdAt: resetDate)
        let tooltip = ProfileUsagePresentation.sessionTooltip(
            terminal: terminal, profiles: [work], timeZone: utc
        )
        #expect(tooltip == "Account: a@b.co (Work)\nSpawned: 2026-07-03 23:10")
    }

    @Test func removedProfileIsCalledOut() {
        let terminal = claudeTerminal(profileID: UUID())
        let tooltip = ProfileUsagePresentation.sessionTooltip(terminal: terminal, profiles: [])
        #expect(tooltip?.contains("profile removed — session keeps its spawn account") == true)
    }

    @Test func nonClaudeTerminalsHaveNoTooltip() {
        let shell = claudeTerminal(kind: .shell)
        let codex = claudeTerminal(kind: .codex, claudeSessionID: "x")
        #expect(ProfileUsagePresentation.sessionTooltip(terminal: shell, profiles: []) == nil)
        #expect(ProfileUsagePresentation.sessionTooltip(terminal: codex, profiles: []) == nil)
    }

    @Test func pinnedButNotLoggedInShowsProfileNameWithLoginState() {
        let spare = entry(name: "Spare")   // oauth, nil identity
        let terminal = claudeTerminal(profileID: spare.profile.id)
        let tooltip = ProfileUsagePresentation.sessionTooltip(terminal: terminal, profiles: [spare])
        #expect(tooltip?.contains("Account: Spare (not logged in)") == true)
    }
}

// MARK: - Worktree row tooltip

@Suite("ProfileUsagePresentation — worktree accounts tooltip")
struct WorktreeAccountsTooltipTests {
    @Test func aggregatesAndDedupesClaudeAccountsInOrder() {
        let work = entry(name: "Work", loginIdentity: "a@b.co")
        let terminals = [
            claudeTerminal(profileID: work.profile.id),
            claudeTerminal(profileID: nil, kind: nil, claudeSessionID: "legacy"),
            claudeTerminal(profileID: work.profile.id),   // duplicate account
            claudeTerminal(kind: .shell),                 // ignored
        ]
        let tooltip = ProfileUsagePresentation.worktreeAccountsTooltip(
            terminals: terminals, profiles: [work]
        )
        #expect(tooltip == "Claude accounts: a@b.co (Work), ambient (terminal login)")
    }

    @Test func noClaudeSessionsMeansNoTooltip() {
        let terminals = [claudeTerminal(kind: .shell)]
        #expect(ProfileUsagePresentation.worktreeAccountsTooltip(terminals: terminals, profiles: []) == nil)
    }
}

// MARK: - Snapshot merge (AppState)

@Suite("AppState.mergingUsageSnapshots")
struct MergingUsageSnapshotsTests {
    @Test func mergesReturnedSnapshotsAndPreservesOtherFields() {
        let gmail = entry(name: "Gmail", loginIdentity: "g@x.co")
        let work = entry(name: "Work", loginIdentity: "a@b.co", usageSnapshot: gmailSnapshot)

        let fresh = snapshot(buckets: [bucket(kind: "session", percent: 42)])
        let merged = AppState.mergingUsageSnapshots(
            into: [gmail, work],
            entries: [ModelProfileUsageSnapshotEntry(profileID: gmail.profile.id, snapshot: fresh)]
        )

        #expect(merged[0].usageSnapshot == fresh)
        #expect(merged[0].loginIdentity == "g@x.co")
        #expect(merged[0].profile == gmail.profile)
        // Untouched profile keeps its cached snapshot.
        #expect(merged[1].usageSnapshot == gmailSnapshot)
    }

    @Test func emptySweepLeavesProfilesUntouched() {
        let work = entry(name: "Work", usageSnapshot: gmailSnapshot)
        let merged = AppState.mergingUsageSnapshots(into: [work], entries: [])
        #expect(merged == [work])
    }
}

// MARK: - "Use default without asking" persistence

@MainActor
@Suite("AppState skipAccountPicker persistence")
struct SkipAccountPickerPersistenceTests {
    private func withIsolatedDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "TBDAppTests.SkipAccountPicker.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }

    @Test func defaultsToAskingEveryTime() {
        withIsolatedDefaults { defaults in
            let state = AppState(userDefaults: defaults)
            #expect(state.skipAccountPicker == false)
        }
    }

    @Test func togglePersistsToInjectedSuiteAndReloadsOnInit() {
        withIsolatedDefaults { defaults in
            let state = AppState(userDefaults: defaults)
            state.skipAccountPicker = true

            #expect(defaults.bool(forKey: "com.tbd.app.accountPicker.useDefaultWithoutAsking"))
            // A fresh AppState over the same suite reads the persisted value.
            let reloaded = AppState(userDefaults: defaults)
            #expect(reloaded.skipAccountPicker)

            // Toggling back off round-trips too (both branches of the gate).
            reloaded.skipAccountPicker = false
            #expect(defaults.bool(forKey: "com.tbd.app.accountPicker.useDefaultWithoutAsking") == false)
            #expect(AppState(userDefaults: defaults).skipAccountPicker == false)
        }
    }

    @Test func writesDoNotTouchStandardDefaults() {
        withIsolatedDefaults { defaults in
            let key = "com.tbd.app.accountPicker.useDefaultWithoutAsking"
            let prior = UserDefaults.standard.object(forKey: key)
            defer {
                if let prior {
                    UserDefaults.standard.set(prior, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }

            let state = AppState(userDefaults: defaults)
            state.skipAccountPicker = true
            #expect(UserDefaults.standard.object(forKey: key) == nil || prior != nil)
        }
    }
}

// MARK: - Relative weekly reset (granularity matches window scale)

@Suite("CompactResetCountdown")
struct CompactResetCountdownTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func minutesUnderAnHour() {
        let resets = now.addingTimeInterval(48 * 60)
        #expect(ProfileUsagePresentation.compactResetCountdown(resets, now: now) == "48m")
    }

    @Test func hoursDropMinutes() {
        let resets = now.addingTimeInterval((3 * 60 + 20) * 60)
        #expect(ProfileUsagePresentation.compactResetCountdown(resets, now: now) == "3h")
    }

    @Test func hourScaleKeepsMinutesWhenAsked() {
        // The session window's countdown form: "2h 10m", not a lossy "2h".
        let resets = now.addingTimeInterval((2 * 60 + 10) * 60)
        #expect(ProfileUsagePresentation.compactResetCountdown(
            resets, now: now, minutesAtHourScale: true) == "2h 10m")
    }

    @Test func hourScaleWithZeroMinutesStaysBare() {
        let resets = now.addingTimeInterval(2 * 3600)
        #expect(ProfileUsagePresentation.compactResetCountdown(
            resets, now: now, minutesAtHourScale: true) == "2h")
    }

    @Test func minutesAtHourScaleLeavesSubHourAndDayScalesUnchanged() {
        let subHour = now.addingTimeInterval(48 * 60)
        #expect(ProfileUsagePresentation.compactResetCountdown(
            subHour, now: now, minutesAtHourScale: true) == "48m")
        let dayScale = now.addingTimeInterval(((2 * 24 + 5) * 60 + 10) * 60)
        #expect(ProfileUsagePresentation.compactResetCountdown(
            dayScale, now: now, minutesAtHourScale: true) == "2d 5h")
    }

    @Test func daysCarryHourRemainder() {
        let resets = now.addingTimeInterval(((2 * 24 + 5) * 60 + 10) * 60)
        #expect(ProfileUsagePresentation.compactResetCountdown(resets, now: now) == "2d 5h")
    }

    @Test func exactDaysOmitHours() {
        let resets = now.addingTimeInterval(3 * 24 * 60 * 60)
        #expect(ProfileUsagePresentation.compactResetCountdown(resets, now: now) == "3d")
    }

    @Test func pastInstantYieldsNil() {
        let resets = now.addingTimeInterval(-60)
        #expect(ProfileUsagePresentation.compactResetCountdown(resets, now: now) == nil)
    }

    @Test func weeklyResetAppearsOnceInDetailLine() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let weeklyReset = now.addingTimeInterval(((2 * 24 + 5) * 60 + 10) * 60)
        let snap = snapshot(buckets: [
            bucket(kind: "session", percent: 16, severity: "normal", resetsAt: resetDate),
            bucket(kind: "weekly_all", percent: 79, severity: "normal", resetsAt: weeklyReset),
            bucket(kind: "weekly_scoped", percent: 45, severity: "normal",
                   resetsAt: weeklyReset, family: "Fable"),
        ])
        let line = ProfileUsagePresentation.usageDetailLine(for: snap, timeZone: utc, now: now)
        #expect(line == "5h 16% used · resets 11:10pm · week 79% · resets in 2d 5h · Fable 45%")
        // The shared weekly instant renders once (on the week segment), not per family.
        #expect(line?.components(separatedBy: "resets in").count == 2)
    }
}

// MARK: - Clock formatting (am/pm)

@Suite("ProfileUsagePresentation — reset clock text")
struct ResetClockTextTests {
    /// Build a UTC instant from wall-clock components.
    private func utcDate(month: Int, day: Int, hour: Int, minute: Int,
                         second: Int = 0) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: components)!
    }

    @Test func eveningRendersTwelveHourWithPM() {
        #expect(ProfileUsagePresentation.resetTimeText(
            utcDate(month: 7, day: 3, hour: 19, minute: 59), timeZone: utc) == "7:59pm")
    }

    @Test func morningRendersTwelveHourWithAM() {
        #expect(ProfileUsagePresentation.resetTimeText(
            utcDate(month: 7, day: 3, hour: 9, minute: 5), timeZone: utc) == "9:05am")
    }

    @Test func midnightAndNoonUseTwelve() {
        #expect(ProfileUsagePresentation.resetTimeText(
            utcDate(month: 7, day: 3, hour: 0, minute: 15), timeZone: utc) == "12:15am")
        #expect(ProfileUsagePresentation.resetTimeText(
            utcDate(month: 7, day: 3, hour: 12, minute: 0), timeZone: utc) == "12pm")
    }

    @Test func clockFormDropsMinutesOnTheHour() {
        #expect(ProfileUsagePresentation.resetTimeText(
            utcDate(month: 7, day: 3, hour: 20, minute: 0), timeZone: utc) == "8pm")
    }

    @Test func secondsUnderTheHourCeilToNextHour() {
        // The API's reset instants land a fraction under the hour; a flooring
        // formatter renders the misleading "7:59pm" — ceil to the minute first.
        #expect(ProfileUsagePresentation.resetTimeText(
            utcDate(month: 7, day: 3, hour: 19, minute: 59, second: 59), timeZone: utc) == "8pm")
        #expect(ProfileUsagePresentation.weekdayResetTimeText(
            utcDate(month: 7, day: 3, hour: 17, minute: 59, second: 59), timeZone: utc) == "Fri 6pm")
    }

    @Test func exactHalfHourKeepsMinutes() {
        #expect(ProfileUsagePresentation.resetTimeText(
            utcDate(month: 7, day: 3, hour: 19, minute: 30), timeZone: utc) == "7:30pm")
    }

    @Test func weekdayFormCarriesWeekdayAndMinutes() {
        // 2026-07-03 is a Friday.
        #expect(ProfileUsagePresentation.weekdayResetTimeText(
            utcDate(month: 7, day: 3, hour: 18, minute: 59), timeZone: utc) == "Fri 6:59pm")
    }

    @Test func weekdayFormDropsMinutesOnTheHour() {
        #expect(ProfileUsagePresentation.weekdayResetTimeText(
            utcDate(month: 7, day: 3, hour: 19, minute: 0), timeZone: utc) == "Fri 7pm")
        #expect(ProfileUsagePresentation.weekdayResetTimeText(
            utcDate(month: 7, day: 6, hour: 9, minute: 0), timeZone: utc) == "Mon 9am")
    }
}
