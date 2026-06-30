import AppKit
import Foundation

// MARK: - Header menu target resolution (pure)

/// The file a pane header's context menu acts on, plus the wording of its
/// copy button. `nil` from `headerMenuTarget` means the pane has no associated
/// file and should show no context menu at all.
struct HeaderMenuTarget: Equatable {
    let path: String
    let copyLabel: String
}

/// Resolve the header context-menu target for a pane.
///
/// - `.codeViewer` acts on its file path ("Copy Path").
/// - `.liveTranscript` acts on the session `.jsonl` (passed in as
///   `transcriptPath`, since resolving it needs the terminal model) and keeps
///   the existing "Copy Conversation Path" wording.
/// - All other panes (and empty/nil paths) return `nil` → no menu.
func headerMenuTarget(for content: PaneContent, transcriptPath: String?) -> HeaderMenuTarget? {
    switch content {
    case .codeViewer(_, let path):
        return path.isEmpty ? nil : HeaderMenuTarget(path: path, copyLabel: "Copy Path")
    case .liveTranscript:
        guard let transcriptPath, !transcriptPath.isEmpty else { return nil }
        return HeaderMenuTarget(path: transcriptPath, copyLabel: "Copy Conversation Path")
    case .terminal, .webview, .note:
        return nil
    }
}

// MARK: - Open With app resolution

/// An application that can open a file, as offered by the "Open With" submenu.
struct OpenWithApp: Identifiable, Equatable {
    let url: URL
    var id: URL { url }
    var displayName: String { appDisplayName(for: url) }
}

/// Applications registered to open the file at `path`, default app first
/// (the same ordered set Finder shows). Empty when the file does not exist or
/// no apps are registered — callers omit the submenu in that case.
func openWithApps(forPath path: String) -> [OpenWithApp] {
    guard FileManager.default.fileExists(atPath: path) else { return [] }
    let fileURL = URL(fileURLWithPath: path)
    return NSWorkspace.shared.urlsForApplications(toOpen: fileURL).map(OpenWithApp.init)
}

/// Human-readable app name from its bundle URL
/// ("Visual Studio Code.app" → "Visual Studio Code").
func appDisplayName(for appURL: URL) -> String {
    appURL.deletingPathExtension().lastPathComponent
}

// MARK: - Actions

/// Replace the general pasteboard contents with `string`.
func copyToPasteboard(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}

/// Reveal the file at `path` in Finder with it selected.
func revealInFinder(path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
}

/// Open the file at `path` with the application bundle at `appURL`.
func openFile(path: String, withApp appURL: URL) {
    NSWorkspace.shared.open(
        [URL(fileURLWithPath: path)],
        withApplicationAt: appURL,
        configuration: NSWorkspace.OpenConfiguration()
    )
}
