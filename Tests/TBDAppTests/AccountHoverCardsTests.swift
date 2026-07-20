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
                                                   profiles: [gmail], timeZone: utc, now: resetDate)
        #expect(card?.title == "g@gmail.com")
        #expect(card?.titleStyle == .plain)
        let rows = card?.rows ?? []
        #expect(rows.count == 5)
        #expect(rows[0] == HoverCardRow(label: "Profile", value: "Gmail"))
        #expect(rows[1] == HoverCardRow(label: "5h window", value: "0% · resets at 11:10 pm",
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

    // The "Show usage tooltip on Claude tabs" setting gate
    // (AppState.showClaudeTabUsageTooltipKey), both branches. Pure `enabled:`
    // parameter — no UserDefaults involved.
    @Test func settingEnabledProducesCardForClaudeTerminal() {
        let card = AccountHoverCards.claudeTabCard(terminal: claudeTerminal(),
                                                   profiles: [], timeZone: utc,
                                                   enabled: true)
        #expect(card != nil)
        // Ungated behavior is unchanged: same content as the default-argument path.
        #expect(card == AccountHoverCards.claudeTabCard(terminal: claudeTerminal(),
                                                        profiles: [], timeZone: utc))
    }

    @Test func settingDisabledSuppressesCardEvenForClaudeTerminal() {
        let gmail = entry(name: "Gmail", loginIdentity: "g@gmail.com",
                          usageSnapshot: gmailSnapshot)
        let terminal = claudeTerminal(profileID: gmail.profile.id)
        #expect(AccountHoverCards.claudeTabCard(terminal: terminal,
                                                profiles: [gmail], timeZone: utc,
                                                enabled: false) == nil)
        #expect(AccountHoverCards.claudeTabCard(terminal: claudeTerminal(),
                                                profiles: [], timeZone: utc,
                                                enabled: false) == nil)
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
        // Tint now uses pace-aware fill level (from BucketPresentation) instead of just severity.
        // Without elapsed fraction, the fill = severity floor, so behavior is the same.
        let normal = ProfileUsagePresentation.bucketPresentation(
            bucket(kind: "session", percent: 10, severity: "normal"), timeZone: utc)
        #expect(AccountHoverCards.tint(for: normal) == .normal)

        let warning = ProfileUsagePresentation.bucketPresentation(
            bucket(kind: "session", percent: 80, severity: "warning"), timeZone: utc)
        #expect(AccountHoverCards.tint(for: warning) == .warning)

        let critical = ProfileUsagePresentation.bucketPresentation(
            bucket(kind: "session", percent: 99, severity: "critical"), timeZone: utc)
        #expect(AccountHoverCards.tint(for: critical) == .critical)

        // API omitted severity: falls back to percent thresholds (no elapsed fraction).
        let normalNoSeverity = ProfileUsagePresentation.bucketPresentation(
            bucket(kind: "session", percent: 10), timeZone: utc)
        #expect(AccountHoverCards.tint(for: normalNoSeverity) == .normal)

        let criticalNoSeverity = ProfileUsagePresentation.bucketPresentation(
            bucket(kind: "session", percent: 92), timeZone: utc)
        #expect(AccountHoverCards.tint(for: criticalNoSeverity) == .critical)
    }

    @Test func scopedBucketWithoutFamilyNameFallsBackToModelLabel() {
        let rows = AccountHoverCards.usageRows(
            for: snapshot(buckets: [bucket(kind: "weekly_scoped", percent: 50)]),
            timeZone: utc, now: Date()
        )
        #expect(rows.first?.label == "Model")
    }
}

// MARK: - Dwell reducer (show-gate state machine)

@Suite("HoverDwellReducer — dwell-gated show")
struct HoverDwellReducerTests {
    // Deliberately round numbers so the arithmetic in each test reads clearly.
    private let timing = HoverCardTiming(
        showDelay: 0.50, restWindow: 0.20, movementThreshold: 3,
        warmDwell: 0.15, warmGrace: 0.40, fadeOutDuration: 0.12
    )
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    private func fresh() -> HoverDwellReducer { HoverDwellReducer(timing: timing) }
    private func at(_ dt: TimeInterval) -> Date { t0.addingTimeInterval(dt) }

    /// Convenience: cold-hover evaluation (no card up, never dismissed).
    private func cold(_ r: inout HoverDwellReducer, _ dt: TimeInterval) -> Bool {
        r.shouldShow(now: at(dt), lastDismissedAt: nil, isCardVisible: false)
    }

    // MARK: Cold path — floor AND rest must both pass

    @Test func coldHoverDoesNotShowBeforeFloorEvenWhenAtRest() {
        var r = fresh()
        r.entered(now: t0)
        // Rest window (0.20) satisfied but floor (0.50) not yet.
        #expect(cold(&r, 0.30) == false)
    }

    @Test func coldHoverDoesNotShowBeforeRestEvenAfterFloor() {
        var r = fresh()
        r.entered(now: t0)
        // Keep moving right up to just before evaluation: never at rest.
        r.moved(distance: 10, now: at(0.55))
        #expect(cold(&r, 0.60) == false) // only 0.05s at rest < 0.20
    }

    @Test func coldHoverShowsOnceFloorAndRestBothPass() {
        var r = fresh()
        r.entered(now: t0)
        // No movement: resting since entry. At 0.50, floor met and rest (0.50) met.
        #expect(cold(&r, 0.50) == true)
    }

    @Test func showLatchesAndFiresExactlyOnce() {
        var r = fresh()
        r.entered(now: t0)
        #expect(cold(&r, 0.50) == true)
        // Subsequent ticks must not re-fire.
        #expect(cold(&r, 0.60) == false)
        #expect(cold(&r, 1.00) == false)
    }

    // MARK: Movement resets the rest clock (hover intent)

    @Test func aboveThresholdMoveResetsTheRestClock() {
        var r = fresh()
        r.entered(now: t0)
        // A big move at 0.45 (past the floor) restarts rest; at 0.55 only
        // 0.10s at rest < 0.20 → still hidden.
        r.moved(distance: 20, now: at(0.45))
        #expect(cold(&r, 0.55) == false)
        // By 0.66, >0.20s at rest → shows. (Evaluate a hair past the boundary
        // so the assertion doesn't hinge on exact Double equality.)
        #expect(cold(&r, 0.66) == true)
    }

    @Test func subThresholdJitterDoesNotResetRest() {
        var r = fresh()
        r.entered(now: t0)
        // Tiny jitter below the 3pt threshold must not push the rest clock.
        r.moved(distance: 1, now: at(0.40))
        r.moved(distance: 2, now: at(0.48))
        #expect(cold(&r, 0.50) == true) // rest still measured from entry
    }

    @Test func sweepThroughNeverShows() {
        // Cursor crosses the anchor moving the whole time, then leaves before
        // ever settling — the drive-by case the user complained about.
        var r = fresh()
        r.entered(now: t0)
        for step in stride(from: 0.02, through: 0.30, by: 0.02) {
            r.moved(distance: 15, now: at(step))
            #expect(cold(&r, step) == false)
        }
        r.exited()
        #expect(r.enteredAt == nil)
    }

    // MARK: Warm swap — reduced floor, short dwell, still gated

    @Test func warmSwapNeedsWarmDwellNotInstant() {
        var r = fresh()
        r.entered(now: t0)
        // Card already visible (sibling swap): floor collapses to 0, but the
        // warm dwell (0.15) still applies. At 0.10 at rest → hidden.
        #expect(r.shouldShow(now: at(0.10), lastDismissedAt: nil, isCardVisible: true) == false)
        // Just past 0.15 at rest → shows (a hair past the boundary to avoid
        // hinging on exact Double equality).
        #expect(r.shouldShow(now: at(0.16), lastDismissedAt: nil, isCardVisible: true) == true)
    }

    @Test func warmSweepDoesNotSwap() {
        var r = fresh()
        r.entered(now: t0)
        // Moving the whole time through a sibling while a card is up: never
        // settles for the warm dwell, so no chase.
        r.moved(distance: 12, now: at(0.05))
        r.moved(distance: 12, now: at(0.12))
        #expect(r.shouldShow(now: at(0.13), lastDismissedAt: nil, isCardVisible: true) == false)
    }

    @Test func recentDismissalIsWarmAndUsesWarmDwell() {
        var r = fresh()
        r.entered(now: t0)
        let justDismissed = t0.addingTimeInterval(-0.10) // within 0.40 grace
        // Warm: floor 0, needs only 0.15 at rest.
        #expect(r.shouldShow(now: at(0.10), lastDismissedAt: justDismissed,
                             isCardVisible: false) == false)
        #expect(r.shouldShow(now: at(0.16), lastDismissedAt: justDismissed,
                             isCardVisible: false) == true)
    }

    @Test func staleDismissalIsColdAgain() {
        var r = fresh()
        r.entered(now: t0)
        let longAgo = t0.addingTimeInterval(-1.0) // past the 0.40 grace
        // Cold: still needs the full 0.50 floor.
        #expect(r.shouldShow(now: at(0.20), lastDismissedAt: longAgo,
                             isCardVisible: false) == false)
        #expect(r.shouldShow(now: at(0.50), lastDismissedAt: longAgo,
                             isCardVisible: false) == true)
    }

    // MARK: Exit clears state

    @Test func exitClearsAndRequiresReentry() {
        var r = fresh()
        r.entered(now: t0)
        r.exited()
        // No entry → never shows regardless of clock.
        #expect(cold(&r, 5.0) == false)
        // Re-entry restarts the cold gate cleanly.
        r.entered(now: at(5.0))
        #expect(r.shouldShow(now: at(5.30), lastDismissedAt: nil, isCardVisible: false) == false)
        #expect(r.shouldShow(now: at(5.50), lastDismissedAt: nil, isCardVisible: false) == true)
    }
}

@Suite("HoverCardTiming — standard constants")
struct HoverCardTimingTests {
    @Test func coldFloorIsInTheResearchedRange() {
        // Upper end of the 300–500ms consensus, raised for the "just passing
        // through" complaint — kept sane (< 1s HIG default).
        #expect(HoverCardTiming.standard.showDelay >= 0.5)
        #expect(HoverCardTiming.standard.showDelay < 1.0)
    }

    @Test func restWindowIsAShortDwell() {
        #expect(HoverCardTiming.standard.restWindow >= 0.12)
        #expect(HoverCardTiming.standard.restWindow <= 0.25)
    }

    @Test func warmDwellIsShorterThanColdFloorButNonZero() {
        // Responsive swap, but never an instant cursor-chase.
        #expect(HoverCardTiming.standard.warmDwell > 0)
        #expect(HoverCardTiming.standard.warmDwell < HoverCardTiming.standard.showDelay)
    }

    @Test func fadeOutIsQuickerThanShow() {
        #expect(HoverCardTiming.standard.fadeOutDuration < HoverCardTiming.standard.showDelay)
    }
}
