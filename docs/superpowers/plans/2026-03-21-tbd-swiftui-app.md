# TBD SwiftUI App Implementation Plan (Phase 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the macOS SwiftUI app that connects to the `tbdd` daemon, renders terminals via SwiftTerm + tmux control mode, and provides a sidebar for managing worktrees across multiple repos.

**Architecture:** The app is a pure SwiftUI client of the daemon. It connects via Unix socket, subscribes to state deltas, and renders terminals by attaching to tmux in control mode. All state mutations go through the daemon's RPC interface. The app owns only UI layout state (split positions, tab order).

**Tech Stack:** Swift 6.0, SwiftUI, SwiftTerm, macOS 14+

**Spec:** `docs/superpowers/specs/2026-03-21-tbd-design.md`
**Phase 1:** `docs/superpowers/plans/2026-03-21-tbd-daemon-cli.md` (daemon + CLI, complete)

---

## File Structure

```
Sources/TBDApp/
├── TBDApp.swift                    # @main entry, app lifecycle, daemon startup
├── AppState.swift                  # Observable state from daemon subscription
├── DaemonClient.swift              # Unix socket connection, RPC calls, state subscription
├── ContentView.swift               # Top-level NavigationSplitView
├── Sidebar/
│   ├── SidebarView.swift           # Repo/worktree tree with collapsible sections
│   ├── RepoSectionView.swift       # Single repo section with "+" button
│   ├── WorktreeRowView.swift       # Worktree item with badge, name, branch
│   └── SidebarContextMenu.swift    # Right-click menu (rename, archive, open in finder, etc.)
├── Terminal/
│   ├── TerminalContainerView.swift # Tab bar + split layout for a worktree
│   ├── TerminalPanelView.swift     # Single terminal panel wrapping SwiftTerm
│   ├── TerminalTabBar.swift        # Tab bar across top of terminal area
│   ├── SplitLayoutView.swift       # Recursive split layout renderer
│   ├── LayoutNode.swift            # Layout tree data model (Codable, persisted)
│   └── TmuxBridge.swift            # tmux control mode parser + SwiftTerm bridge
├── Settings/
│   └── SettingsView.swift          # App preferences (notifications, per-repo config)
└── Helpers/
    ├── KeyboardShortcuts.swift     # Cmd-1..9, Cmd-N, Cmd-D, etc.
    └── StatusBarView.swift         # Bottom status bar
```

---

### Task 1: Package.swift + App Shell

**Files:**
- Modify: `Package.swift`
- Create: `Sources/TBDApp/TBDApp.swift`
- Create: `Sources/TBDApp/ContentView.swift`
- Create: `Sources/TBDApp/AppState.swift`

- [ ] **Step 1: Update Package.swift**

Add SwiftTerm dependency and TBDApp target:
```swift
.package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.0.0"),
```

Add executable target:
```swift
.executableTarget(
    name: "TBDApp",
    dependencies: [
        "TBDShared",
        .product(name: "SwiftTerm", package: "SwiftTerm"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIO", package: "swift-nio"),
    ],
    path: "Sources/TBDApp"
),
```

- [ ] **Step 2: Create TBDApp.swift**

```swift
import SwiftUI
import TBDShared

@main
struct TBDAppMain: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        Window("TBD", id: "main") {
            ContentView()
                .environmentObject(appState)
        }
        .defaultSize(width: 1200, height: 800)

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}
```

- [ ] **Step 3: Create AppState.swift**

Observable object that holds all UI state:
- `repos: [Repo]` — from daemon
- `worktrees: [UUID: [Worktree]]` — grouped by repo ID
- `terminals: [UUID: [Terminal]]` — grouped by worktree ID
- `notifications: [UUID: NotificationType?]` — highest severity per worktree
- `selectedWorktreeIDs: Set<UUID>` — multi-select support
- `layouts: [UUID: LayoutNode]` — per-worktree split layout (persisted to UserDefaults)
- `isConnected: Bool` — daemon connection status
- `repoFilter: UUID?` — sidebar filter (nil = show all)

Methods for sending RPCs to daemon (delegate to DaemonClient).

- [ ] **Step 4: Create ContentView.swift**

Basic NavigationSplitView with placeholder sidebar and detail:
```swift
struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            if appState.selectedWorktreeIDs.isEmpty {
                Text("Select a worktree or click + to create one")
                    .foregroundStyle(.secondary)
            } else {
                TerminalContainerView()
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                // Add Repo button, Filter, Settings
            }
        }
    }
}
```

Create placeholder files for SidebarView and TerminalContainerView (empty views) so it compiles.

- [ ] **Step 5: Create placeholder SettingsView.swift**

Empty settings view so the app compiles.

- [ ] **Step 6: Build and run**

Run: `swift build --product TBDApp`
Expected: Builds successfully. Running it shows an empty window with a split view.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/TBDApp/
git commit -m "feat: add SwiftUI app shell with NavigationSplitView"
```

---

### Task 2: Daemon Client + State Subscription

**Files:**
- Create: `Sources/TBDApp/DaemonClient.swift`
- Modify: `Sources/TBDApp/AppState.swift`

- [ ] **Step 1: Implement DaemonClient.swift**

An actor that:
- Connects to the daemon Unix socket at `~/.tbd/sock`
- Sends RPC requests and receives responses (same protocol as CLI)
- Subscribes to state changes by calling `state.subscribe` — keeps connection open, reads streaming JSON deltas
- On connection loss, attempts reconnect every 2 seconds
- If daemon isn't running, attempts to start it by launching `tbdd` binary
- Provides typed async methods: `addRepo(path:)`, `createWorktree(repoID:)`, `archiveWorktree(id:force:)`, `listRepos()`, `listWorktrees(repoID:)`, etc.

- [ ] **Step 2: Update AppState to use DaemonClient**

AppState initializes a DaemonClient on init, connects, fetches initial state (repo list, worktree list, notifications), then subscribes to deltas. Delta handler updates the published properties.

- [ ] **Step 3: Verify connection**

Start daemon manually (`tbdd`), then run the app. AppState should populate repos/worktrees. Add a temporary Text() showing repo count to verify.

- [ ] **Step 4: Commit**

```bash
git add Sources/TBDApp/
git commit -m "feat: add daemon client with state subscription"
```

---

### Task 3: Sidebar

**Files:**
- Create: `Sources/TBDApp/Sidebar/SidebarView.swift`
- Create: `Sources/TBDApp/Sidebar/RepoSectionView.swift`
- Create: `Sources/TBDApp/Sidebar/WorktreeRowView.swift`
- Create: `Sources/TBDApp/Sidebar/SidebarContextMenu.swift`

- [ ] **Step 1: Implement SidebarView.swift**

```swift
struct SidebarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        List(selection: $appState.selectedWorktreeIDs) {
            ForEach(filteredRepos) { repo in
                RepoSectionView(repo: repo)
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: addRepo) {
                    Label("Add Repository", systemImage: "plus.rectangle")
                }
            }
        }
    }
}
```

With file picker for adding repos, filter dropdown in toolbar.

- [ ] **Step 2: Implement RepoSectionView.swift**

Collapsible `DisclosureGroup` with repo name and "+" button:
```swift
struct RepoSectionView: View {
    let repo: Repo
    @EnvironmentObject var appState: AppState
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(worktrees) { worktree in
                WorktreeRowView(worktree: worktree)
                    .tag(worktree.id)
            }
        } label: {
            HStack {
                Label(repo.displayName, systemImage: "folder")
                Spacer()
                Button(action: { createWorktree() }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
            }
        }
    }
}
```

- [ ] **Step 3: Implement WorktreeRowView.swift**

Shows display name, notification badge (colored dot or bold text), subtle branch name:
```swift
struct WorktreeRowView: View {
    let worktree: Worktree
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack {
            notificationBadge
            VStack(alignment: .leading, spacing: 2) {
                Text(worktree.displayName)
                    .fontWeight(hasBoldNotification ? .bold : .regular)
                Text(worktree.branch)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contextMenu { SidebarContextMenu(worktree: worktree) }
    }
}
```

- [ ] **Step 4: Implement SidebarContextMenu.swift**

Context menu with: Rename, Archive, Open in Finder, Open in IDE (configurable), Copy Path.

Rename uses a sheet with a text field. Archive calls daemon RPC. Open in Finder uses `NSWorkspace.shared.open()`. Copy Path uses `NSPasteboard`.

- [ ] **Step 5: Build, run, verify sidebar renders**

- [ ] **Step 6: Commit**

```bash
git add Sources/TBDApp/Sidebar/
git commit -m "feat: add sidebar with repo sections, worktree rows, and context menus"
```

---

### Task 4: Tmux Control Mode Bridge

**Files:**
- Create: `Sources/TBDApp/Terminal/TmuxBridge.swift`

This is the highest-risk component. It bridges tmux control mode output to SwiftTerm views.

- [ ] **Step 1: Implement TmuxBridge.swift**

An actor that manages one tmux control mode connection per repo:

```swift
actor TmuxBridge {
    private var connections: [String: TmuxConnection] = [:] // keyed by server name

    func connect(server: String) async throws {
        // Launch: tmux -L <server> -CC attach -t main
        // Parse stdout for control mode notifications
    }

    func disconnect(server: String) { ... }

    // Register a pane to receive output
    func registerPane(_ paneID: String, handler: @Sendable @escaping (Data) -> Void) { ... }
    func unregisterPane(_ paneID: String) { ... }

    // Send input to a pane
    func sendKeys(server: String, paneID: String, text: String) async { ... }

    // Resize a window
    func resizeWindow(server: String, windowID: String, width: Int, height: Int) async { ... }
}
```

**TmuxConnection** (internal class):
- Launches `tmux -L <server> -CC attach -t main` as a `Process`
- Reads stdout line by line in a background Task
- Parses control mode protocol:
  - `%output <pane-id> <octal-escaped-data>` → decode octal escapes, route to registered handler
  - `%begin <time> <num> <flags>` → start of command response block
  - `%end <time> <num> <flags>` → end of command response block
  - `%pause <pane-id>` → flow control, pause sending data for that pane
  - `%continue <pane-id>` → resume
  - `%window-add @<id>` / `%window-close @<id>` → window lifecycle
  - `%exit` → session detached
- Writes commands to stdin: `send-keys -t <pane> -l <text>`, `resize-window`, etc.

**Octal decoding**: `%output` data uses octal escapes for non-printable bytes (e.g. `\033` for ESC). Decode these into raw `Data` before feeding to SwiftTerm.

- [ ] **Step 2: Add unit tests for octal decoder**

```swift
// Test that "\033[31m" decodes to ESC [ 3 1 m
// Test that "hello\\012world" decodes to "hello\nworld"
// Test that regular text passes through unchanged
```

- [ ] **Step 3: Commit**

```bash
git add Sources/TBDApp/Terminal/TmuxBridge.swift Tests/
git commit -m "feat: add tmux control mode bridge with octal decoder"
```

---

### Task 5: Terminal Panel View (SwiftTerm Integration)

**Files:**
- Create: `Sources/TBDApp/Terminal/TerminalPanelView.swift`

- [ ] **Step 1: Implement TerminalPanelView.swift**

Wraps SwiftTerm's `TerminalView` (AppKit) in a SwiftUI `NSViewRepresentable`:

```swift
struct TerminalPanelView: NSViewRepresentable {
    let terminalID: UUID
    let tmuxServer: String
    let tmuxPaneID: String
    @EnvironmentObject var appState: AppState

    func makeNSView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: .zero)
        tv.configureNativeColors()
        // Set font, colors, etc.
        tv.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        // Register with TmuxBridge to receive output
        context.coordinator.setupBridge(tv: tv, server: tmuxServer, paneID: tmuxPaneID)

        return tv
    }

    func updateNSView(_ tv: TerminalView, context: Context) {
        // Handle resize — tell tmux about new dimensions
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator {
        // Receives %output data from TmuxBridge, feeds to TerminalView.feed()
        // Captures keystrokes from TerminalView, sends via TmuxBridge.sendKeys()
    }
}
```

The coordinator:
- Subscribes to TmuxBridge for the specific pane ID
- On `%output` data: calls `terminalView.feed(byteArray: bytes)`
- Implements `TerminalViewDelegate` to capture keystrokes: forwards to `tmuxBridge.sendKeys()`
- On view resize: calculates character dimensions, calls `tmuxBridge.resizeWindow()`

- [ ] **Step 2: Test basic terminal rendering**

Start daemon, create a worktree, then embed a TerminalPanelView pointing at one of its tmux panes. Verify text appears and keystrokes work.

- [ ] **Step 3: Commit**

```bash
git add Sources/TBDApp/Terminal/TerminalPanelView.swift
git commit -m "feat: add SwiftTerm panel view with tmux bridge integration"
```

---

### Task 6: Layout Node + Split Layout View

**Files:**
- Create: `Sources/TBDApp/Terminal/LayoutNode.swift`
- Create: `Sources/TBDApp/Terminal/SplitLayoutView.swift`

- [ ] **Step 1: Implement LayoutNode.swift**

```swift
import Foundation

enum SplitDirection: String, Codable {
    case horizontal, vertical
}

indirect enum LayoutNode: Codable, Equatable {
    case terminal(terminalID: UUID)
    case split(direction: SplitDirection, children: [LayoutNode], ratios: [CGFloat])

    // Mutating helpers:
    func splitTerminal(id: UUID, direction: SplitDirection, newTerminalID: UUID) -> LayoutNode
    func removeTerminal(id: UUID) -> LayoutNode?
    func allTerminalIDs() -> [UUID]
}
```

Persist to UserDefaults as JSON, keyed by worktree ID.

- [ ] **Step 2: Implement SplitLayoutView.swift**

Recursive SwiftUI view that renders LayoutNode:
```swift
struct SplitLayoutView: View {
    let node: LayoutNode
    let worktree: Worktree

    var body: some View {
        switch node {
        case .terminal(let id):
            TerminalPanelWithChrome(terminalID: id, worktree: worktree)
        case .split(let direction, let children, let ratios):
            // Use HSplitView/VSplitView or GeometryReader + custom dividers
            SplitContainer(direction: direction, children: children, ratios: ratios, worktree: worktree)
        }
    }
}
```

`TerminalPanelWithChrome` wraps `TerminalPanelView` with a small title bar containing split buttons [⬓] [⬒].

`SplitContainer` uses a custom implementation with draggable dividers (not HSplitView which has limited customization). Each child is rendered recursively. Dividers are 4px wide/tall with a drag gesture that updates ratios.

- [ ] **Step 3: Commit**

```bash
git add Sources/TBDApp/Terminal/LayoutNode.swift Sources/TBDApp/Terminal/SplitLayoutView.swift
git commit -m "feat: add recursive split layout with draggable dividers"
```

---

### Task 7: Terminal Container + Tab Bar

**Files:**
- Create: `Sources/TBDApp/Terminal/TerminalContainerView.swift`
- Create: `Sources/TBDApp/Terminal/TerminalTabBar.swift`

- [ ] **Step 1: Implement TerminalTabBar.swift**

A horizontal tab bar showing terminal labels for the selected worktree. Supports Cmd-T to add tabs, Cmd-W to close.

```swift
struct TerminalTabBar: View {
    let terminals: [Terminal]
    @Binding var selectedTabID: UUID?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(terminals) { terminal in
                TabItem(terminal: terminal, isSelected: selectedTabID == terminal.id)
                    .onTapGesture { selectedTabID = terminal.id }
            }
            // "+" button for new tab
            Button(action: addTab) {
                Image(systemName: "plus")
            }
        }
    }
}
```

- [ ] **Step 2: Implement TerminalContainerView.swift**

Manages the terminal area for the selected worktree(s):

For **single selection**: Shows tab bar + split layout for the selected worktree.

For **multi-selection**: Auto-splits the view, one primary terminal per selected worktree (no tab bar — each panel shows the worktree name).

```swift
struct TerminalContainerView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if appState.selectedWorktreeIDs.count == 1,
           let id = appState.selectedWorktreeIDs.first {
            SingleWorktreeView(worktreeID: id)
        } else {
            MultiWorktreeView(worktreeIDs: Array(appState.selectedWorktreeIDs))
        }
    }
}
```

`SingleWorktreeView`: Tab bar at top, SplitLayoutView below.
`MultiWorktreeView`: Auto-grid of terminals, one per worktree.

- [ ] **Step 3: Commit**

```bash
git add Sources/TBDApp/Terminal/TerminalContainerView.swift Sources/TBDApp/Terminal/TerminalTabBar.swift
git commit -m "feat: add terminal container with tab bar and multi-select support"
```

---

### Task 8: Status Bar + Keyboard Shortcuts

**Files:**
- Create: `Sources/TBDApp/Helpers/StatusBarView.swift`
- Create: `Sources/TBDApp/Helpers/KeyboardShortcuts.swift`

- [ ] **Step 1: Implement StatusBarView.swift**

Bottom bar showing daemon connection status, active worktree count:
```swift
struct StatusBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack {
            Circle()
                .fill(appState.isConnected ? .green : .red)
                .frame(width: 8, height: 8)
            Text(appState.isConnected ? "tbdd connected" : "tbdd disconnected")
            Spacer()
            Text("\(activeWorktreeCount) active worktrees")
        }
        .font(.caption)
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(.bar)
    }
}
```

- [ ] **Step 2: Implement KeyboardShortcuts.swift**

Add `.keyboardShortcut` modifiers and menu commands:
- Cmd-1..9: Switch worktrees by sidebar order
- Cmd-N: New worktree in focused repo
- Cmd-Shift-A: Archive focused worktree
- Cmd-D: Split horizontal
- Cmd-Shift-D: Split vertical
- Cmd-T: New terminal tab
- Cmd-W: Close terminal tab

These are added as `.commands` in the App struct.

- [ ] **Step 3: Commit**

```bash
git add Sources/TBDApp/Helpers/
git commit -m "feat: add status bar and keyboard shortcuts"
```

---

### Task 9: Settings View

**Files:**
- Modify: `Sources/TBDApp/Settings/SettingsView.swift`

- [ ] **Step 1: Implement SettingsView.swift**

Tabbed settings window:

**General tab:**
- macOS notifications toggle (on/off)
- Default behavior for new worktrees (launch claude with --dangerously-skip-permissions toggle)

**Repositories tab:**
- List of added repos with per-repo settings:
  - Display name (editable)
  - Default branch override
  - Hook override path (file picker)
  - Claude flags override

Settings stored in UserDefaults (not in daemon — these are UI preferences). Per-repo daemon settings go through the RPC interface.

- [ ] **Step 2: Commit**

```bash
git add Sources/TBDApp/Settings/
git commit -m "feat: add settings view with general and per-repo tabs"
```

---

### Task 10: Daemon Auto-Start + App Polish

**Files:**
- Modify: `Sources/TBDApp/TBDApp.swift`
- Modify: `Sources/TBDApp/DaemonClient.swift`
- Modify: `Sources/TBDApp/ContentView.swift`

- [ ] **Step 1: Auto-start daemon on app launch**

In `DaemonClient`, if the socket doesn't exist, look for `tbdd` in the app's `Resources` or adjacent to the app binary, and launch it. Fall back to checking `$PATH`.

- [ ] **Step 2: Add "Add Repository" empty state**

When no repos exist, show a prominent "Add Repository" button with instructions in the detail area.

- [ ] **Step 3: Add toolbar items**

- Add Repo button (file picker)
- Filter dropdown (All repos / specific repo)
- Gear icon opens Settings

- [ ] **Step 4: Wire up notification badge clearing**

When user selects a worktree, send `markRead` for its notifications via the daemon.

- [ ] **Step 5: Build and run full app**

Verify the complete flow:
1. App launches, starts daemon
2. Add a repo
3. Create a worktree (terminal appears with claude running)
4. Split terminals
5. Switch between worktrees
6. Archive a worktree
7. Keyboard shortcuts work

- [ ] **Step 6: Commit**

```bash
git add Sources/TBDApp/
git commit -m "feat: add daemon auto-start, empty state, toolbar, notification clearing"
```

---

## Post-Phase 2 Verification

1. **Build**: `swift build --product TBDApp`
2. **Run**: `.build/debug/TBDApp`
3. **Smoke test**:
   - App opens, daemon starts automatically
   - Add a repo via toolbar button
   - Click "+" to create a worktree
   - Terminal renders with claude code running
   - Split terminals with buttons and Cmd-D
   - Switch worktrees via sidebar
   - Cmd-click multiple worktrees for multi-select view
   - Right-click for context menu (rename, archive, copy path)
   - Archive a worktree, verify it disappears
   - Close and reopen app, verify terminals reconnect with content intact
   - Send a notification via CLI (`tbd notify --type response_complete`), verify sidebar badge
