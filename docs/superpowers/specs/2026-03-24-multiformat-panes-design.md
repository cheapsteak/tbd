# Multi-Format Panes

Add support for webview and code viewer panes alongside existing terminal panes, splittable within the same layout tree.

## Background

TBD currently supports only terminal panes. The layout system (`LayoutNode`) is a recursive split tree where every leaf is a terminal. This design generalizes the leaf type so panes can render terminals, web content (particularly GitHub PRs), or syntax-highlighted source code.

## Data Model

### PaneContent enum

Single type used in both the layout tree and the tab system (no separate `TabContent` — one type serves both purposes):

```swift
enum PaneContent: Codable, Equatable, Sendable {
    case terminal(terminalID: UUID)
    case webview(id: UUID, url: URL)
    case codeViewer(id: UUID, path: String) // absolute file path
}
```

Each variant carries its own `id: UUID` so the layout tree can address any pane uniformly. A `PaneContent` has a computed `paneID: UUID` that returns the relevant ID regardless of variant.

### LayoutNode changes

```swift
indirect enum LayoutNode: Equatable, Sendable {
    case pane(PaneContent)  // was: .terminal(terminalID: UUID)
    case split(direction: SplitDirection, children: [LayoutNode], ratios: [CGFloat])
}
```

Tree helpers renamed: `splitTerminal` → `splitPane`, `removeTerminal` → `removePane`, `allTerminalIDs` → `allPaneIDs`. `splitPane` takes a `PaneContent` (not just a UUID) so it can insert any pane type. Logic is otherwise identical — only the leaf type changes.

### Codable migration

The manual `Codable` conformance on `LayoutNode` currently encodes a `NodeType` discriminator (`terminal`, `split`) and type-specific keys (`terminalID`). After the change:

- `NodeType` gains new cases: `webview`, `codeViewer`
- The `terminal` decoder is rewritten to produce `.pane(.terminal(terminalID:))` instead of `.terminal(terminalID:)` — same on-disk format, different in-memory representation
- New pane types add their own coding keys (`url` for webview, `path` for code viewer)
- **No data file migration needed** — persisted layouts with `NodeType.terminal` decode correctly through the updated decoder. New pane types simply use new `NodeType` values that old versions won't encounter.

## Tab System

### Single source of truth

Introduce a `Tab` model that reuses `PaneContent` (no separate `TabContent` type):

```swift
struct Tab: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var content: PaneContent  // same type used in LayoutNode leaves
    var label: String?
}
```

`appState.tabs: [UUID: [Tab]]` (keyed by worktree ID) is the single source of truth for tab ordering and existence. `appState.terminals: [UUID: [Terminal]]` becomes a passive lookup table for tmux connection info only.

The "+" button creates a new terminal tab only. There is no generic UI for creating webview or code viewer tabs — those are created exclusively through the contextual flows described in "Creation Flows" below (PR link, Cmd+Click, FileViewerPanel click).

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

`appState.layouts: [UUID: LayoutNode]` is keyed by `Tab.id`. Each tab has exactly one layout tree. The default layout for a new tab is `.pane(tab.content)` — a single leaf matching the tab's content type. When the user splits a pane, the layout grows into a `.split(...)` tree. A tab's layout can contain mixed pane types (e.g., a terminal tab with a code viewer split alongside it).

This is a change from the current scheme where layouts are keyed by `terminal.id`. Migration: on first launch, for each terminal, create a `Tab` with `id == terminal.id` so existing layout keys remain valid.

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

### CLI (future scope)

`tbd open path/to/file.swift` — programmatic access for opening files in the code viewer. This requires a new RPC method and daemon-to-app communication channel. Deferred to a follow-up; not part of this implementation.

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
- `Sources/TBDShared/Models.swift` — `Tab`, `PaneContent` models (if shared with daemon, otherwise app-only)
- `Package.swift` — add Highlightr dependency
