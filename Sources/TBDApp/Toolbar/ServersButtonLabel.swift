import Foundation
import TBDShared

/// The Servers chip's wording: its title, its accessibility label and its
/// menu's titles, for the status bar's Servers chip
/// (`ServersChipPresentation`) and its menu (`ServersToolbarMenu`).
enum ServersButtonLabel {
    static func runningCount(_ list: DevServerListResult) -> Int {
        list.servers.filter { $0.state == .running }.count
    }

    static func accessibilityLabel(runningCount: Int) -> String {
        runningCount > 0 ? "Dev servers, \(runningCount) running" : "Dev servers"
    }

    static func title(runningCount: Int) -> String {
        runningCount > 0 ? "\(runningCount) running" : "Servers"
    }

    static func menuTitle(for server: DevServerInfo) -> String {
        let state: String
        switch server.state {
        case .running: state = "running"
        case .exited: state = server.exitCode.map { "exited (code \($0))" } ?? "exited"
        case .stopped: state = "stopped"
        case .unknown: state = "unknown"
        }
        return "\(server.label) — \(state) · \(server.source ?? "undeclared")"
    }

    /// The per-server stop item's title, or nil when the menu offers none.
    /// "Stop" for a server that runs or may run; "Close" for one that has
    /// nothing running but still has a TBD tab — an exited server, declared
    /// or not, which the daemon clears by closing that tab. Without it, an
    /// exited server whose declaration is gone could not be cleared from the
    /// menu at all. A live running file always reads as running.
    static func stopItemTitle(for server: DevServerInfo) -> String? {
        switch server.state {
        case .running, .unknown: return "Stop"
        case .exited, .stopped: return server.terminalID != nil ? "Close" : nil
        }
    }

    /// The servers "Stop all" acts on: every server that offers a stop item.
    /// Empty disables the item.
    static func stopAllNames(_ list: DevServerListResult) -> [String] {
        list.servers.filter { stopItemTitle(for: $0) != nil }.map { $0.name }
    }

    /// The menu's first item (decision D4): present whenever a running
    /// server has reported a main URL.
    static func leadItemTitle(primaryURL: String?) -> String? {
        primaryURL.map { "Open \($0)" }
    }
}
