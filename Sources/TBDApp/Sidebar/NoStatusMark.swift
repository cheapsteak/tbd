import Foundation
import TBDShared

/// What the app has seen of one agent terminal sitting at `.unknown`: the
/// incarnation it saw there, and whether that incarnation has stayed there for
/// the whole grace period. Memory only, kept by `AppState.noStatusSightings`.
struct NoStatusSighting: Equatable, Sendable {
    let incarnationID: UUID?
    var graceElapsed: Bool
}

/// Pure presentation of the sidebar's no-status mark: an agent session whose
/// state TBD does not know, because nothing has reported it.
///
/// The mark is drawn for a Claude or Codex terminal whose activity column reads
/// `.unknown`, that is neither parked nor gone, once the app has seen its
/// current incarnation in that state for `grace`. The grace keeps a starting
/// session from flashing the mark before its first report; the first accepted
/// report moves the column off `.unknown` and clears it. A terminal the app no
/// longer lists is gone, and an exit-stamped row is parked, so neither shows
/// it. Nor does a row whose `.unknown` the daemon stamped `.processLiveness`:
/// that is a child exit, an agent whose process is gone, which the version
/// tooltip would misexplain. Shell terminals never show it.
/// Design: `docs/specs/2026-10-30-osc-only-agent-status-design.md`, "Sessions
/// that cannot report".
enum NoStatusMark {
    /// How long an incarnation must sit at `.unknown` before the mark shows.
    static let grace: Duration = .seconds(15)

    static let systemImage = "antenna.radiowaves.left.and.right.slash"
    static let accessibilityLabel = "No agent status"

    /// The tooltip for a session on the tmux transport, which never reports.
    static let tmuxHelp =
        "The tmux transport doesn't carry agent status. Status needs the pty-holder transport."
    /// The tooltip for a holder session that has not reported.
    static let holderHelp =
        "This session isn't reporting status. Status needs Claude Code 2.1.295 or later, "
        + "or Codex 0.163.0 or later. A session started before this version of TBD reports "
        + "after it is relaunched."

    /// Whether `terminal` is the kind of row the mark is for: an agent that
    /// reports (Claude or Codex), not parked, with no state in its column for
    /// a reason other than its process having exited.
    static func isCandidate(_ terminal: TBDShared.Terminal) -> Bool {
        ProgramStatusProtocol.expectedApp(for: terminal) != nil
            && !terminal.isParked
            && terminal.activityState == .unknown
            && terminal.activityStateSource != .processLiveness
    }

    /// The mark's tooltip for `terminal`, or nil when it shows no mark: not a
    /// candidate, no sighting of its current incarnation, or the grace still
    /// running. The text names the cause from the terminal's transport.
    static func help(for terminal: TBDShared.Terminal, sighting: NoStatusSighting?) -> String? {
        guard isCandidate(terminal),
              let sighting,
              sighting.incarnationID == terminal.sessionIncarnationID,
              sighting.graceElapsed
        else { return nil }
        switch terminal.transport {
        case .tmux: return tmuxHelp
        case .holder: return holderHelp
        }
    }

    /// The tooltip for a sidebar row: each distinct cause among its terminals
    /// once, tmux first, separated by a blank line. Nil when no terminal of the
    /// row shows the mark.
    static func rowHelp(
        terminals: [TBDShared.Terminal],
        sightings: [UUID: NoStatusSighting]
    ) -> String? {
        let helps = Set(terminals.compactMap { help(for: $0, sighting: sightings[$0.id]) })
        let ordered = [tmuxHelp, holderHelp].filter { helps.contains($0) }
        return ordered.isEmpty ? nil : ordered.joined(separator: "\n\n")
    }
}
