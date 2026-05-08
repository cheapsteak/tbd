# Single Viewer + Live File Watching

## Problem

Clicking a relative file path in a terminal pane (cmd-click, OSC-8, etc.) currently calls `splitPane(...)` from `Sources/TBDApp/Panes/PanePlaceholder.swift:243-245`. Every click appends a new pane to the layout, so clicking N relative links produces N viewer panes, each squeezed smaller than the last.

A second, related gap: the code viewer reads file contents once via `.task(id: filePath)` and never updates when the file changes on disk. Editing the same file in another tool requires re-clicking the link to see the latest content.

## Goals

1. **At most one code-viewer pane per tab.** Subsequent terminal-link clicks in the same tab replace that pane's contents instead of splitting.
2. **Auto-refresh on disk changes.** Any code-viewer pane (terminal flow, sidebar flow, future markdown-link flow) reflects edits to the watched file within ~150 ms.
3. **No leaked file watchers, file descriptors, or async tasks** under any combination of pane open / close / path-change cycles.

## Non-goals

- Replacing or repurposing the existing markdown `OpenURLAction` in `RenderedContentView` (`NSWorkspace.shared.open`) — that is a separate flow for in-document links and is left untouched.
- Sharing a single watcher across multiple viewers of the same path (no central pool — see "Rejected alternatives").
- Showing a dedicated UI state when a watched file is deleted; the existing "Could not read file" error suffices.
- Multi-pane "tile of viewers" layouts. A future cmd-click escape hatch could add this; out of scope.

## Decisions captured during brainstorming

| # | Question | Decision |
|---|---|---|
| 1 | Behavior on link click when a viewer already exists in the tab | Replace the existing pane's path, keep its size and position |
| 2 | Behavior after the user closes the viewer | Next click re-creates by splitting from the clicked terminal (today's first-time behavior) |
| 3 | Reach of the file watcher | Applies to all code-viewer panes regardless of how they were opened |
| 4 | Atomic-save handling | Detect rename/delete, retry-open the same path after a short delay |
| 5 | Refresh debounce | ~150 ms trailing-edge |
| 6 | Cross-tab routing | Out of scope. One viewer per tab. Different tabs each get their own. |

## Architecture overview

Two narrow, independent changes:

1. **Single-viewer routing** — pure additions to `LayoutNode` (a value type) plus a small free function `routeFileClick`. `PanePlaceholder.swift`'s `onFilePathClicked` callback delegates to that function.
2. **`FileWatcher` class** — a new `final class FileWatcher: ObservableObject` owning a `DispatchSourceFileSystemObject`. `CodeViewerPaneView` holds one as `@StateObject`; its leaf content views (`RenderedContentView`, `HighlightedCodeView`, `ImagePreviewView`) take a `revision: Int` from `watcher.revision` and key their `.task` on `"\(filePath)#\(revision)"` so they reload when the watcher fires.

The two changes are wired together through one fact: when the routing change replaces a viewer's content, it **keeps the same `paneID`**, so SwiftUI's view identity is stable and the `@StateObject` watcher is reused (re-targeted via `observe(newPath)`). One pane lifetime → one `FileWatcher` instance, regardless of how many files are clicked.

## Component 1: Single-viewer routing

### New helpers on `LayoutNode`

```swift
extension LayoutNode {
    /// Returns the id of the first pane (in pre-order traversal) whose content
    /// matches the predicate, or nil if none match.
    func firstPaneID(where predicate: (PaneContent) -> Bool) -> UUID?

    /// Returns a copy of the tree with the pane identified by `paneID`
    /// replaced by `newContent`. Returns nil if no pane has that id.
    /// Other panes and split ratios are preserved exactly.
    func replacingContent(at paneID: UUID, with newContent: PaneContent) -> LayoutNode?
}
```

Both are pure recursive walks. No I/O, no side effects, fully unit-testable against constructed trees.

### Routing function

```swift
// Sources/TBDApp/Panes/ViewerRouting.swift
func routeFileClick(into layout: LayoutNode, terminalID: UUID, path: String) -> LayoutNode {
    let isViewer: (PaneContent) -> Bool = {
        if case .codeViewer = $0 { return true } else { return false }
    }
    if let viewerID = layout.firstPaneID(where: isViewer),
       let updated = layout.replacingContent(
           at: viewerID,
           with: .codeViewer(id: viewerID, path: path)
       ) {
        return updated
    }
    return layout.splitPane(
        id: terminalID,
        direction: .horizontal,
        newContent: .codeViewer(id: UUID(), path: path)
    )
}
```

Crucial detail: the replacement reuses `viewerID` as the new content's id. `PaneContent.codeViewer` carries an id field; `LayoutNode` keys panes by it; SwiftUI uses it as the view identity. Stable id → stable view → stable `@StateObject`.

### Callback site

`Sources/TBDApp/Panes/PanePlaceholder.swift:243-245` becomes:

```swift
onFilePathClicked: { path in
    layout = routeFileClick(into: layout, terminalID: terminalID, path: path)
}
```

No other call sites change. The sidebar's "open as code viewer" flow in `FileViewerPanel.swift` already uses tab/replace semantics on `appState.tabs` and is left as-is.

## Component 2: `FileWatcher`

### Type

```swift
@MainActor
final class FileWatcher: ObservableObject {
    @Published private(set) var revision: Int = 0

    private var source: DispatchSourceFileSystemObject?
    private var watchedPath: String?
    private var debounceTask: Task<Void, Never>?
    private var reopenTask: Task<Void, Never>?

    #if DEBUG
    static let liveCount = OSAllocatedUnfairLock(initialState: 0)
    #endif

    init() {
        #if DEBUG
        FileWatcher.liveCount.withLock { $0 += 1 }
        #endif
    }

    func observe(_ path: String) {
        guard path != watchedPath else { return }
        stop()
        startWatching(path)
    }

    func stop() {
        debounceTask?.cancel(); debounceTask = nil
        reopenTask?.cancel(); reopenTask = nil
        source?.cancel()           // triggers cancel handler → close(fd)
        source = nil
        watchedPath = nil
    }

    deinit {
        debounceTask?.cancel()
        reopenTask?.cancel()
        source?.cancel()
        #if DEBUG
        FileWatcher.liveCount.withLock { $0 -= 1 }
        #endif
    }

    private func startWatching(_ path: String) { /* see below */ }
    private func handleEvent(mask: DispatchSource.FileSystemEvent, path: String) { /* see below */ }
}
```

### `startWatching`

```swift
private func startWatching(_ path: String) {
    let fd = open(path, O_EVTONLY)
    guard fd >= 0 else {
        watchedPath = path     // remember intent; if file appears later, re-targeting still works
        return
    }
    let queue = DispatchQueue.global(qos: .utility)
    let src = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: fd,
        eventMask: [.write, .extend, .delete, .rename, .revoke],
        queue: queue
    )
    src.setEventHandler { [weak self] in
        let mask = src.data
        Task { @MainActor [weak self] in
            self?.handleEvent(mask: mask, path: path)
        }
    }
    src.setCancelHandler {
        close(fd)              // FD closed exactly once, here, only here
    }
    self.source = src
    self.watchedPath = path
    src.resume()
}
```

### `handleEvent`

```swift
private func handleEvent(mask: DispatchSource.FileSystemEvent, path: String) {
    if mask.contains(.delete) || mask.contains(.rename) || mask.contains(.revoke) {
        // Atomic save: editor wrote a temp file and renamed over us.
        // Tear down the now-stale source/FD, retry-open after a small delay.
        reopenTask?.cancel()
        reopenTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, let self, self.watchedPath == path else { return }
            self.stop()
            self.startWatching(path)
            self.revision &+= 1
        }
        return
    }

    // Write/extend: debounce a revision bump.
    debounceTask?.cancel()
    debounceTask = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled, let self else { return }
        self.revision &+= 1
    }
}
```

### Wiring into `CodeViewerPaneView`

```swift
struct CodeViewerPaneView: View {
    let filePath: String
    @StateObject private var watcher = FileWatcher()

    var body: some View {
        // ...existing chrome / sidebar / content branching...
        contentView
            .task(id: filePath) { watcher.observe(filePath) }
    }
}
```

The leaf content views — `RenderedContentView`, `HighlightedCodeView`, `ImagePreviewView` — gain a `revision: Int` parameter and key their existing `.task(id: ...)` on `"\(filePath)#\(revision)"` instead of `filePath`. That triggers their existing one-shot loaders to re-run on each watcher fire. No other change to their internals.

## Leak prevention

| Vector | Guard |
|---|---|
| Source's event handler retains `self` | `[weak self]` in event/cancel/debounce/reopen closures |
| `Task` retains `self` while sleeping | `[weak self]` plus `cancel()` in `stop()` and `deinit` |
| New `FileWatcher` per click | `@StateObject` (one-time init per view identity) **and** the routing change keeps `paneID` stable across path replacements, so SwiftUI doesn't tear the view down |
| Repeated `observe()` leaks old source | Idempotent on same path; calls `stop()` first on different path |
| Watcher outlives its pane | `LayoutNode.removePane` removes the node → SwiftUI tears down view → `@StateObject` released → `deinit` runs → source cancelled |
| FD leak | FD is closed *only* by the source's cancel handler. Cancel is invoked from `stop()` (path change, explicit stop) and `deinit` (view teardown) — no path leaks an FD; no path double-closes |

## Testing strategy

### Unit tests (must pass in CI)

- **`LayoutNodeTests`** — extend the existing test file:
  - `firstPaneID` returns nil on no match, root pane id on root match, walks left-then-right, finds nested matches.
  - `replacingContent` returns nil on missing id, replaces at root, replaces in either side of a split, preserves split direction and ratios, preserves sibling panes byte-for-byte.
- **`ViewerRoutingTests`**:
  - No existing viewer → returns `splitPane` result with a fresh viewer id.
  - One existing viewer → returns the tree with that viewer's `path` field replaced and id preserved.
  - Multiple viewers (a layout that somehow has more than one) → replaces the first found; others untouched.
- **`FileWatcherTests`** (in DEBUG):
  - Create 50 `FileWatcher`s in an `autoreleasepool`, call `observe("/some/path")`, let them deallocate. Assert `FileWatcher.liveCount == 0` afterward. Catches retain-cycle regressions.
  - Watcher with no events: `revision` stays 0.
  - `observe(path)` then `observe(samePath)` — no source recreation (verified via a debug hook or by counting `init` of an injected source factory; if too invasive, verify only that `revision` doesn't bump spuriously).
  - `observe(path)` then `observe(differentPath)` — old source cancelled before new one starts (assert via cancel callback observability).

### Manual verification (run before commit)

1. Open a worktree, open a terminal pane, `ls`, cmd-click a `.md` file. Viewer opens to the right.
2. cmd-click a second file. Viewer **content swaps**, pane keeps size.
3. Repeat for 5+ files. Pane never gets smaller; `log stream --predicate 'subsystem BEGINSWITH "com.tbd" AND category == "fileWatcher"'` shows 1 init, 0 deinit.
4. Edit the displayed file in another editor (vim, then VS Code). Pane refreshes within ~200ms each save.
5. Close the viewer pane via its close button. Logs show 1 deinit. Re-click a relative link — viewer is recreated by splitting from the terminal.
6. Open viewer + close pane in a tight loop 50 times. Final live-count is 0.
7. Run Instruments → Leaks → record the manual flow. No leaks reported.

## Files touched

- `Sources/TBDApp/Terminal/LayoutNode.swift` — add `firstPaneID(where:)` and `replacingContent(at:with:)` extensions.
- `Sources/TBDApp/Panes/ViewerRouting.swift` — **new file**, contains the free function `routeFileClick`.
- `Sources/TBDApp/Panes/PanePlaceholder.swift:243-245` — replace the body of the `onFilePathClicked` closure with a call to `routeFileClick`.
- `Sources/TBDApp/Panes/FileWatcher.swift` — **new file**, the `FileWatcher` class.
- `Sources/TBDApp/Panes/CodeViewerPaneView.swift` — add `@StateObject private var watcher = FileWatcher()`, plumb `watcher.revision` into the three leaf content views, change their `.task(id:)` keys.
- `Tests/TBDAppTests/LayoutNodeTests.swift` (or equivalent existing test file) — new cases for the two helpers.
- `Tests/TBDAppTests/ViewerRoutingTests.swift` — **new file**.
- `Tests/TBDAppTests/FileWatcherTests.swift` — **new file** (DEBUG only).

## Rejected alternatives

- **Promote the viewer to a fixed dock outside the layout tree.** Cleaner conceptually but a real refactor: existing close/move/split menus, layout serialization, and the FileViewerPanel sidebar's "open as code viewer" flow all route through the layout tree today. Replacing them is a lot of work for the same observable result.
- **`LayoutNode.viewerSlot` placeholder variant.** A hybrid that picks up the worst of both — extra state to sync but still inside the tree.
- **Central `FileWatcherPool` keyed by path.** Would let multiple viewers of the same file share a watcher. In practice we have at most one viewer per tab and rarely the same file in two tabs. The pool would add reference counting, deregistration callbacks, and a global to leak — *more* leak surface, not less. Skipped.
- **`FSEventStream` on the parent directory.** Survives atomic saves naturally, but emits more events to filter and is heavier per directory. The vnode-source + retry approach is lighter and equally correct for this use case.
- **`NSFilePresenter`.** Designed for coordinated I/O; far heavier than needed; unrelated semantics.
- **Reload immediately with no debounce.** Causes flicker during multi-event saves (Prettier, vim's :w). 150ms trailing edge is the standard fix.
