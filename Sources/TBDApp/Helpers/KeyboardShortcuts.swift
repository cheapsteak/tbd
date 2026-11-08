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

/// The main window's navigation and panel commands. They live in the menu bar,
/// not on toolbar buttons, so the shortcuts work the same on the SwiftUI and
/// AppKit toolbars.
enum MainWindowCommand: CaseIterable {
    case back
    case forward
    case toggleChanges

    var title: String {
        switch self {
        case .back: "Back"
        case .forward: "Forward"
        case .toggleChanges: "Toggle Changes"
        }
    }

    var key: KeyEquivalent {
        switch self {
        case .back: "["
        case .forward: "]"
        case .toggleChanges: "e"
        }
    }

    var modifiers: EventModifiers {
        switch self {
        case .back, .forward: .command
        case .toggleChanges: [.command, .shift]
        }
    }

    /// The shortcut as the menu bar writes it: modifier glyphs in macOS
    /// order (control, option, shift, command), then the upper-cased key,
    /// e.g. "⌘[" or "⇧⌘E".
    var shortcutDisplay: String {
        let glyphs: [(EventModifiers, String)] = [
            (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"),
        ]
        let prefix = glyphs.filter { modifiers.contains($0.0) }.map(\.1).joined()
        return prefix + String(key.character).uppercased()
    }

    /// The title with its shortcut, e.g. "Back (⌘[)", for a tool tip. An
    /// accessibility label stays the bare `title`.
    var toolTip: String { "\(title) (\(shortcutDisplay))" }
}

/// Menu commands providing keyboard shortcuts for the app.
struct TBDCommands: Commands {
    var appState: AppState

    var body: some Commands {
        // The TBD menu opens with adding a repository, in a section of its
        // own; About TBD lives in the Help menu instead. The two items run
        // what the sidebar's Add Repository row runs: the folder picker, and
        // the clone request the native sidebar presents its sheet for.
        CommandGroup(replacing: .appInfo) {
            Button("Add Local Repository…") {
                AddRepositoryPanel.run(appState: appState)
            }
            Button("Clone Repository…") {
                appState.requestCloneRepository()
            }
            Divider()
        }

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
            Button("Check for Updates…") {
                Task { @MainActor in
                    await appState.checkForUpdatesNow()
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

        // The standard About panel, below the Help menu's own items.
        CommandGroup(after: .help) {
            Divider()
            Button("About TBD") {
                NSApplication.shared.orderFrontStandardAboutPanel(nil)
            }
        }

        // Ungated, like the prompt commands: it does nothing without a single
        // selected local worktree with an active tab, and beeps on a tab that
        // renders legacy (`AppState.toggleChangesPanel`).
        CommandGroup(after: .sidebar) {
            Button(MainWindowCommand.toggleChanges.title) {
                Task { @MainActor in appState.toggleChangesPanel() }
            }
            .keyboardShortcut(
                MainWindowCommand.toggleChanges.key,
                modifiers: MainWindowCommand.toggleChanges.modifiers
            )
        }

        // Worktree commands
        CommandMenu("Worktree") {
            WorktreeCommandsContent().environment(appState)
        }

        // Terminal commands
        CommandMenu("Terminal") {
            TerminalCommandsContent().environment(appState)
        }

        // Worktree selection by index (Cmd-1 through Cmd-9)
        CommandMenu("Go") {
            NavigationCommandsContent().environment(appState)

            Divider()

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

            // Menu commands cannot observe the first responder, so these stay
            // enabled and do nothing when no transcript pane is focused.
            Divider()

            Button("Previous Prompt") {
                Task { @MainActor in PromptRailCommand.perform(.previous, appState: appState) }
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])

            Button("Next Prompt") {
                Task { @MainActor in PromptRailCommand.perform(.next, appState: appState) }
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
        }
    }
}

/// The two menus whose items are *gated* on `AppState` live in nested `View`s,
/// not directly in the `Commands` body above — the same shape
/// `ModelProfileMenu` uses, and for the same reason: a `Commands` body does not
/// reliably re-evaluate when the state it reads changes, so a `.disabled(…)`
/// computed there can be captured once and never re-computed. Selection is
/// empty at launch, so a captured value would leave ⌘⇧A, ⌘T and ⌘W permanently
/// disabled.
///
/// The ungated items stay in the `Commands` body: their closures only *call*
/// `AppState`, and a closure that runs later needs no dependency.
private struct WorktreeCommandsContent: View {
    @Environment(AppState.self) var appState

    var body: some View {
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
}

private struct TerminalCommandsContent: View {
    @Environment(AppState.self) var appState
    /// `useGhosttyTerminalEngine` as stored, nil while nobody has chosen, so
    /// the menu follows the flag as soon as it changes. Read only.
    @AppStorage(AppState.useGhosttyTerminalEngineKey) private var ghosttyEngineChoice: Bool?

    private var ghosttyExperimentEnabled: Bool {
        AppState.ghosttyTerminalEngineEnabled(stored: ghosttyEngineChoice)
    }

    var body: some View {
        Button("New Tab") {
            Task { @MainActor in
                appState.newTerminalTab()
            }
        }
        .keyboardShortcut("t", modifiers: .command)
        .disabled(appState.selectedWorktreeIDs.isEmpty)

        Button("Close Tab") {
            Task { @MainActor in
                appState.closeFocusedTab()
            }
        }
        .keyboardShortcut("w", modifiers: .command)
        .disabled(!appState.canCloseFocusedTab)

        // In the menu only while the libghostty experiment is on, and enabled
        // only for a focused holder terminal (`TerminalEngineSwitchCommand`).
        if TerminalEngineSwitchCommand.isVisible(experimentEnabled: ghosttyExperimentEnabled) {
            Button(TerminalEngineSwitchCommand.title) {
                Task { @MainActor in
                    await appState.switchFocusedTerminalEngine()
                }
            }
            .keyboardShortcut(
                TerminalEngineSwitchCommand.key, modifiers: TerminalEngineSwitchCommand.modifiers)
            .disabled(!appState.canSwitchFocusedTerminalEngine)
        }

        Divider()

        // ⌘/ is unbound in this app, unclaimed by the terminal view, inert in
        // SwiftTerm, and not a system default. A terminal with no composer
        // mounted answers the call with a no-op, which is the honest result for
        // a pane that is closed or a session the composer's scope excludes.
        Button("Focus Message Composer") {
            Task { @MainActor in
                guard let terminalID = appState.composerCommandTerminalID else { return }
                appState.focusComposer(terminalID: terminalID)
            }
        }
        .keyboardShortcut("/", modifiers: .command)
        .disabled(appState.composerCommandTerminalID == nil)

        // The way back, for people who reach for a menu rather than Escape —
        // which the composer's own key handling already answers with this same
        // call. ⌥ rather than ⇧, because ⌘⇧/ is macOS's Help search field.
        Button("Focus Transcript") {
            Task { @MainActor in
                guard let terminalID = appState.composerCommandTerminalID else { return }
                appState.focusTranscript(terminalID: terminalID)
            }
        }
        .keyboardShortcut("/", modifiers: [.command, .option])
        .disabled(appState.composerCommandTerminalID == nil)
    }
}

/// Back and Forward are gated on `AppState`, so they live in a nested `View`
/// for the reason `WorktreeCommandsContent` gives.
private struct NavigationCommandsContent: View {
    @Environment(AppState.self) var appState

    var body: some View {
        Button(MainWindowCommand.back.title) {
            appState.navigateBack()
        }
        .keyboardShortcut(MainWindowCommand.back.key, modifiers: MainWindowCommand.back.modifiers)
        .disabled(!appState.canGoBack)

        Button(MainWindowCommand.forward.title) {
            appState.navigateForward()
        }
        .keyboardShortcut(MainWindowCommand.forward.key, modifiers: MainWindowCommand.forward.modifiers)
        .disabled(!appState.canGoForward)
    }
}
