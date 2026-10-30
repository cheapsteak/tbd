import Foundation
import TBDShared

/// Pure presentation of Program Status Protocol (OSC 7501) snapshots for a
/// sidebar worktree row: whether a snapshot speaks for a terminal, and the
/// plain-text tooltip the row's status badge carries.
///
/// A terminal this returns nothing for — not OSC-authoritative, parked, or a
/// snapshot from another incarnation — keeps today's hook-rail presentation
/// unchanged.
/// Design: `docs/specs/2026-10-10-program-status-protocol-design.md`, "UI".
enum ProgramStatusRowPresentation {
    /// The OSC-authoritative state of `terminal`, or nil unless `snapshot`
    /// speaks for this process: a parked terminal's process is gone, and a
    /// snapshot accepted for another incarnation describes a process that no
    /// longer runs in this row.
    static func resolution(
        terminal: TBDShared.Terminal,
        snapshot: ProgramStatusSnapshot?
    ) -> ProgramStatusResolution? {
        guard let snapshot else { return nil }
        guard !terminal.isParked else { return nil }
        guard snapshot.incarnationID == terminal.sessionIncarnationID else { return nil }
        return ProgramStatusRollup.resolve(snapshot)
    }

    /// The suffix badge an OSC-authoritative state selects, or nil for a
    /// state that selects none: idle and done (a done session shows like an
    /// idle one; the bold name already marks a finished turn the user has not
    /// read), unknown, and the TBD-owned states, which never come out of a
    /// resolution.
    static func suffixIndicator(for value: SessionStateValue) -> SuffixRowIndicator? {
        switch value {
        case .working: return .working
        case .awaitingInput: return .attention
        case .needsAuth: return .needsAuth
        case .error: return .turnFailed
        case .idle, .done, .rateLimited, .parked, .gone, .unknown: return nil
        }
    }

    /// The help text for the badge `selected`: the OSC tooltip when it
    /// describes that badge — some OSC-authoritative terminal resolves to the
    /// state that selects it — and otherwise the badge's generic help. An
    /// unread error notification, say, wins the badge over an OSC `working`,
    /// and a tooltip about working would mislabel it.
    static func badgeHelp(
        selected: SuffixRowIndicator,
        oscTooltip: String?,
        resolvedValues: [SessionStateValue],
        genericHelp: String
    ) -> String {
        guard let oscTooltip,
              resolvedValues.contains(where: { suffixIndicator(for: $0) == selected })
        else { return genericHelp }
        return oscTooltip
    }

    /// The label a terminal goes by in the tooltip: its own label, else its
    /// agent's name.
    static func tooltipLabel(for terminal: TBDShared.Terminal) -> String {
        if let label = terminal.label, !label.isEmpty { return label }
        if ProgramStatusProtocol.expectedApp(for: terminal) == ProgramStatusProtocol.codexApp {
            return "Codex"
        }
        return "Claude"
    }

    /// The tooltip text, one block per OSC-authoritative terminal:
    ///
    ///     <label>: <state>[ — <title>][ (<progress>%)]
    ///     <msg>
    ///       • <task title or id>: <task state>[ — <task msg>]
    ///
    /// Blocks are separated by a blank line. Entries without a main entry are
    /// skipped; nil when nothing is left.
    static func tooltip(terminals: [(label: String, snapshot: ProgramStatusSnapshot)]) -> String? {
        var blocks: [String] = []
        for item in terminals {
            guard let main = item.snapshot.main else { continue }
            var lines: [String] = []

            var head: String = "\(item.label): \(ProgramStatusRollup.mainValue(main).label)"
            if let title = main.title, !title.isEmpty {
                head += " — \(title)"
            }
            if let progress = main.progress {
                head += " (\(progress)%)"
            }
            lines.append(head)

            if let msg = main.msg, !msg.isEmpty {
                lines.append(msg)
            }

            for task in item.snapshot.tasks {
                let name: String
                if let title = task.entry.title, !title.isEmpty {
                    name = title
                } else {
                    name = task.id
                }
                var line: String = "  • \(name): \(task.entry.state.rawValue)"
                if let msg = task.entry.msg, !msg.isEmpty {
                    line += " — \(msg)"
                }
                lines.append(line)
            }

            blocks.append(lines.joined(separator: "\n"))
        }
        if blocks.isEmpty { return nil }
        return blocks.joined(separator: "\n\n")
    }
}
