import AppKit
import SwiftUI

struct ExternalEditor {
    let name: String
    let bundleID: String
}

private let knownEditors: [ExternalEditor] = [
    ExternalEditor(name: "Cursor",          bundleID: "com.todesktop.230313mzl4w4u92"),
    ExternalEditor(name: "VS Code",         bundleID: "com.microsoft.VSCode"),
    ExternalEditor(name: "Xcode",           bundleID: "com.apple.dt.Xcode"),
    ExternalEditor(name: "Sublime Text",    bundleID: "com.sublimetext.4"),
    ExternalEditor(name: "Tower",           bundleID: "com.fournova.Tower3"),
    ExternalEditor(name: "GitHub Desktop",  bundleID: "com.github.GitHubClient"),
    ExternalEditor(name: "DataGrip",        bundleID: "com.jetbrains.datagrip"),
    ExternalEditor(name: "IntelliJ IDEA",   bundleID: "com.jetbrains.intellij"),
    ExternalEditor(name: "IntelliJ IDEA CE", bundleID: "com.jetbrains.intellij.ce"),
    ExternalEditor(name: "Finder",          bundleID: "com.apple.finder"),
]

// Resolved once per process: each lookup is a Launch Services round-trip
// (~10 `urlForApplication` calls for the full list), and the installed-app
// set is process-stable — paying it per body evaluation made every hover
// toggle re-query Launch Services. An editor installed mid-session appears
// after the next app launch.
private let installedEditors: [(editor: ExternalEditor, appURL: URL)] = knownEditors.compactMap { editor in
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundleID) else { return nil }
    return (editor, url)
}

private let intelliJBundleIDs: Set<String> = ["com.jetbrains.intellij", "com.jetbrains.intellij.ce"]

private func findIdeaCLIScript() -> String? {
    let candidates = [
        NSString(string: "~/Library/Application Support/JetBrains/Toolbox/scripts/idea").expandingTildeInPath,
        NSString(string: "~/.local/bin/idea").expandingTildeInPath,
        "/usr/local/bin/idea",
        "/opt/homebrew/bin/idea",
    ]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

private func openInEditor(path: String, bundleID: String) {
    if bundleID == "com.apple.finder" {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
        return
    }
    if intelliJBundleIDs.contains(bundleID), let script = findIdeaCLIScript() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: script)
        process.arguments = [path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        return
    }
    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
    NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: appURL, configuration: .init(), completionHandler: nil)
}

// `repoID` is nil for scratch spaces (repo-less worktrees); the "scratch"
// sentinel keys their recent-editor list separately from any real repo.
private func recentKey(repoID: UUID?) -> String {
    "openInEditor.recent.\(repoID?.uuidString ?? "scratch")"
}

private func loadRecentBundleIDs(repoID: UUID?) -> [String] {
    guard let data = UserDefaults.standard.data(forKey: recentKey(repoID: repoID)),
          let ids = try? JSONDecoder().decode([String].self, from: data) else {
        return knownEditors.map(\.bundleID)
    }
    return ids
}

private func recordUsed(bundleID: String, repoID: UUID?) {
    var ids = loadRecentBundleIDs(repoID: repoID)
    ids.removeAll { $0 == bundleID }
    ids.insert(bundleID, at: 0)
    if let data = try? JSONEncoder().encode(ids) {
        UserDefaults.standard.set(data, forKey: recentKey(repoID: repoID))
    }
}

struct OpenInEditorButton: View {
    let path: String
    let repoID: UUID?
    /// Runs at the start of every open action (pinned icon click and overflow
    /// menu selection alike) — e.g. to make sure `path` exists on disk before
    /// the target app is asked to open it. Default nil keeps existing call
    /// sites unchanged.
    var beforeOpen: (() -> Void)? = nil

    @State private var recentBundleIDs: [String] = []
    @State private var hovering: String? = nil

    private var available: [(editor: ExternalEditor, appURL: URL)] { installedEditors }

    /// App icons keyed by app path. The NSImage must be identity-stable
    /// across body evaluations — `Image(nsImage:)` diffs by object identity,
    /// so a fresh `NSWorkspace.icon(forFile:)` per render rebuilt every
    /// pinned editor's icon layer on each hover toggle. Same rationale as
    /// `WorktreeRowView.iconCache`. MainActor confinement (SwiftUI body runs
    /// on main) makes this safe without locks.
    @MainActor
    private static var iconCache: [String: NSImage] = [:]

    // Internal (not private) so OpenInEditorIconCacheTests can assert the
    // identity-stability invariant, mirroring WorktreeRowView.loadIcon.
    @MainActor
    static func appIcon(forPath path: String) -> NSImage {
        if let cached = iconCache[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        iconCache[path] = icon
        return icon
    }

    private var pinnedEditors: [(editor: ExternalEditor, appURL: URL)] {
        let byID = Dictionary(uniqueKeysWithValues: available.map { ($0.editor.bundleID, $0) })
        var result: [(editor: ExternalEditor, appURL: URL)] = []
        for bundleID in recentBundleIDs {
            if let entry = byID[bundleID] {
                result.append(entry)
                if result.count == 3 { break }
            }
        }
        if result.count < 3 {
            let pinnedIDs = Set(result.map(\.editor.bundleID))
            for entry in available where !pinnedIDs.contains(entry.editor.bundleID) {
                result.append(entry)
                if result.count == 3 { break }
            }
        }
        return result
    }

    private var overflowEditors: [(editor: ExternalEditor, appURL: URL)] {
        let pinnedIDs = Set(pinnedEditors.map(\.editor.bundleID))
        return available.filter { !pinnedIDs.contains($0.editor.bundleID) }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(pinnedEditors, id: \.editor.bundleID) { entry in
                Image(nsImage: Self.appIcon(forPath: entry.appURL.path))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(hovering == entry.editor.bundleID ? Color.primary.opacity(0.08) : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .onHover { hovering = $0 ? entry.editor.bundleID : nil }
                    .onTapGesture { open(entry: entry) }
                    .help("Open in \(entry.editor.name)")
            }

            if !overflowEditors.isEmpty {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 12, height: 16)
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(hovering == "__chevron" ? Color.primary.opacity(0.08) : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .onHover { hovering = $0 ? "__chevron" : nil }
                    .onTapGesture { showOverflowMenu() }
                    .help("More editors")
            }
        }
        .onAppear { recentBundleIDs = loadRecentBundleIDs(repoID: repoID) }
        .onChange(of: repoID) { _, _ in recentBundleIDs = loadRecentBundleIDs(repoID: repoID) }
    }

    private func open(entry: (editor: ExternalEditor, appURL: URL)) {
        beforeOpen?()
        openInEditor(path: path, bundleID: entry.editor.bundleID)
        recordUsed(bundleID: entry.editor.bundleID, repoID: repoID)
        recentBundleIDs = loadRecentBundleIDs(repoID: repoID)
    }

    private func showOverflowMenu() {
        let menu = NSMenu()
        let coordinator = EditorMenuCoordinator()
        for entry in overflowEditors {
            let item = NSMenuItem(title: entry.editor.name, action: nil, keyEquivalent: "")
            let icon = NSWorkspace.shared.icon(forFile: entry.appURL.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            coordinator.actions[item] = { open(entry: entry) }
            item.target = coordinator
            item.action = #selector(EditorMenuCoordinator.selectItem(_:))
            menu.addItem(item)
        }
        objc_setAssociatedObject(menu, "editorCoordinator", coordinator, .OBJC_ASSOCIATION_RETAIN)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

private class EditorMenuCoordinator: NSObject {
    var actions: [NSMenuItem: () -> Void] = [:]

    @objc func selectItem(_ sender: NSMenuItem) {
        actions[sender]?()
    }
}
