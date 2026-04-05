# Conductor UI Design

A Guake-style toggleable overlay that renders the conductor's terminal session within the TBD app, with navigation suggestions and hotkey support.

## Problem

The conductor (Phase 1a) is a CLI-only experience. Users must manually switch to a conductor terminal, check on it, and switch back. There's no way to keep the conductor visible while working in worktrees, and no UI affordance to start one.

## Solution

A resizable, toggleable terminal overlay that drops from the top of the main content area. One-click setup from the toolbar. Local hotkey (Opt+.) for instant toggle. Navigation suggestions let the conductor surface clickable "go to worktree" pills without blocking interaction.

## Design Principles

- **Zero reflow.** The overlay covers content — it doesn't push it down. Content underneath retains its layout.
- **Non-destructive hide.** Hiding the overlay keeps the terminal and tmux session alive. Show/hide is instant.
- **Non-blocking suggestions.** Navigation pills are informational. The user can ignore them and keep chatting with the conductor.
- **One-click start.** No configuration dialogs. Click the toolbar button, conductor is running.

## Architecture

### Overlay Layout

The conductor overlay is a SwiftUI `.overlay(alignment: .top)` applied inside the `detail:` closure of `NavigationSplitView` in `ContentView`, wrapping the terminal/worktree content branch. It spans the full main content area — everything right of the sidebar, covering tab content, multi-worktree grid, and pinned dock.

The overlay only renders when terminal content is showing — not over the disconnected view, empty state, or archived worktrees view. The `.overlay()` wraps the `HStack` containing `TerminalContainerView` (+ optional `FileViewerPanel`).

```
┌─────────┬──────────────────────────────────────────┐
│         │ Toolbar: [auto-suspend] [conductor ⚡]    │
│         ├──────────────────────────────────────────┤
│         │ ┌──────────────────────────────────────┐ │
│ Sidebar │ │  Conductor terminal (SwiftTerm)      │ │
│         │ │                                      │ │
│         │ ├──────── drag handle ─────────────────┤ │
│         │ │ 🔗 fix-auth — waiting for input [Go] │ │
│         │ ├──────────────────────────────────────┤ │
│         │ │                                      │ │
│         │ │  Tab content / worktree grid          │ │
│         │ │  (partially covered by overlay)       │ │
│         │ │                                      │ │
│         │ └──────────────────────────────────────┘ │
└─────────┴──────────────────────────────────────────┘
```

### ConductorOverlayView Structure

```
ConductorOverlayView
├── VStack(spacing: 0) {
│   ├── TerminalPanelView (conductor's terminal — fills available height)
│   ├── ConductorDragHandle (4pt, full width, resizeUpDown cursor)
│   └── ConductorSuggestionBar (conditional — only when suggestion is active, ~28px)
│   }
```

### Visibility & Terminal Lifecycle

- `appState.showConductor: Bool` controls visibility (defaults to `false` on app launch, even if a conductor is running — the user toggles it when they want it)
- When hidden: `TerminalPanelView` stays mounted at its configured height via `.opacity(0).allowsHitTesting(false)` — SwiftTerm + tmux grouped session stays alive. **Do not use `frame(height: 0)`** — a zero-height frame would send 0 rows to the PTY via `TIOCSWINSZ`, breaking the terminal. The view keeps its full frame but is invisible and non-interactive.
- When shown: restores opacity and hit testing

### Sizing

- `appState.conductorHeight: CGFloat` — persisted in UserDefaults, default 300px
- Drag handle at bottom edge uses the same deferred-commit pattern as existing `SplitDivider` — shows blue indicator during drag, commits on release
- Min height: 100px. Max height: 80% of content area.

### Background

Nearly opaque with blur: `.background(.ultraThinMaterial)` or solid dark background with ~0.93 opacity. Matches the user's iTerm2 guake profile aesthetic (transparency 0.065, blur radius ~5).

## Conductor Lifecycle

### Toolbar Toggle

A button in the `ContentView` toolbar, next to the auto-suspend toggle. Shows a conductor icon.

**States:**
- **No conductor for this repo:** Click runs `conductor.setup` (name auto-derived: `repo.displayName` lowercased, non-alphanumeric chars replaced with hyphens, e.g. "My App" → "my-app"; all worktrees, manual polling) → `conductor.start` → shows overlay. One click, zero config.
- **Conductor exists but hidden:** Click shows overlay.
- **Conductor visible:** Click hides overlay.

**Context menu (right-click):**
- **Stop conductor** — kills tmux window, keeps config/DB row. Button returns to "not running" state. Next click runs `conductor.start` (no re-setup).
- **Remove conductor** — runs `conductor.teardown` (stop + remove DB row + remove directory). Clean slate. Next click runs full setup.

### Repo Scoping

The conductor is tied to a repo. When the user selects a worktree in a different repo, the overlay shows/hides the conductor for *that* repo's conductor. If the other repo has no conductor, the overlay is empty and the button shows "no conductor" state. Each repo has at most one conductor (simplification for now).

**Conductor-to-repo matching:** The `Conductor` model has `repos: [String]` which is either `["*"]` (all repos) or specific repo ID strings. To find the conductor for a given repo: check all conductors for one whose `repos` contains the repo's UUID string or `"*"`. A `["*"]` conductor matches every repo. If multiple conductors match (unlikely in practice), use the first one found. The app builds `conductorsByRepo: [UUID: Conductor]` client-side by expanding wildcard conductors across all known repos.

## Hotkey

**Default:** Opt+. (Option + period)

Registered via `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` at app startup. Only fires when TBD is the active app. Toggles `appState.showConductor`. The monitor consumes the event (returns `nil`) when matched, preventing propagation to terminals or other responders.

Hotkey is configurable, stored in UserDefaults. Settings UI deferred.

## Focus Management

1. **Conductor appears:** Conductor terminal becomes first responder. User can type immediately.
2. **Conductor hides:** Previous first responder is restored (stored before showing conductor).
3. **User clicks a terminal below the overlay:** That terminal becomes first responder. Conductor stays visible but unfocused. Standard NSView first responder chain handles this naturally.
4. **Re-focus conductor:** Click inside the conductor overlay, or Opt+. twice (hide/show).
5. **Cmd+G (go to suggestion):** Navigates to suggested worktree, clears suggestion. Conductor stays visible.

No custom focus management needed beyond sequencing `makeFirstResponder` calls on show/hide. SwiftUI hit testing + NSView responder chain handles the rest.

## Navigation Suggestions

The conductor can set a navigation target via RPC. The app renders a non-blocking pill at the bottom of the conductor overlay.

### New RPC Methods

| Method | Params | Result | Description |
|--------|--------|--------|-------------|
| `conductor.suggest` | `name: String, worktreeID: UUID, label: String?` | void | Set navigation suggestion |
| `conductor.clearSuggestion` | `name: String` | void | Clear navigation suggestion |

Param structs use `name: String` to match the existing `ConductorNameParams` convention.

**No `conductor.info` RPC needed.** The app already polls `conductor.list` — the suggestion state is included in the polling response by adding an optional `suggestion` field to the `Conductor` model returned by `conductor.list`/`conductor.status`.

### New CLI Commands

```bash
tbd conductor suggest <name> --worktree <id> [--label "waiting for input"]
tbd conductor clear-suggestion <name>
```

### Suggestion Bar

`ConductorSuggestionBar` sits below the drag handle. ~28px tall. Only visible when a suggestion is active.

```
│ 🔗 fix-auth — waiting for input    [Go] [✕] │
```

- **Click / Go button:** Sets `appState.selectedWorktreeIDs = [worktreeID]`, clears suggestion. Does NOT auto-hide the conductor — the user may want to keep it open.
- **Dismiss (✕):** Clears suggestion without navigating.
- **Cmd+G:** Same as clicking Go — navigates to suggested worktree, clears suggestion. Only active when a suggestion exists and conductor is focused.

### Data Flow

Suggestion state is in-memory on `ConductorManager` (not DB — transient UI state).

**Primary mechanism: polling.** The app's existing 2-second poll cycle calls `conductor.list`. The `Conductor` result type gains an optional `suggestion: ConductorSuggestion?` field (worktreeID + worktreeName + label). The app compares against previous poll to detect changes. This means suggestion updates have up to 2s latency — acceptable for a non-blocking pill.

**No StateDelta subscription needed.** The app currently has no live StateDelta subscription (it's poll-only via `refreshAll()`). Adding a persistent socket connection for push updates is out of scope. If subscriptions are added later, a `conductorSuggestionChanged` delta case can be added for lower latency.

**Polling integration:** Add `refreshConductors()` to `AppState.refreshAll()`. This calls `conductor.list`, populates `conductorsByRepo` (expanding `["*"]` conductors across all repos), `conductorTerminalsByRepo`, and `conductorSuggestion`.

### CLAUDE.md Template Additions

```markdown
## Navigation Suggestions

When discussing a specific worktree, help the user navigate to it:

| Command | Description |
|---------|-------------|
| `tbd conductor suggest <your-name> --worktree <id>` | Show a "Go to" pill in the UI |
| `tbd conductor suggest <your-name> --worktree <id> --label "waiting for input"` | With context label |
| `tbd conductor clear-suggestion <your-name>` | Remove the pill |

Set a suggestion when surfacing info about a worktree. Clear it when moving on to a different topic or when the user has acknowledged it.
```

## AppState Additions

```swift
// Conductor state
@Published var showConductor: Bool = false  // defaults false, even if conductor is running
@Published var conductorHeight: CGFloat = 300  // persisted in UserDefaults
@Published var conductorsByRepo: [UUID: Conductor] = [:]  // from polling, wildcard-expanded
@Published var conductorTerminalsByRepo: [UUID: Terminal] = [:]
@Published var conductorSuggestion: ConductorSuggestion?  // from polling conductor.list

// Derived
var currentConductor: Conductor?  // conductor for the repo of currently selected worktree
var conductorActive: Bool  // currentConductor != nil && its terminal exists
```

`ConductorSuggestion` is an app-only struct (in AppState or a local types file), derived from the `suggestion` field on the `Conductor` wire type returned by `conductor.list`. It is NOT a shared model in `ConductorModels.swift`.

## File Changes

### New Files
- `Sources/TBDApp/Conductor/ConductorOverlayView.swift` — overlay container
- `Sources/TBDApp/Conductor/ConductorSuggestionBar.swift` — navigation pill strip
- `Sources/TBDApp/Conductor/ConductorHotkeyMonitor.swift` — local NSEvent monitor

### Modified Files
- `Sources/TBDApp/ContentView.swift` — `.overlay()` + toolbar toggle button with context menu
- `Sources/TBDApp/AppState.swift` — conductor state properties + `refreshConductors()` in poll cycle
- `Sources/TBDShared/RPCProtocol.swift` — `conductor.suggest`, `conductor.clearSuggestion` methods + param structs
- `Sources/TBDShared/ConductorModels.swift` — add optional `suggestion` field to `Conductor` model (worktreeID, worktreeName, label)
- `Sources/TBDDaemon/Server/RPCRouter+ConductorHandlers.swift` — suggest/clearSuggestion handlers
- `Sources/TBDDaemon/Conductor/ConductorManager.swift` — in-memory suggestion state, CLAUDE.md template update
- `Sources/TBDApp/DaemonClient.swift` — use existing `conductor.list` for polling conductors
- `Sources/TBDCLI/Commands/ConductorCommands.swift` — suggest/clear-suggestion subcommands

### No DB Migration

Suggestions are transient (in-memory). Conductor records already exist from Phase 1a (migration v9).

## Testing

- **RPC handler tests:** conductor.suggest sets suggestion, conductor.clearSuggestion clears it, suggest overwrites previous suggestion
- **ConductorManager tests:** suggestion state lifecycle (set, overwrite, clear, clear when none exists); suggestion included in conductor.list/status results
- **Conductor model tests:** encode/decode `Conductor` with optional `suggestion` field (nil and non-nil)
- **UI:** Manual testing — toggle overlay, resize via drag handle, Opt+. hotkey, suggestion pill click → navigation, dismiss suggestion, focus flow between conductor and worktree terminals
