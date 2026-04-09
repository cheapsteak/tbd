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
    ExternalEditor(name: "Finder",          bundleID: "com.apple.finder"),
]

private func installedEditors() -> [(editor: ExternalEditor, appURL: URL)] {
    knownEditors.compactMap { editor in
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundleID) else { return nil }
        return (editor, url)
    }
}

private func openInEditor(path: String, bundleID: String) {
    if bundleID == "com.apple.finder" {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
        return
    }
    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
    let fileURL = URL(fileURLWithPath: path)
    NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: .init(), completionHandler: nil)
}

struct OpenInEditorButton: View {
    let path: String

    @AppStorage("openInEditor.preferredBundleID") private var preferredBundleID: String = ""
    @State private var isHoveringLeft = false
    @State private var isHoveringRight = false

    private var available: [(editor: ExternalEditor, appURL: URL)] {
        installedEditors()
    }

    private var primaryEntry: (editor: ExternalEditor, appURL: URL)? {
        if !preferredBundleID.isEmpty,
           let match = available.first(where: { $0.editor.bundleID == preferredBundleID }) {
            return match
        }
        return available.first
    }

    var body: some View {
        if let primary = primaryEntry {
            HStack(spacing: 0) {
                // Left segment — primary editor icon
                Button {
                    openInEditor(path: path, bundleID: primary.editor.bundleID)
                } label: {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: primary.appURL.path))
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    isHoveringLeft
                        ? Color.primary.opacity(0.08)
                        : Color.clear
                )
                .onHover { isHoveringLeft = $0 }
                .help("Open in \(primary.editor.name)")

                // Divider
                Rectangle()
                    .fill(Color.primary.opacity(0.15))
                    .frame(width: 1, height: 16)

                // Right segment — chevron dropdown
                Button {
                    showMenu(primary: primary)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 14, height: 16)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
                .background(
                    isHoveringRight
                        ? Color.primary.opacity(0.08)
                        : Color.clear
                )
                .onHover { isHoveringRight = $0 }
                .help("Choose editor")
            }
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.primary.opacity(0.15), lineWidth: 1)
            )
        }
    }

    private func showMenu(primary: (editor: ExternalEditor, appURL: URL)) {
        let menu = NSMenu()
        let coordinator = EditorMenuCoordinator()

        for entry in available {
            let item = NSMenuItem(title: entry.editor.name, action: nil, keyEquivalent: "")
            let icon = NSWorkspace.shared.icon(forFile: entry.appURL.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon

            let bundleID = entry.editor.bundleID
            let p = path
            coordinator.actions[item] = {
                openInEditor(path: p, bundleID: bundleID)
                preferredBundleID = bundleID
            }
            item.target = coordinator
            item.action = #selector(EditorMenuCoordinator.selectItem(_:))
            menu.addItem(item)
        }

        objc_setAssociatedObject(menu, "editorCoordinator", coordinator, .OBJC_ASSOCIATION_RETAIN)

        let location = NSEvent.mouseLocation
        menu.popUp(positioning: nil, at: location, in: nil)
    }
}

private class EditorMenuCoordinator: NSObject {
    var actions: [NSMenuItem: () -> Void] = [:]

    @objc func selectItem(_ sender: NSMenuItem) {
        actions[sender]?()
    }
}
