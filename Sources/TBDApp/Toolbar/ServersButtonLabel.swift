import AppKit
import SwiftUI
import TBDShared

/// The Servers button's wording and icon: its title, its accessibility label,
/// its menu's titles, and one baked icon (green when something runs), for
/// `MainToolbarSnapshot`, `ServersToolbarMenu`, the toolbar's item and the
/// status bar's Servers chip (`ServersChipPresentation`), which uses the
/// wording but draws its own glyph.
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

    @MainActor private static var bakedIconCache: [String: NSImage] = [:]

    /// `server.rack`, tinted green when a server runs and secondary-label
    /// otherwise, baked into a non-template image — draw, `color.set()`, fill
    /// with `.sourceAtop`, `isTemplate = false` — so a toolbar control that
    /// tints template images keeps the color.
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
