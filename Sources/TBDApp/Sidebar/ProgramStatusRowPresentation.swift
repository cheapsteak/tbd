import Foundation
import TBDShared

/// Pure presentation of Program Status Protocol (OSC 7501) snapshots for a
/// sidebar worktree row: whether a snapshot speaks for a terminal, and the
/// plain-text tooltip the row's status badge carries.
///
/// A terminal this returns nothing for — flag off, not OSC-authoritative,
/// parked, or a snapshot from another incarnation — keeps today's hook-rail
/// presentation unchanged.
/// Design: `docs/specs/2026-10-10-program-status-protocol-design.md`, "UI".
enum ProgramStatusRowPresentation {
    /// The OSC-authoritative state of `terminal`, or nil unless the flag is on
    /// and `snapshot` speaks for this process: a parked terminal's process is
    /// gone, and a snapshot accepted for another incarnation describes a
    /// process that no longer runs in this row.
    static func resolution(
        terminal: TBDShared.Terminal,
        snapshot: ProgramStatusSnapshot?,
        enabled: Bool
    ) -> ProgramStatusResolution? {
        guard enabled, let snapshot else { return nil }
        guard !terminal.isParked else { return nil }
        guard snapshot.incarnationID == terminal.sessionIncarnationID else { return nil }
        return ProgramStatusRollup.resolve(snapshot)
    }

    /// The label a terminal goes by in the tooltip.
    static func tooltipLabel(for terminal: TBDShared.Terminal) -> String {
        if let label = terminal.label, !label.isEmpty { return label }
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
