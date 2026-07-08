import Foundation
import Testing
@testable import TBDApp
import TBDShared

// MARK: - Fixtures

private let utc = TimeZone(identifier: "UTC")!

/// 2026-07-03 23:10:00 UTC — renders as "23:10" in the UTC fixtures below.
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

/// The live-verified Gmail shape: 5h 0% resetting 23:10, weekly 76%, Fable 100%.
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
        #expect(suffix == " · 5h 0% ↺23:10 · wk 76% · F 100%")
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
                == "Gmail — g@x.co · 5h 0% ↺23:10 · wk 76% · F 100%")
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
        #expect(line == "5h 0% used · resets 23:10 · week 76% · Fable 100%")
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
                == "5h 16% used · resets 23:10 · week 79%")
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
        #expect(line.secondary == "5h 0% used · resets 23:10 · week 76% · Fable 100%")
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
        #expect(line == "5h 0% used · resets 23:10 · week 76% · Fable 100%")
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
        Usage: 5h 0% ↺23:10 · wk 76% · F 100%
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

@Suite("RelativeResetText")
struct RelativeResetTextTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func minutesUnderAnHour() {
        let resets = now.addingTimeInterval(48 * 60)
        #expect(ProfileUsagePresentation.relativeResetText(resets, now: now) == "48m")
    }

    @Test func hoursDropMinutes() {
        let resets = now.addingTimeInterval((3 * 60 + 20) * 60)
        #expect(ProfileUsagePresentation.relativeResetText(resets, now: now) == "3h")
    }

    @Test func daysCarryHourRemainder() {
        let resets = now.addingTimeInterval(((2 * 24 + 5) * 60 + 10) * 60)
        #expect(ProfileUsagePresentation.relativeResetText(resets, now: now) == "2d 5h")
    }

    @Test func exactDaysOmitHours() {
        let resets = now.addingTimeInterval(3 * 24 * 60 * 60)
        #expect(ProfileUsagePresentation.relativeResetText(resets, now: now) == "3d")
    }

    @Test func pastInstantYieldsNil() {
        let resets = now.addingTimeInterval(-60)
        #expect(ProfileUsagePresentation.relativeResetText(resets, now: now) == nil)
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
        #expect(line == "5h 16% used · resets 23:10 · week 79% · resets in 2d 5h · Fable 45%")
        // The shared weekly instant renders once (on the week segment), not per family.
        #expect(line?.components(separatedBy: "resets in").count == 2)
    }
}
