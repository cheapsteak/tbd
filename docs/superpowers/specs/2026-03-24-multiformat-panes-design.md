# Multi-Format Panes

Add support for webview and code viewer panes alongside existing terminal panes, splittable within the same layout tree.

## Background

TBD currently supports only terminal panes. The layout system (`LayoutNode`) is a recursive split tree where every leaf is a terminal. This design generalizes the leaf type so panes can render terminals, web content (particularly GitHub PRs), or syntax-highlighted source code.

## Data Model

### PaneContent enum

Replaces the terminal-only leaf with a discriminated union of pane types:

```swift
enum PaneContent: Codable, Equatable, Sendable {
    case terminal(terminalID: UUID)
    case webview(id: UUID, url: URL)
    case codeViewer(id: UUID, path: String) // absolute file path
}
```

Each variant carries its own `id: UUID` so the layout tree can address any pane uniformly.

### LayoutNode changes

```swift
indirect enum LayoutNode: Equatable, Sendable {
    case pane(PaneContent)  // was: .terminal(terminalID: UUID)
    case split(direction: SplitDirection, children: [LayoutNode], ratios: [CGFloat])
}
```

Tree helpers renamed: `splitTerminal` → `splitPane`, `removeTerminal` → `removePane`, `allTerminalIDs` → `allPaneIDs`. Logic is identical — only the leaf type changes.

### Codable migration

The manual `Codable` conformance on `LayoutNode` currently encodes a `NodeType` discriminator (`terminal`, `split`). Add new `NodeType` cases (`webview`, `codeViewer`). The existing `terminal` case decodes to `.pane(.terminal(...))`, so persisted layouts migrate without data changes.

## Tab System

### Single source of truth

Introduce a `Tab` model:

```swift
struct Tab: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var content: TabContent
    var label: String?
}

enum TabContent: Codable, Equatable, Sendable {
    case terminal(terminalID: UUID)
    case webview(id: UUID, url: URL)
    case codeViewer(id: UUID, path: String)
}
```

`appState.tabs: [UUID: [Tab]]` (keyed by worktree ID) is the single source of truth for tab ordering and existence. `appState.terminals: [UUID: [Terminal]]` becomes a passive lookup table for tmux connection info only.

### Tab bar

`TerminalTabBar` becomes a generic `TabBar` displaying icons per type:
- Terminal: terminal icon + truncated ID
- Webview: globe icon + domain or page title
- Code viewer: document icon + filename

The "+" button creates a new terminal tab (calls `createTerminal()` on the daemon, then appends a tab entry).

### Daemon reconciliation

When the daemon creates/deletes terminals (including on reconnect), `appState.tabs` is updated accordingly:
- New terminal from daemon → append `.terminal(terminalID:)` tab
- Terminal removed → remove its tab entry
- On reconnect, reconcile: remove tabs for terminals that no longer exist, add tabs for new ones

### Migration

On first launch after update, if `tabs[worktreeID]` is nil, generate it from `terminals[worktreeID]`.

### Layouts

`appState.layouts: [UUID: LayoutNode]` continues to be keyed by the tab's root pane ID. For terminal tabs that's `terminal.id`, for webview/code viewer tabs it's their respective UUID.

## WebviewPaneView

`NSViewRepresentable` wrapping `WKWebView`.

- **Shared session:** All webview panes share `WKWebsiteDataStore.default()`. Log in to GitHub once, authenticated everywhere. Cookies persist across app restarts.
- **Chrome:** Minimal — URL display (read-only, shows current page URL), back/forward buttons in the `PanePlaceholder` header. No URL input bar.
- **Navigation:** `WKNavigationDelegate` updates the displayed URL as the user navigates.
- **Creation flow:** Programmatic only — no generic "create webview" UI.

## CodeViewerPaneView

Native syntax-highlighted code viewer using [Highlightr](https://github.com/raspu/Highlightr) (Swift wrapper around highlight.js).

### Components

- **File sidebar** (~200px, left): Tree view of the worktree directory. Single-click selects a file and shows it in the preview. Cmd+Click selects multiple files, shown stacked vertically in a scrollable view.
- **Code preview** (main area, right): Read-only `NSTextView` displaying `NSAttributedString` from Highlightr. Monospace font, text-selectable.

### Syntax highlighting

- Highlightr tokenizes code via highlight.js, produces `NSAttributedString`
- Override font to consistent monospace (`NSFont.monospacedSystemFont`)
- **Legibility fix:** Enumerate foreground color attributes; replace any with WCAG relative luminance > 0.6 with `NSColor.labelColor` (same approach as gh-review's `colorIsTooPale()`)

### Language detection

Map file extensions to highlight.js language names (swift, typescript, python, etc.). Fall back to plain text for unknown extensions.

### Dependency

Add `Highlightr` SPM package to `Package.swift`, imported in `TBDApp` target only.

## SplitLayoutView Changes

`SplitLayoutView` switches on the new `LayoutNode`:

```swift
switch node {
case .pane(let content):
    PanePlaceholder(content: content, worktree: worktree, layout: $layout)
case .split(let direction, let children, let ratios):
    SplitContainer(/* unchanged */)
}
```

### PanePlaceholder

Universal leaf wrapper replacing `TerminalPanelPlaceholder`:

- **Shared header toolbar:** Pane type indicator, close button. Split buttons shown for terminal panes only.
- **Content switch:** Renders `TerminalPanelView`, `WebviewPaneView`, or `CodeViewerPaneView` based on `PaneContent`.

`SplitContainer` and `SplitDivider` are untouched — they only know about `LayoutNode`, not leaf contents.

## Creation Flows

### PR link → webview tab

- When a single worktree is selected and has a `PRStatus` in `appState.prStatuses[worktreeID]`, show a clickable PR number (e.g., "#42") in the toolbar title area.
- Clicking it creates a new tab: `.webview(id: UUID(), url: URL(string: prStatus.url)!)`.

### Cmd+Click file path in terminal → code viewer split

- Override `mouseDown(with:)` in `TBDTerminalView` when Cmd is held.
- Extract the terminal line text via SwiftTerm's buffer API.
- Parse text around click position for a plausible file path (contiguous non-whitespace, optional `:line` suffix).
- Resolve relative paths against `worktree.path`.
- Validate path exists via `FileManager`.
- If valid: mutate layout to add `.pane(.codeViewer(...))` split to the right of the current terminal.
- If invalid: silent no-op (replaces current broken Finder open that shows error -50).

> **TODO: Harden file path detection.** The current approach is best-effort heuristic parsing of terminal buffer text. If this proves unreliable in practice, consider: regex-based pattern matching on full line text, OSC 8 hyperlink support, or shell integration escape sequences.

### FileViewerPanel click → code viewer tab

- Clicking a file in the git status FileViewerPanel opens a code viewer tab (or reuses an existing one).
- Subsequent file clicks replace the displayed file in the same code viewer tab.
- Cmd+Click adds files to a multi-file selection, shown stacked in the code viewer.

### CLI

`tbd open path/to/file.swift` — programmatic access for opening files in the code viewer.

## Files Changed

### New files
- `Sources/TBDApp/Panes/PanePlaceholder.swift` — universal pane leaf wrapper
- `Sources/TBDApp/Panes/WebviewPaneView.swift` — WKWebView wrapper
- `Sources/TBDApp/Panes/CodeViewerPaneView.swift` — Highlightr-based code viewer
- `Sources/TBDApp/Panes/CodeViewerSidebar.swift` — file tree sidebar for code viewer
- `Sources/TBDApp/TabBar.swift` — generalized tab bar (replaces TerminalTabBar)

### Modified files
- `Sources/TBDApp/Terminal/LayoutNode.swift` — `PaneContent` enum, `.pane()` case, renamed helpers
- `Sources/TBDApp/Terminal/SplitLayoutView.swift` — switch on `.pane()`, remove `TerminalPanelPlaceholder`
- `Sources/TBDApp/Terminal/TerminalContainerView.swift` — read tabs from `appState.tabs`, use generic `TabBar`
- `Sources/TBDApp/Terminal/TBDTerminalView.swift` — Cmd+Click file path interception
- `Sources/TBDApp/AppState.swift` — add `tabs: [UUID: [Tab]]`, daemon reconciliation updates
- `Sources/TBDApp/ContentView.swift` — PR link in toolbar
- `Sources/TBDApp/FileViewer/FileViewerPanel.swift` — click handler to open code viewer tab
- `Sources/TBDShared/Models.swift` — `Tab`, `TabContent` models (if shared with daemon, otherwise app-only)
- `Package.swift` — add Highlightr dependency
