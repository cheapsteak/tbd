# Pre-session hook: correct the menu naming, offer to create a missing hook

Date: 2026-07-09
Follows: `2026-07-08-rerun-presession-hook-design.md` (shipped as PR #405, merged as `2181073a`)

## Problem

Two independent defects in the context-menu entry shipped by #405.

**1. The label names the wrong hook.** TBD has five hook events, two of which fire on
worktree creation and are routinely confused:

| Settings heading | `HookEvent` case | Behavior |
| --- | --- | --- |
| Pre-session hook | `preSession` | Runs in a visible terminal; **blocks** the agent from starting |
| Setup hook | `setup` | Runs in parallel alongside the agent; does **not** block |

The context-menu item reads **"Re-run setup hook"** but resolves and runs `HookEvent.preSession`.
So it names one real hook while running a different real hook. Four daemon-side strings inherit
the same mistake. The behavior is correct throughout — `rerunPreSessionHook`, the
`worktree.rerunPreSession` RPC, and the app's `hasPreSessionHook` gate all key off
`HookEvent.preSession`. Only the user-visible text is wrong, and all five strings were
introduced by #405 (commit `5b094015`), so no pre-existing prose is in scope.

**2. A missing hook is invisible.** When no `preSession` hook resolves, the entry is hidden
entirely. A user who wants one has no affordance and must know to look in
Settings → repo → Settings tab → scroll past the model-profile picker and env overrides.

## Goals

- The menu, the daemon's error, and the daemon's notifications all say *pre-session hook*.
- A regular worktree with no `preSession` hook offers **Create pre-session hook…**, which
  reveals the editor that authors it.
- No change to what any hook does, when it runs, or which file resolves.

## Non-goals

- **The main-repo row.** `mainItems` has no maintenance section and does not gain one, even
  though a repo-scoped "create a hook" arguably belongs there. Out of scope by request.
- **A global-hooks editor.** `~/tbd/hooks/default/preSession` is the fallback for *every* repo
  that has no per-repo hook. Nothing in this change authors it.
- **`.worktree-hooks/preSession` authoring.** Nothing in the app writes that rung of the
  resolution chain today, and this change does not start.
- Renaming the `setup` event, its Settings heading, or the `setup`-hook comments in
  `WorktreeLifecycle+Create.swift` — those are correct as written.

## Behavior

### Menu states

`isScratch` is *defined* as `repoID == nil` (`Models.swift:156`), so a regular row always has a
repo and a scratch row never does. That makes the matrix total without a new `Context` field:

| Row | `preSession` hook resolves | No hook resolves |
| --- | --- | --- |
| Regular | `Re-run pre-session hook` | `Create pre-session hook…` |
| Scratch | `Re-run pre-session hook` | *(section collapses — no entry, no divider)* |
| Main / creating | *(unchanged — `mainItems` has no maintenance section)* |

The scratch/no-hook cell is empty because a scratch space has nowhere repo-scoped to route:
`ScratchDetailView`'s Settings tab holds only global scratch config and has no hooks editor.
Its hook, if any, comes from the scratch dir's `.worktree-hooks/` or the global default — both
non-goals above. So scratch keeps exactly today's behavior.

The trailing ellipsis on **Create pre-session hook…** follows the macOS convention: the item
opens further UI rather than acting immediately.

### Create → reveal

Clicking **Create pre-session hook…** selects the worktree's repo, switches its detail pane to
the **Settings** tab, scrolls to the **Pre-session hook** section, and focuses its `TextEditor`.
It does not write a file — the user types the hook and the existing save path in
`RepoHooksSettingsView` persists it to `~/tbd/repos/<uuid>/hooks/preSession`.

Once saved, the same menu entry becomes **Re-run pre-session hook** on the next right-click,
because `hasPreSessionHook` re-resolves from disk each time the menu is built.

## Design

### 1. Strings

Five strings change. All are the only occurrence of their text.

| Location | From | To |
| --- | --- | --- |
| `RowActionMenu.swift:174` (`rerunPreSessionLabel`) | `Re-run setup hook` | `Re-run pre-session hook` |
| `WorktreeLifecycle+PreSession.swift:460` (`.alreadyRunning`) | `Setup hook is already running for this worktree.` | `Pre-session hook is already running for this worktree.` |
| `WorktreeLifecycle+PreSession.swift:462` (`.worktreeBusy`) | `…its setup hook is already running.` | `…its pre-session hook is already running.` |
| `WorktreeLifecycle+PreSession.swift:546` (failure notification) | `Setup hook failed (exit N) — …` | `Pre-session hook failed (exit N) — …` |
| `WorktreeLifecycle+PreSession.swift:551` (timeout notification) | `Setup hook timed out after Ns` | `Pre-session hook timed out after Ns` |

Prose to match: the `RowActionMenu.items` doc comment (§4 "Maintenance") and the two lines in
`docs/worktree-hooks.md` (`:32`, `:34`). The `.alreadyRunning` description remains the single
source of that sentence — the app surfaces it verbatim via `showAlert`, so no app-side copy exists.

`AppState+Worktrees.swift:296,298` log lines say "setup hook" too; they are `os.Logger` output,
not user-facing, but they change with the rest so `log stream` reads consistently.

### 2. Menu model (`RowActionMenu.swift`)

`Kind` gains a payload-free case, and a label constant joins `rerunPreSessionLabel`:

```swift
case createPreSessionHook

static let createPreSessionLabel = "Create pre-session hook…"  // U+2026, not "..."
```

`maintenanceActions(context:)` grows the third state. It already receives `isScratch` and
`hasPreSessionHook`; no new `Context` field is required, and `items()` stays a pure function
of `Context`:

```swift
static func maintenanceActions(context: Context) -> [Action] {
    if context.hasPreSessionHook {
        return [Action(kind: .rerunPreSessionHook, title: rerunPreSessionLabel)]
    }
    // A scratch space (repoID == nil) has no repo hooks editor to reveal.
    guard !context.isScratch else { return [] }
    return [Action(kind: .createPreSessionHook, title: createPreSessionLabel)]
}
```

Both call sites (`regularItems`, `scratchItems`) already route through `maintenanceActions`, so
the section placement — its own section between spawning and the filesystem section, above
`Open in Finder` — is unchanged. The empty return keeps `joined(...)` collapsing the section,
so a hookless scratch row still renders no dangling divider.

### 3. Dispatch (`RowActionMenuActions.swift`)

The new kind carries no payload; the dispatcher reads the repo from the worktree it already
holds. A regular row always has a `repoID`, so the `guard` is a total-function formality:

```swift
case .createPreSessionHook:
    guard let repoID = worktree.repoID else { return }
    appState.revealPreSessionHookEditor(repoID: repoID)
```

`hasPreSessionHook` — the private computed property doing the `HookResolver` filesystem walk —
is unchanged.

### 4. Reveal plumbing (`AppState`, `RepoDetailView`, `RepoHooksSettingsView`)

A one-shot published request, consumed by the view. This mirrors how `selectedRepoID` and
`selectedScratchSection` already drive the detail pane.

```swift
// AppState.swift, beside selectedRepoID
/// One-shot request to reveal a section of a repo's detail pane. Set by
/// `revealPreSessionHookEditor`, cleared by `RepoDetailView` once applied.
@Published var repoDetailReveal: RepoDetailReveal?

enum RepoDetailReveal: Equatable {
    case preSessionHook(repoID: UUID)
}
```

```swift
// AppState+Worktrees.swift, beside selectRepo(id:)
func revealPreSessionHookEditor(repoID: UUID) {
    selectRepo(id: repoID)
    repoDetailReveal = .preSessionHook(repoID: repoID)
}
```

`selectRepo(id:)` already clears `selectedWorktreeIDs` and `selectedScratchSection` and records
a navigation entry, so `ContentView` swaps in `RepoDetailView(repoID:)` on the next render.

**`RepoDetailView` must consume the reveal in both `onAppear` and `onChange`.** It is not
`.id(repoID)`-keyed — only its `RepoInstructionsView` / `RepoSettingsView` children are — so
SwiftUI reuses one instance across repo switches:

- Pane not yet mounted (no repo was selected): `onAppear` fires, `onChange` does not.
- Pane already mounted (another repo, or this repo on the Archived tab): the instance is
  reused, `onAppear` does not fire again, `onChange` does.

Handling only one of the two leaves a dead menu item in the other case. On match, the view sets
`selectedTab = .settings` and sets `appState.repoDetailReveal = nil` so the reveal is not
replayed when the user later navigates back. It ignores a reveal whose `repoID` is not its own.

`RepoSettingsView` wraps its existing `ScrollView` in a `ScrollViewReader` and, on the same
signal, scrolls to an anchor `.id(...)` placed on `RepoHooksSettingsView`'s pre-session section.
`RepoHooksSettingsView` takes an optional `FocusState<...>.Binding` so the pre-session
`TextEditor` receives focus; the `setup` and `archive` sections are untouched.

## Error handling

There is no new failure mode. The reveal is pure local navigation — no RPC, no filesystem
write, nothing to fail. A reveal naming an unknown or since-removed repo simply matches no
mounted `RepoDetailView` and is dropped; `selectRepo(id:)` on a stale ID already no-ops in the
same way today.

The `guard let repoID = worktree.repoID` in the dispatcher cannot fire for a regular row (that
is what `isScratch` means), and the menu never offers the action to a scratch row. It returns
silently rather than asserting, because a context menu is not a place to crash.

## Testing

`Tests/TBDAppTests/RowActionMenuTests.swift`
- regular + no hook → `.createPreSessionHook`, titled `Create pre-session hook…`
- regular + hook → `.rerunPreSessionHook`, titled `Re-run pre-session hook`
- scratch + no hook → neither kind present, **and** no doubled/dangling divider (assert the
  full `[Item]` sequence around the collapse point, not just the absence of the action)
- scratch + hook → `.rerunPreSessionHook`
- main → neither kind present

`Tests/TBDAppTests/PreSessionAppStateTests.swift` (exists)
- `revealPreSessionHookEditor(repoID:)` sets `selectedRepoID` and
  `repoDetailReveal == .preSessionHook(repoID:)`
- construct via `AppState(userDefaults: UserDefaults(suiteName:))` and tear down with
  `removePersistentDomain(forName:)` — `UserDefaults.standard` on this unbundled executable is
  the developer's real `TBDApp.plist`

`Tests/TBDDaemonTests/PreSessionRerunTests.swift`
- `rpcReportsAlreadyRunning` asserts the new sentence

**Live-only, requires the user:** the scroll-to-section and editor focus. SwiftUI context menus
do not respond to synthetic clicks, and scroll position/focus are not observable from a headless
harness. Verify by right-clicking a hookless worktree and confirming the Settings tab opens
scrolled to Pre-session hook with the editor focused.

## Files touched

| File | Change |
| --- | --- |
| `Sources/TBDApp/Helpers/RowActionMenu.swift` | `createPreSessionHook` kind, `createPreSessionLabel`, three-state `maintenanceActions`, renamed `rerunPreSessionLabel`, doc comment |
| `Sources/TBDApp/Sidebar/RowActionMenuActions.swift` | dispatch the new kind |
| `Sources/TBDApp/AppState.swift` | `RepoDetailReveal` enum, `repoDetailReveal` published property |
| `Sources/TBDApp/AppState+Worktrees.swift` | `revealPreSessionHookEditor(repoID:)`; log-line wording |
| `Sources/TBDApp/RepoDetailView.swift` | consume reveal in `onAppear` + `onChange`; `ScrollViewReader` in `RepoSettingsView` |
| `Sources/TBDApp/Settings/RepoHooksSettingsView.swift` | scroll anchor + optional focus binding on the pre-session section |
| `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+PreSession.swift` | four strings |
| `docs/worktree-hooks.md` | prose at `:32`, `:34` |
| `Tests/TBDAppTests/RowActionMenuTests.swift` | five cases above |
| `Tests/TBDAppTests/PreSessionAppStateTests.swift` | reveal test |
| `Tests/TBDDaemonTests/PreSessionRerunTests.swift` | updated assertion |
