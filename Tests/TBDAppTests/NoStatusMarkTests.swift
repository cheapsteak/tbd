import Foundation
import Testing
@testable import TBDApp
import TBDShared

// Tier 1: pure functions; no daemon, no sleeps.

/// The sidebar's no-status mark: which terminals it is for, when it shows, and
/// the tooltip text by transport.
/// Design: `docs/specs/2026-10-30-osc-only-agent-status-design.md`, "Sessions
/// that cannot report".
@Suite("NoStatusMark")
struct NoStatusMarkTests {

    // MARK: - Fixtures

    private static let stamp = Date(timeIntervalSince1970: 1_800_000_000)
    private static let incarnation = UUID()

    private static func terminal(
        kind: TerminalKind? = .claude,
        label: String? = nil,
        activity: TerminalActivityState = .unknown,
        transport: TerminalTransport = .tmux,
        incarnation: UUID? = NoStatusMarkTests.incarnation,
        hibernated: Bool = false,
        suspended: Bool = false
    ) -> TBDShared.Terminal {
        TBDShared.Terminal(
            worktreeID: UUID(),
            tmuxWindowID: transport == .tmux ? "@1" : "",
            tmuxPaneID: transport == .tmux ? "%1" : "",
            label: label,
            suspendedAt: suspended ? stamp : nil,
            sessionIncarnationID: incarnation,
            kind: kind,
            activityState: activity,
            hibernatedAt: hibernated ? stamp : nil,
            transport: transport)
    }

    private static let elapsed = NoStatusSighting(incarnationID: incarnation, graceElapsed: true)

    // MARK: - Text

    @Test func theTooltipTextIsExact() {
        #expect(NoStatusMark.tmuxHelp
            == "The tmux transport doesn't carry agent status. Status needs the pty-holder transport.")
        #expect(NoStatusMark.holderHelp
            == "This session isn't reporting status. Status needs Claude Code 2.1.295 or later, or Codex 0.163.0 or later. A session started before this version of TBD reports after it is relaunched.")
        #expect(NoStatusMark.grace == .seconds(15))
    }

    @Test func theTooltipNamesTheTransport() {
        #expect(NoStatusMark.help(for: Self.terminal(transport: .tmux), sighting: Self.elapsed)
            == NoStatusMark.tmuxHelp)
        #expect(NoStatusMark.help(for: Self.terminal(transport: .holder), sighting: Self.elapsed)
            == NoStatusMark.holderHelp)
        #expect(NoStatusMark.help(
            for: Self.terminal(kind: .codex, transport: .holder), sighting: Self.elapsed)
            == NoStatusMark.holderHelp)
    }

    // MARK: - When it shows

    @Test func noMarkBeforeTheGraceRunsOut() {
        let waiting = NoStatusSighting(incarnationID: Self.incarnation, graceElapsed: false)
        #expect(NoStatusMark.help(for: Self.terminal(), sighting: waiting) == nil)
        #expect(NoStatusMark.help(for: Self.terminal(), sighting: nil) == nil)
    }

    @Test func aSightingOfAnotherIncarnationShowsNothing() {
        let other = NoStatusSighting(incarnationID: UUID(), graceElapsed: true)
        #expect(NoStatusMark.help(for: Self.terminal(), sighting: other) == nil)
        let legacy = NoStatusSighting(incarnationID: nil, graceElapsed: true)
        #expect(NoStatusMark.help(for: Self.terminal(), sighting: legacy) == nil)
        // The same shape for the row's own incarnation does show.
        #expect(NoStatusMark.help(for: Self.terminal(incarnation: nil), sighting: legacy)
            == NoStatusMark.tmuxHelp)
    }

    @Test func claudeCodexAndLegacyAgentRowsAreCandidates() {
        #expect(NoStatusMark.isCandidate(Self.terminal(kind: .claude)))
        #expect(NoStatusMark.isCandidate(Self.terminal(kind: .codex)))
        #expect(NoStatusMark.isCandidate(Self.terminal(kind: nil)))
        #expect(NoStatusMark.isCandidate(Self.terminal(kind: nil, label: TerminalLabel.codex)))
    }

    @Test func aShellNeverShowsTheMark() {
        let shell = Self.terminal(kind: .shell)
        #expect(!NoStatusMark.isCandidate(shell))
        #expect(NoStatusMark.help(for: shell, sighting: Self.elapsed) == nil)
    }

    @Test func aParkedRowNeverShowsTheMark() {
        let hibernated = Self.terminal(hibernated: true)
        let suspended = Self.terminal(suspended: true)
        #expect(!NoStatusMark.isCandidate(hibernated))
        #expect(!NoStatusMark.isCandidate(suspended))
        #expect(NoStatusMark.help(for: hibernated, sighting: Self.elapsed) == nil)
        #expect(NoStatusMark.help(for: suspended, sighting: Self.elapsed) == nil)
    }

    @Test func aRowWithStateNeverShowsTheMark() {
        for activity in [TerminalActivityState.idle, .working, .waitingForUser] {
            let row = Self.terminal(activity: activity)
            #expect(!NoStatusMark.isCandidate(row), "\(activity)")
            #expect(NoStatusMark.help(for: row, sighting: Self.elapsed) == nil, "\(activity)")
        }
    }

    // MARK: - The row

    @Test func theRowJoinsEachCauseOnceTmuxFirst() {
        let holder = Self.terminal(transport: .holder)
        let tmux = Self.terminal(transport: .tmux)
        let secondTmux = Self.terminal(kind: .codex, transport: .tmux)
        let shell = Self.terminal(kind: .shell)
        let sightings = Dictionary(
            uniqueKeysWithValues: [holder, tmux, secondTmux, shell].map { ($0.id, Self.elapsed) })

        #expect(NoStatusMark.rowHelp(terminals: [holder, tmux, secondTmux, shell], sightings: sightings)
            == NoStatusMark.tmuxHelp + "\n\n" + NoStatusMark.holderHelp)
        #expect(NoStatusMark.rowHelp(terminals: [holder, shell], sightings: sightings)
            == NoStatusMark.holderHelp)
        #expect(NoStatusMark.rowHelp(terminals: [shell], sightings: sightings) == nil)
        #expect(NoStatusMark.rowHelp(terminals: [holder, tmux], sightings: [:]) == nil)
    }
}
