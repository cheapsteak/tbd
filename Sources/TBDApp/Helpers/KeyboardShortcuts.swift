import SwiftUI
import AppKit

enum TextFinderCommand {
    static let action = #selector(NSResponder.performTextFinderAction(_:))

    static func tag(for action: NSTextFinder.Action) -> Int {
        action.rawValue
    }

    @MainActor
    static func perform(_ finderAction: NSTextFinder.Action = .showFindInterface) {
        let sender = NSMenuItem()
        sender.tag = tag(for: finderAction)

        if let host = webviewHost(from: NSApp.keyWindow?.firstResponder) {
            host.performTextFinderAction(sender)
            return
        }

        NSApp.sendAction(action, to: nil, from: sender)
    }

    @MainActor
    static func webviewHost(from responder: NSResponder?) -> WebviewPaneHostView? {
        var current = responder
        var visited = Set<ObjectIdentifier>()

        while let responder = current {
            let id = ObjectIdentifier(responder)
            guard !visited.contains(id) else { return nil }
            visited.insert(id)

            if let host = responder as? WebviewPaneHostView {
                return host
            }

            if let view = responder as? NSView {
                var superview = view.superview
                while let candidate = superview {
                    if let host = candidate as? WebviewPaneHostView {
                        return host
                    }
                    superview = candidate.superview
                }
            }

            current = responder.nextResponder
        }

        return nil
    }
}

/// Menu commands providing keyboard shortcuts for the app.
struct TBDCommands: Commands {
    @ObservedObject var appState: AppState

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Install Command-Line Tool…") {
                Task { @MainActor in
                    await appState.installCLITool()
                }
            }
            Button("Migrate Claude Hooks…") {
                Task { @MainActor in
                    await appState.migrateClaudeHooks()
                }
            }
        }

        CommandGroup(after: .pasteboard) {
            Divider()

            Button("Find…") {
                TextFinderCommand.perform()
            }
            .keyboardShortcut("f", modifiers: .command)

            Button("Find Next") {
                TextFinderCommand.perform(.nextMatch)
            }
            .keyboardShortcut("g", modifiers: .command)

            Button("Find Previous") {
                TextFinderCommand.perform(.previousMatch)
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
        }

        // Worktree commands
        CommandMenu("Worktree") {
            Button("New Worktree") {
                Task { @MainActor in
                    appState.newWorktreeInFocusedRepo()
                }
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("Archive Worktree") {
                Task { @MainActor in
                    appState.archiveSelectedWorktree()
                }
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(appState.selectedWorktreeIDs.isEmpty)
        }

        // Terminal commands
        CommandMenu("Terminal") {
            Button("New Tab") {
                Task { @MainActor in
                    appState.newTerminalTab()
                }
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(appState.selectedWorktreeIDs.isEmpty)

            Button("Close Tab") {
                Task { @MainActor in
                    appState.closeTerminalTab()
                }
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(appState.selectedWorktreeIDs.isEmpty)

            Divider()

            Button("Split Horizontally") {
                Task { @MainActor in
                    appState.splitTerminalHorizontally()
                }
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(appState.selectedWorktreeIDs.isEmpty)

            Button("Split Vertically") {
                Task { @MainActor in
                    appState.splitTerminalVertically()
                }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(appState.selectedWorktreeIDs.isEmpty)
        }

        // Worktree selection by index (Cmd-1 through Cmd-9)
        CommandMenu("Go") {
            Button("Jump to Worktree…") {
                Task { @MainActor in
                    JumpMenuController.shared.toggle()
                }
            }
            .keyboardShortcut("k", modifiers: .command)

            Divider()

            ForEach(1...9, id: \.self) { index in
                Button("Worktree \(index)") {
                    Task { @MainActor in
                        appState.selectWorktreeByIndex(index - 1)
                    }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
            }
        }
    }
}
