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

private func claudeTerminal(id: UUID = UUID(),
                            label: String? = nil,
                            profileID: UUID? = nil,
                            createdAt: Date = Date(timeIntervalSince1970: 0),
                            kind: TerminalKind? = .claude) -> Terminal {
    Terminal(id: id, worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
             label: label, createdAt: createdAt, profileID: profileID, kind: kind)
}

/// Live-verified Gmail shape: 5h 0% resetting 23:10, weekly 76%, Fable 100%.
private let fableSnapshot = snapshot(buckets: [
    bucket(kind: "session", percent: 0, severity: "normal", resetsAt: resetDate),
    bucket(kind: "weekly_all", percent: 76, severity: "warning"),
    bucket(kind: "weekly_scoped", percent: 100, severity: "critical", family: "Fable"),
])

// MARK: - Model composition

@Suite("RowAccountMenu — model")
struct RowAccountMenuModelTests {
    @Test func noClaudeSessionsYieldsEmptyModel() {
        let shell = claudeTerminal(kind: .shell)
        let model = RowAccountMenu.model(terminals: [shell], profiles: [])
        #expect(model.isEmpty)
        #expect(model.sessions.isEmpty)
        #expect(RowAccountMenu.model(terminals: [], profiles: []).isEmpty)
    }

    @Test func oneSessionPerClaudeTerminalInTabOrder() {
        let work = entry(name: "Work", loginIdentity: "a@b.co")
        let t1 = claudeTerminal(label: "Claude 1", profileID: work.profile.id)
        let t2 = claudeTerminal(label: nil, profileID: nil)
        let model = RowAccountMenu.model(terminals: [t1, t2], profiles: [work])
        #expect(model.sessions.count == 2)
        #expect(model.sessions[0].terminalID == t1.id)
        #expect(model.sessions[1].terminalID == t2.id)
    }

    @Test func footerIsTheForkExplainer() {
        let model = RowAccountMenu.model(
            terminals: [claudeTerminal()], profiles: []
        )
        #expect(model.footer == RowAccountMenu.footerCaption)
        #expect(model.footer.contains("re-reads uncached once"))
    }
}

// MARK: - Session info header

@Suite("RowAccountMenu — session header")
struct RowAccountMenuSessionTests {
    @Test func pinnedLoggedInSessionDescribesEmailAndProfile() {
        let work = entry(name: "Work", loginIdentity: "a@b.co")
        let session = RowAccountMenu.session(
            terminal: claudeTerminal(label: "Agent", profileID: work.profile.id),
            fallbackIndex: 1, profiles: [work], timeZone: utc
        )
        #expect(session.label == "Agent")
        #expect(session.accountDescriptor == "a@b.co (Work)")
    }

    @Test func ambientSessionDescribesTerminalLogin() {
        let session = RowAccountMenu.session(
            terminal: claudeTerminal(profileID: nil),
            fallbackIndex: 2, profiles: [], timeZone: utc
        )
        #expect(session.accountDescriptor == "ambient (terminal login)")
    }

    @Test func removedProfileSessionKeepsNote() {
        let session = RowAccountMenu.session(
            terminal: claudeTerminal(profileID: UUID()),
            fallbackIndex: 1, profiles: [], timeZone: utc
        )
        #expect(session.accountDescriptor == "profile removed — session keeps its spawn account")
    }

    @Test func labelFallsBackToClaudeIndexWhenTerminalHasNoLabel() {
        #expect(RowAccountMenu.sessionLabel(terminal: claudeTerminal(label: nil),
                                            fallbackIndex: 3) == "Claude 3")
        #expect(RowAccountMenu.sessionLabel(terminal: claudeTerminal(label: "   "),
                                            fallbackIndex: 1) == "Claude 1")
        #expect(RowAccountMenu.sessionLabel(terminal: claudeTerminal(label: "Reviewer"),
                                            fallbackIndex: 1) == "Reviewer")
    }
}

// MARK: - Switch targets

@Suite("RowAccountMenu — switch targets")
struct RowAccountMenuSwitchTargetTests {
    @Test func currentAccountIsCheckmarkedDisabledAndEmitsNoAction() {
        let current = entry(name: "Work", loginIdentity: "a@b.co", usageSnapshot: fableSnapshot)
        let other = entry(name: "Personal", loginIdentity: "p@q.io", usageSnapshot: fableSnapshot)
        let targets = RowAccountMenu.switchTargets(
            currentProfileID: current.profile.id,
            profiles: [current, other], timeZone: utc
        )
        let currentTarget = targets.first { $0.profileID == current.profile.id }
        #expect(currentTarget?.isCurrent == true)
        // Current account is not a swap destination — no action emitted.
        #expect(currentTarget?.action(terminalID: UUID()) == nil)
    }

    @Test func loggedInNonCurrentProfileIsSelectableAndEmitsSwapAction() {
        let current = entry(name: "Work", loginIdentity: "a@b.co")
        let target = entry(name: "Personal", loginIdentity: "p@q.io")
        let terminalID = UUID()
        let targets = RowAccountMenu.switchTargets(
            currentProfileID: current.profile.id,
            profiles: [current, target], timeZone: utc
        )
        let row = targets.first { $0.profileID == target.profile.id }
        #expect(row?.isSelectable == true)
        #expect(row?.isCurrent == false)
        #expect(row?.disabledReason == nil)
        #expect(row?.action(terminalID: terminalID)
                == RowAccountMenu.RowAccountMenuAction(terminalID: terminalID,
                                                       newProfileID: target.profile.id))
    }

    @Test func notLoggedInProfileIsDisabledWithLoginHintAndNoAction() {
        let current = entry(name: "Work", loginIdentity: "a@b.co")
        let pending = entry(name: "Staging", loginIdentity: nil)
        let targets = RowAccountMenu.switchTargets(
            currentProfileID: current.profile.id,
            profiles: [current, pending], timeZone: utc
        )
        let row = targets.first { $0.profileID == pending.profile.id }
        #expect(row?.isSelectable == false)
        #expect(row?.disabledReason == RowAccountMenu.notLoggedInReason)
        #expect(row?.action(terminalID: UUID()) == nil)
    }

    @Test func switchTargetTitleCarriesCompactPerFamilyUsageSuffix() {
        let target = entry(name: "Fablework", loginIdentity: "f@x.co", usageSnapshot: fableSnapshot)
        let targets = RowAccountMenu.switchTargets(
            currentProfileID: nil, profiles: [target], timeZone: utc
        )
        let title = targets.first?.title ?? ""
        #expect(title.contains("f@x.co"))
        // Compact usage from ProfileUsagePresentation, incl. the per-family "F 100%".
        #expect(title.contains("5h 0% ↺23:10"))
        #expect(title.contains("wk 76%"))
        #expect(title.contains("F 100%"))
    }

    @Test func ambientSessionOffersEveryLoggedInProfileAsSelectable() {
        // An ambient session (nil profileID) has no current account, so every
        // logged-in profile is a live switch destination.
        let work = entry(name: "Work", loginIdentity: "a@b.co")
        let personal = entry(name: "Personal", loginIdentity: "p@q.io")
        let targets = RowAccountMenu.switchTargets(
            currentProfileID: nil, profiles: [work, personal], timeZone: utc
        )
        #expect(targets.count == 2)
        #expect(targets.allSatisfy { $0.isSelectable && !$0.isCurrent })
        #expect(targets.allSatisfy { $0.action(terminalID: UUID()) != nil })
    }
}
