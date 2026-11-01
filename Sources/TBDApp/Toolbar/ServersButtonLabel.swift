import AppKit
import SwiftUI
import TBDShared

/// The Servers split button's label: one baked icon (green when something
/// runs) and one string. See `Sources/TBDApp/CLAUDE.md` for why the colour is
/// baked and why there is exactly one image.
struct ServersButtonLabel: View {
    let list: DevServerListResult
    @Environment(\.colorScheme) private var colorScheme

    private var runningCount: Int { Self.runningCount(list) }

    nonisolated static func runningCount(_ list: DevServerListResult) -> Int {
        list.servers.filter { $0.state == .running }.count
    }

    var body: some View {
        // A `Label` so the toolbar `Menu`'s `.labelStyle(.titleAndIcon)`
        // applies: macOS 27 otherwise draws the item icon-only.
        Label {
            Text(verbatim: Self.title(runningCount: runningCount))
                .font(.caption)
                .fontWeight(.medium)
        } icon: {
            Image(nsImage: Self.bakedIcon(running: runningCount > 0, colorScheme: colorScheme))
                .renderingMode(.original)
        }
        .accessibilityLabel(Self.accessibilityLabel(runningCount: runningCount))
    }

    static func accessibilityLabel(runningCount: Int) -> String {
        runningCount > 0 ? "Dev servers, \(runningCount) running" : "Dev servers"
    }

    static func title(runningCount: Int) -> String {
        runningCount > 0 ? "\(runningCount) running" : "Servers"
    }

    nonisolated static func menuTitle(for server: DevServerInfo) -> String {
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
    nonisolated static func stopItemTitle(for server: DevServerInfo) -> String? {
        switch server.state {
        case .running, .unknown: return "Stop"
        case .exited, .stopped: return server.terminalID != nil ? "Close" : nil
        }
    }

    /// The servers "Stop all" acts on: every server that offers a stop item.
    /// Empty disables the item.
    nonisolated static func stopAllNames(_ list: DevServerListResult) -> [String] {
        list.servers.filter { stopItemTitle(for: $0) != nil }.map { $0.name }
    }

    /// Everything the label and the menu render, as a String — AppKit
    /// rebuilds the menu only when this changes (`Sources/TBDApp/CLAUDE.md`).
    static func splitButtonID(
        worktreeID: UUID, list: DevServerListResult, messages: [String], colorScheme: ColorScheme
    ) -> String {
        let servers = list.servers.map { server in
            [server.name, server.label, server.state.rawValue,
             server.exitCode.map { String($0) } ?? "-", server.source ?? "-",
             server.endpoints.map { "\($0.name)=\($0.url)" }.joined(separator: ","),
             // "Show last output" enables on either, and targets the entry first (D2).
             server.lastOutputID?.uuidString ?? "-", server.terminalID?.uuidString ?? "-"]
                .joined(separator: ":")
        }.joined(separator: ";")
        let errors = list.parseErrors.map { "\($0.path):\($0.message)" }.joined(separator: ";")
        return "servers-split-\(worktreeID.uuidString)-\(servers)-\(errors)"
            + "-\(messages.joined(separator: "|"))-\(colorScheme)"
    }

    /// The menu's first item (decision D4): present whenever a running
    /// server has reported a main URL, in both toolbar shapes.
    nonisolated static func leadItemTitle(primaryURL: String?) -> String? {
        primaryURL.map { "Open \($0)" }
    }

    @MainActor private static var bakedIconCache: [String: NSImage] = [:]

    /// `server.rack`, tinted green when a server runs and secondary-label
    /// otherwise; the same bake `PRButtonLabel.coloredIcon` performs — draw,
    /// `color.set()`, fill with `.sourceAtop`, `isTemplate = false`.
    @MainActor static func bakedIcon(running: Bool, colorScheme: ColorScheme) -> NSImage {
        let key = "\(running)-\(colorScheme)"
        if let cached = bakedIconCache[key] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        let base = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage(size: NSSize(width: 12, height: 12))
        let color: NSColor = running ? .systemGreen : .secondaryLabelColor
        let image = NSImage(size: base.size, flipped: false) { rect in
            // Colors resolve inside the draw handler, so dynamic colors pick
            // up the current appearance.
            base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        bakedIconCache[key] = image
        return image
    }
}
