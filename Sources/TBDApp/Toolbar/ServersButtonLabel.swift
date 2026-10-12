import AppKit
import SwiftUI
import TBDShared

/// The Servers split button's label: one baked icon (green when something
/// runs) and one string. See `Sources/TBDApp/CLAUDE.md` for why the colour is
/// baked and why there is exactly one image.
struct ServersButtonLabel: View {
    let list: DevServerListResult
    @Environment(\.colorScheme) private var colorScheme

    private var runningCount: Int { list.servers.filter { $0.state == .running }.count }

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: Self.bakedIcon(running: runningCount > 0, colorScheme: colorScheme))
                .renderingMode(.original)
            Text(verbatim: Self.title(runningCount: runningCount))
                .font(.caption)
                .fontWeight(.medium)
        }
        .accessibilityLabel(runningCount > 0 ? "Dev servers, \(runningCount) running" : "Dev servers")
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
    static func leadItemTitle(primaryURL: String?) -> String? {
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
