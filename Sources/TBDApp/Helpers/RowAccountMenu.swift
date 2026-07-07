import Foundation
import TBDShared

/// Naming helper for a worktree row's Claude sessions, used when composing the
/// row's action menu (`RowActionMenuActions`). Per-session account facts and
/// switching live in the tab bar, not on the worktree row.
enum RowAccountMenu {
    /// Human handle for a session. Prefers the terminal's own label; falls back
    /// to "Claude N" using the caller's Claude-session index.
    static func sessionLabel(terminal: Terminal, fallbackIndex: Int) -> String {
        if let label = terminal.label?.trimmingCharacters(in: .whitespacesAndNewlines),
           !label.isEmpty {
            return label
        }
        return "Claude \(fallbackIndex)"
    }
}
