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

private func snapshot(buckets: [ClaudeUsageLimitBucket]) -> ProfileUsageSnapshot {
    ProfileUsageSnapshot(buckets: buckets, fetchedAt: Date(),
                         lastAttemptAt: Date(), status: "ok")
}

private func entry(id: UUID = UUID(),
                   name: String,
                   loginIdentity: String? = nil,
                   usageSnapshot: ProfileUsageSnapshot? = nil) -> ModelProfileWithUsage {
    ModelProfileWithUsage(
        profile: ModelProfile(id: id, name: name, kind: .oauth),
        usage: nil,
        loginIdentity: loginIdentity,
        usageSnapshot: usageSnapshot
    )
}

private func claudeTerminal(profileID: UUID? = nil,
                            createdAt: Date = Date(timeIntervalSince1970: 0),
                            kind: TerminalKind? = .claude) -> Terminal {
    Terminal(worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
             createdAt: createdAt, profileID: profileID, kind: kind)
}

/// The live-verified Gmail shape: 5h 0% resetting 23:10, weekly 76%, Fable 100%.
private let gmailSnapshot = snapshot(buckets: [
    bucket(kind: "session", percent: 0, severity: "normal", resetsAt: resetDate),
    bucket(kind: "weekly_all", percent: 76, severity: "warning"),
    bucket(kind: "weekly_scoped", percent: 100, severity: "critical", family: "Fable"),
])

// MARK: - Worktree row card

@Suite("AccountHoverCards — worktree row")
struct WorktreeCardTests {
    @Test func noClaudeSessionsMeansNoCard() {
        let shell = claudeTerminal(kind: .shell)
        #expect(AccountHoverCards.worktreeCard(terminals: [shell], profiles: []) == nil)
        #expect(AccountHoverCards.worktreeCard(terminals: [], profiles: []) == nil)
    }

    @Test func titleAndOneRowPerAccount() {
        let work = entry(name: "Work", loginIdentity: "a@b.co")
        let personal = entry(name: "Personal", loginIdentity: "p@q.io")
        let terminals = [
            claudeTerminal(profileID: work.profile.id),
            claudeTerminal(profileID: personal.profile.id),
        ]
        let card = AccountHoverCards.worktreeCard(terminals: terminals,
                                                  profiles: [work, personal])
        #expect(card?.title == "Claude accounts")
        #expect(card?.rows.count == 2)
        #expect(card?.rows[0] == HoverCardRow(value: "a@b.co", chip: "Work"))
        #expect(card?.rows[1] == HoverCardRow(value: "p@q.io", chip: "Personal"))
    }

    @Test func duplicateAccountsAreDedupedInTabOrder() {
        let work = entry(name: "Work", loginIdentity: "a@b.co")
        let terminals = [
            claudeTerminal(profileID: work.profile.id),
            claudeTerminal(profileID: work.profile.id),
            claudeTerminal(profileID: nil),
            claudeTerminal(profileID: nil),
        ]
        let card = AccountHoverCards.worktreeCard(terminals: terminals, profiles: [work])
        #expect(card?.rows.count == 2)
        #expect(card?.rows[0].value == "a@b.co")
        #expect(card?.rows[1].value == AccountHoverCards.ambientAccountLabel)
    }

    @Test func ambientRowIsMutedItalicWithDriftCaption() {
        let row = AccountHoverCards.accountRow(profileID: nil, profiles: [])
        #expect(row.value == "ambient (terminal login)")
        #expect(row.valueStyle == .mutedItalic)
        #expect(row.caption == AccountHoverCards.ambientDriftCaption)
        #expect(row.chip == nil)
    }

    @Test func removedProfileRowIsMutedItalicWithCaption() {
        let row = AccountHoverCards.accountRow(profileID: UUID(), profiles: [])
        #expect(row.value == AccountHoverCards.removedProfileLabel)
        #expect(row.valueStyle == .mutedItalic)
        #expect(row.caption == AccountHoverCards.removedProfileCaption)
    }

    @Test func notLoggedInProfileRowShowsNameWithCaption() {
        let pending = entry(name: "Staging", loginIdentity: nil)
        let row = AccountHoverCards.accountRow(profileID: pending.profile.id,
                                               profiles: [pending])
        #expect(row.value == "Staging")
        #expect(row.chip == nil)
        #expect(row.caption == AccountHoverCards.notLoggedInCaption)
        #expect(row.valueStyle == .plain)
    }
}

// MARK: - Claude tab card

@Suite("AccountHoverCards — Claude tab")
struct ClaudeTabCardTests {
    @Test func nonClaudeTerminalsGetNoCard() {
        #expect(AccountHoverCards.claudeTabCard(terminal: claudeTerminal(kind: .shell),
                                                profiles: []) == nil)
        #expect(AccountHoverCards.claudeTabCard(terminal: claudeTerminal(kind: .codex),
                                                profiles: []) == nil)
    }

    @Test func pinnedLoggedInCardHasEmailTitleProfileUsageAndSpawnRows() {
        let gmail = entry(name: "Gmail", loginIdentity: "g@gmail.com",
                          usageSnapshot: gmailSnapshot)
        let terminal = claudeTerminal(profileID: gmail.profile.id,
                                      createdAt: resetDate)
        let card = AccountHoverCards.claudeTabCard(terminal: terminal,
                                                   profiles: [gmail], timeZone: utc)
        #expect(card?.title == "g@gmail.com")
        #expect(card?.titleStyle == .plain)
        let rows = card?.rows ?? []
        #expect(rows.count == 5)
        #expect(rows[0] == HoverCardRow(label: "Profile", value: "Gmail"))
        #expect(rows[1] == HoverCardRow(label: "5h window", value: "0% · resets 23:10",
                                        monospacedDigits: true, tint: .normal))
        #expect(rows[2] == HoverCardRow(label: "Week", value: "76%",
                                        monospacedDigits: true, tint: .warning))
        #expect(rows[3] == HoverCardRow(label: "Fable", value: "100%",
                                        monospacedDigits: true, tint: .critical))
        #expect(rows[4] == HoverCardRow(label: "Spawned", value: "2026-07-03 23:10",
                                        monospacedDigits: true))
    }

    @Test func ambientCardHasMutedTitleAndDriftCaptionAndNoUsage() {
        let card = AccountHoverCards.claudeTabCard(terminal: claudeTerminal(),
                                                   profiles: [], timeZone: utc)
        #expect(card?.title == AccountHoverCards.ambientAccountLabel)
        #expect(card?.titleStyle == .mutedItalic)
        #expect(card?.titleCaption == AccountHoverCards.ambientDriftCaption)
        // Only the spawn row — ambient sessions have no pinned usage to show.
        #expect(card?.rows.count == 1)
        #expect(card?.rows.first?.label == "Spawned")
        #expect(card?.rows.first?.value == "1970-01-01 00:00")
    }

    @Test func removedProfileCardKeepsSpawnRow() {
        let card = AccountHoverCards.claudeTabCard(terminal: claudeTerminal(profileID: UUID()),
                                                   profiles: [], timeZone: utc)
        #expect(card?.title == AccountHoverCards.removedProfileLabel)
        #expect(card?.titleStyle == .mutedItalic)
        #expect(card?.titleCaption == AccountHoverCards.removedProfileCaption)
        #expect(card?.rows.count == 1)
        #expect(card?.rows.first?.label == "Spawned")
    }

    @Test func notLoggedInPinnedProfileTitlesByProfileName() {
        let pending = entry(name: "Staging", loginIdentity: "  ")
        let card = AccountHoverCards.claudeTabCard(
            terminal: claudeTerminal(profileID: pending.profile.id),
            profiles: [pending], timeZone: utc
        )
        #expect(card?.title == "Staging")
        #expect(card?.titleCaption == AccountHoverCards.notLoggedInCaption)
        // No Profile row (the title IS the profile), no usage rows.
        #expect(card?.rows.map(\.label) == ["Spawned"])
    }

    @Test func profileWithoutSnapshotGetsNoUsageRows() {
        let work = entry(name: "Work", loginIdentity: "a@b.co", usageSnapshot: nil)
        let card = AccountHoverCards.claudeTabCard(
            terminal: claudeTerminal(profileID: work.profile.id),
            profiles: [work], timeZone: utc
        )
        #expect(card?.rows.map(\.label) == ["Profile", "Spawned"])
    }
}

// MARK: - Usage rows

@Suite("AccountHoverCards — usage rows")
struct UsageRowsTests {
    @Test func emptySnapshotYieldsNoRows() {
        #expect(AccountHoverCards.usageRows(for: nil).isEmpty)
        #expect(AccountHoverCards.usageRows(for: snapshot(buckets: [])).isEmpty)
    }

    @Test func sessionRowOmitsResetWhenAbsent() {
        let rows = AccountHoverCards.usageRows(
            for: snapshot(buckets: [bucket(kind: "session", percent: 42)]),
            timeZone: utc
        )
        #expect(rows == [HoverCardRow(label: "5h window", value: "42%",
                                      monospacedDigits: true, tint: .normal)])
    }

    @Test func allUsageValuesUseMonospacedDigits() {
        let rows = AccountHoverCards.usageRows(for: gmailSnapshot, timeZone: utc)
        #expect(!rows.isEmpty)
        #expect(rows.allSatisfy { $0.monospacedDigits })
    }

    @Test func tintIsCalmForNormalAndColoredOnlyForWarningCritical() {
        #expect(AccountHoverCards.tint(for: bucket(kind: "session", percent: 10,
                                                   severity: "normal")) == .normal)
        #expect(AccountHoverCards.tint(for: bucket(kind: "session", percent: 80,
                                                   severity: "warning")) == .warning)
        #expect(AccountHoverCards.tint(for: bucket(kind: "session", percent: 99,
                                                   severity: "critical")) == .critical)
        // API omitted severity: falls back to percent thresholds.
        #expect(AccountHoverCards.tint(for: bucket(kind: "session", percent: 10)) == .normal)
        #expect(AccountHoverCards.tint(for: bucket(kind: "session", percent: 92)) == .critical)
    }

    @Test func scopedBucketWithoutFamilyNameFallsBackToModelLabel() {
        let rows = AccountHoverCards.usageRows(
            for: snapshot(buckets: [bucket(kind: "weekly_scoped", percent: 50)]),
            timeZone: utc
        )
        #expect(rows.first?.label == "Model")
    }
}

// MARK: - Hover timing

@Suite("HoverCardTiming — warm-state show delay")
struct HoverCardTimingTests {
    private let timing = HoverCardTiming(showDelay: 0.35, warmGrace: 0.35,
                                         fadeOutDuration: 0.12)
    private let now = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test func coldHoverWaitsTheFullShowDelay() {
        #expect(timing.effectiveShowDelay(now: now, lastDismissedAt: nil,
                                          isCardVisible: false) == 0.35)
    }

    @Test func visibleCardSwapsInstantly() {
        #expect(timing.effectiveShowDelay(now: now, lastDismissedAt: nil,
                                          isCardVisible: true) == 0)
    }

    @Test func recentDismissalIsWarmAndSkipsTheDelay() {
        let justDismissed = now.addingTimeInterval(-0.2)
        #expect(timing.effectiveShowDelay(now: now, lastDismissedAt: justDismissed,
                                          isCardVisible: false) == 0)
    }

    @Test func staleDismissalIsColdAgain() {
        let longAgo = now.addingTimeInterval(-1.0)
        #expect(timing.effectiveShowDelay(now: now, lastDismissedAt: longAgo,
                                          isCardVisible: false) == 0.35)
    }

    @Test func standardTimingIsFastButNotFlickery() {
        #expect(HoverCardTiming.standard.showDelay > 0.1)
        #expect(HoverCardTiming.standard.showDelay <= 0.5)
        #expect(HoverCardTiming.standard.fadeOutDuration < HoverCardTiming.standard.showDelay)
    }
}
