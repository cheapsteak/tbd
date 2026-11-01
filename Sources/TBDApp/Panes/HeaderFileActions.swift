import AppKit
import Combine
import Foundation
import TBDShared

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
/// Only the app's bundle URL, so a lookup off the main actor can hand it back;
/// the submenu draws each app's icon when it is built.
struct OpenWithApp: Identifiable, Equatable, Sendable {
    let url: URL
    var id: URL { url }
    var displayName: String { appDisplayName(for: url) }
}

/// Applications registered to open the file at `path`, default app first
/// (the same ordered set Finder shows). Empty when the file does not exist or
/// no apps are registered — callers omit the submenu in that case.
/// Nonisolated, and it touches the disk and Launch Services, so views reach it
/// through `lookUpOpenWithApps(forPath:)`, off the main actor.
///
/// The task it runs in being cancelled skips each step not yet reached — the
/// file check, then the query — and returns an empty list, which a cancelled
/// caller drops. `fileExists` and `applicationsToOpen` are the disk and
/// Launch Services, unless a test stands in for them.
func openWithApps(
    forPath path: String,
    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
    applicationsToOpen: (URL) -> [URL] = { NSWorkspace.shared.urlsForApplications(toOpen: $0) }
) -> [OpenWithApp] {
    guard !Task.isCancelled, fileExists(path) else { return [] }
    guard !Task.isCancelled else { return [] }
    return applicationsToOpen(URL(fileURLWithPath: path)).map(OpenWithApp.init)
}

/// `openWithApps(forPath:)` on a detached task at utility priority, so the
/// file check and the Launch Services query never run on the main thread.
/// Cancelling the caller cancels the detached task too, so a lookup the view
/// abandoned (`OpenWithAppsLookup.stop`, or a newer lookup replacing it)
/// skips whatever query it has not started.
func lookUpOpenWithApps(forPath path: String) async -> [OpenWithApp] {
    let lookup = Task.detached(priority: .utility) { openWithApps(forPath: path) }
    return await withTaskCancellationHandler {
        await lookup.value
    } onCancel: {
        lookup.cancel()
    }
}

/// One view's Open With list (`apps`) for the file its menu acts on, looked
/// up off the main actor (`lookUpOpenWithApps`) when the view appears, when
/// its file changes, and each time the pointer enters it, so the right-click
/// that almost always follows a hover finds a file created since, or a
/// handler installed since, in the list.
///
/// At most one lookup is in flight: starting one cancels the one before it,
/// and the view disappearing cancels it too. A lookup's result is dropped
/// when it was cancelled, or when the view's file (`path`, which `show`
/// keeps current) is no longer the one it looked up, so a slow lookup for a
/// file the view has left behind never overwrites the list for the file it
/// shows now. A hover starts no lookup while one for the same file is in
/// flight.
///
/// A view owns one as a `@StateObject`, which builds it once per view
/// identity rather than on every init of the view, as `OwnChromeHolder`
/// is. It publishes only `apps`, and writes them only when a lookup changes
/// them: an equal write would re-evaluate the view.
@MainActor
final class OpenWithAppsLookup: ObservableObject {
    /// The applications Open With offers for `path`'s file, default first.
    @Published private(set) var apps: [OpenWithApp] = []
    /// The file the view's menu acts on now, nil for none.
    private(set) var path: String?
    /// The lookup in flight, if one is, and the file it is for.
    private var inFlight: (path: String, task: Task<Void, Never>)?
    private let lookUp: @MainActor (String) async -> [OpenWithApp]

    /// `lookUp` finds the apps for a file: `lookUpOpenWithApps` unless a
    /// test stands in for it.
    init(
        lookUp: @escaping @MainActor (String) async -> [OpenWithApp] = { await lookUpOpenWithApps(forPath: $0) }
    ) {
        self.lookUp = lookUp
    }

    /// The view appeared, or its file changed: `path` is its file now, and a
    /// lookup for it replaces any in flight. With no file the list empties
    /// and nothing is looked up.
    func show(path: String?) {
        self.path = path
        start()
    }

    /// The pointer entered the view: a fresh lookup for its file, unless one
    /// for that file is already in flight.
    func pointerEntered() {
        guard let path, inFlight?.path != path else { return }
        start()
    }

    /// The view disappeared: the lookup in flight is cancelled, and its result
    /// dropped. The list stays as it was.
    func stop() {
        inFlight?.task.cancel()
        inFlight = nil
    }

    private func start() {
        stop()
        guard let path else {
            if !apps.isEmpty { apps = [] }
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let lookUp = self?.lookUp else { return }
            let found = await lookUp(path)
            // Every start cancels the lookup before it, so one that was not
            // cancelled is the one in flight.
            guard let self, !Task.isCancelled else { return }
            self.inFlight = nil
            guard self.path == path, found != self.apps else { return }
            self.apps = found
        }
        inFlight = (path: path, task: task)
    }
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
