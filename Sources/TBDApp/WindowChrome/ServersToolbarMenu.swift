import Foundation
import TBDShared

/// What choosing a Servers menu item does. The AppKit toolbar maps each case
/// onto the same `AppState` call the SwiftUI menu makes.
enum ServersMenuCommand: Equatable {
    case open(url: String)
    case showLastOutput(serverName: String)
    case stop(names: [String])
    case restart(names: [String])
    /// Empty `names` starts every declared server.
    case start(names: [String])
    case refreshStatus
}

/// One row of the Servers menu, as a value.
enum ServersMenuEntry: Equatable {
    case item(title: String, isEnabled: Bool, command: ServersMenuCommand)
    case header(String)
    case note(String)
    case separator
}

/// The Servers menu the toolbar builds each time it opens: the main URL first
/// (D4), then each server with its state, its URLs and its actions; then Start
/// all / Stop all / Refresh status; then parse errors and the last action's
/// failures.
enum ServersToolbarMenu {
    nonisolated static func entries(list: DevServerListResult, messages: [String]) -> [ServersMenuEntry] {
        var result: [ServersMenuEntry] = []
        if let primaryURL = AppState.primaryDevServerURL(list),
           let lead = ServersButtonLabel.leadItemTitle(primaryURL: primaryURL) {
            result.append(.item(title: lead, isEnabled: true, command: .open(url: primaryURL)))
            result.append(.separator)
        }
        for server in list.servers {
            result.append(.header(ServersButtonLabel.menuTitle(for: server)))
            for endpoint in server.endpoints {
                result.append(.item(title: "Open \(endpoint.name) — \(endpoint.url)", isEnabled: true,
                                    command: .open(url: endpoint.url)))
            }
            if server.state == .exited {
                result.append(.item(title: "Show last output",
                                    isEnabled: server.lastOutputID != nil || server.terminalID != nil,
                                    command: .showLastOutput(serverName: server.name)))
            }
            if let stopTitle = ServersButtonLabel.stopItemTitle(for: server) {
                result.append(.item(title: stopTitle, isEnabled: true, command: .stop(names: [server.name])))
            }
            if server.state == .running || server.state == .unknown {
                if server.isDeclared {
                    result.append(.item(title: "Restart", isEnabled: true, command: .restart(names: [server.name])))
                }
            } else if server.isDeclared {
                result.append(.item(title: "Start", isEnabled: true, command: .start(names: [server.name])))
            }
        }
        result.append(.separator)
        result.append(.item(title: "Start all",
                            isEnabled: list.servers.contains { $0.isDeclared && $0.state != .running },
                            command: .start(names: [])))
        let stopAllNames = ServersButtonLabel.stopAllNames(list)
        result.append(.item(title: "Stop all", isEnabled: !stopAllNames.isEmpty, command: .stop(names: stopAllNames)))
        result.append(.item(title: "Refresh status", isEnabled: true, command: .refreshStatus))
        let problems = list.parseErrors.map { "\(($0.path as NSString).lastPathComponent): \($0.message)" } + messages
        if !problems.isEmpty {
            result.append(.separator)
            result.append(contentsOf: problems.map { ServersMenuEntry.note($0) })
        }
        return result
    }
}
