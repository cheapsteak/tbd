# Sidebar navigation history survives app restarts

## Problem

The toolbar Back and Forward buttons (⌘[ and ⌘]) step through the places a
user has selected in the sidebar: a worktree or a multi-worktree selection, a
repo's archived list, or a remote session. This history lives only in app
memory — `navigationEntries` and `navigationIndex` on `AppState`. When the app
quits, it is gone. The app does restore the current worktree selection
(`com.tbd.app.selectionOrder` in UserDefaults), so after a restart the user
lands in the right place with nothing behind them, and Back is disabled.

## The three histories in TBD

TBD has three separate Back/Forward histories. Only the first is lost on
restart, and only the first is in scope.

- **Sidebar history** – toolbar arrows, ⌘[ / ⌘]. Up to 100 entries. Held in
  `AppState` memory only (`AppState.swift`, `AppState+Navigation.swift`).
  Lost on every app restart. **This spec.**
- **Pane history** – the arrows in a viewer pane's header. Up to 10 entries
  per pane (`MRUHistory`). Already saved in UserDefaults
  (`com.tbd.app.paneHistories`) and restored at launch; pruning waits until
  every visible worktree's tabs have been reconciled, so a partly loaded tab
  list cannot wipe it (#515).
- **Daemon panel history** – `tbd panel back` / `tbd panel forward`. Stored in
  the daemon database (`panel_history` table, `PanelSurfaceStore`), so it
  survives app and daemon restarts. Active only when
  `daemon_panel_surface_enabled` is on (default off).

A daemon restart on its own does not touch the sidebar history, because the
app keeps running. Only an app restart — including logout and reboot — loses
it, so only app restarts need covering.

## Design

### Storage

One new UserDefaults key, `com.tbd.app.navigationHistory`, in the
`AppState.userDefaults` domain. Its value is JSON holding the entry list and
the current index.

`NavigationEntry` and `RemoteSessionSelection` become `Codable`, using the
conformance Swift synthesizes. No other type changes.

UserDefaults fits because this is app-only presentation state that nothing
else in TBD reads, and it sits beside the two comparable values the app
already keeps there: the current selection and the pane histories. Nothing
outside the app needs the history, so it does not belong in the daemon
database. It is not a user-written blob, so it does not belong in a file under
`~/tbd/`.

### Saving

Every path that changes the list or the index — `recordNavigation`,
`navigateBack`, `navigateForward`, `navigateBackPastArchived` — already ends
by calling `updateNavigationFlags()`. A single helper replaces those calls: it
refreshes the toolbar flags, then writes the history to UserDefaults. Routing
every mutation through one helper means no change path can skip the save.

This writes UserDefaults once per sidebar navigation, the same rate at which
selection changes already write `selectionOrder`.

### Loading

`AppState.init` restores the history next to `restoreLayouts()` and
`restorePaneHistories()`, before `restoreSavedSelection` runs in
`connectAndLoadInitialState()`.

The decoded value is accepted only when it is well formed:

- the entry list holds at most 100 entries (`navigationHistoryCap`);
- an empty list comes with index -1;
- a non-empty list comes with an index inside the list.

Anything else — bad JSON, an unknown entry shape, an index out of range — is
discarded, and the app starts with an empty history, as it does without this
change. A damaged value can never crash the app or leave the index pointing
outside the list.

The index is restored as saved, so Forward entries survive. A user who pressed
Back from R to Q and then quit reopens on Q with Back leading to P and
Forward leading to R.

### Saved selection versus saved history

The two values are saved separately and can disagree — for example, if the
app crashes between the two writes. The restored selection is the truth.

No new code is needed for this. `restoreSavedSelection` already ends with
`recordNavigation(.worktrees(filteredIDs))`, and `recordNavigation` behaves
correctly against a restored history:

- when the restored selection equals the entry at the restored index, the call
  is a no-op and Forward entries are kept;
- when it differs, the selection is appended as a new entry and Forward
  entries are cut, exactly as a click would.

A pending deep link wins over the saved selection, as today, and records its
own entry the same way.

`restoreSavedSelection` restores worktree selections only. If the user quit
while viewing a repo's archived list or a remote session, the app reopens with
nothing selected while the restored index still points at that entry. Back
still works from there. Restoring repo and remote-session selections is out of
scope.

### Entries that point at something gone

Restored entries are never removed for being stale. Back and Forward already
skip any entry whose target no longer exists (`usableEntryIndex`): an archived
or deleted worktree, a removed repo, a dismissed remote session. Dead entries
fall off the old end as the 100-entry cap pushes them out.

Pruning at load is rejected, because the worktree, repo and remote-session
lists are all empty at launch and fill in over several refreshes; remote
sessions come from providers and can arrive late. Any prune that ran before
every list had loaded would read every entry as dead and delete the whole
history — the same failure #515 fixed for pane histories.

Because the toolbar flags are computed against those lists, a flag computed at
launch would read false. `updateNavigationFlags()` therefore also runs after
each refresh of the worktree, repo and remote-session lists, so the arrows
enable themselves once the data arrives without waiting for a click. This
refresh only recomputes flags and does not save.

### Size

The saved list uses the in-memory cap: 100 entries. An entry is one UUID, a
handful of UUIDs, or a provider name and session id, so the saved value is a
few kilobytes at most. There is no age-based expiry.

## Feature flag

None. The change acts only when the user presses Back or Forward, as today;
it adds one UserDefaults key and deletes nothing; no UI moves. The one new
risk — a damaged saved value — is contained by the load-time validation
above. The PR description restates this.

## Testing

Tests construct `AppState(userDefaults: UserDefaults(suiteName:))` and remove
the suite in teardown, so they never touch the developer's real
`TBDApp.plist`. A second `AppState` built on the same suite stands in for an
app restart.

- **Round trip with position** – record P, Q, R; go Back once; build a new
  `AppState` on the same suite. The index is on Q, Back reaches P, Forward
  reaches R.
- **Every entry kind round-trips** – `.worktrees` with several IDs in order,
  `.repo`, `.remoteSession`.
- **Matching restored selection** – restoring a selection equal to the entry
  at the restored index keeps the Forward entries.
- **Differing restored selection** – restoring a different selection appends
  it and cuts the Forward entries.
- **Damaged data** – bad JSON, an index past the end, a negative index with a
  non-empty list, an empty list with index 0, and more than 100 entries each
  load as an empty history without crashing.
- **Stale entries** – restored entries whose worktrees are missing are skipped
  by Back, and stay in the saved list.
- **Flags after load** – right after restore, with empty lists, Back is
  disabled; after the worktree list loads, Back is enabled.
- **Cap** – after a reload, recording past 100 entries still drops the oldest.
- **Every mutation saves** – after `recordNavigation`, `navigateBack`,
  `navigateForward` and `navigateBackPastArchived`, a fresh `AppState` on the
  same suite sees the new list and index.

## Out of scope

- Pane history and daemon panel history, which already survive restarts.
- Restoring a repo or remote-session selection at launch.
- Sharing sidebar history with the CLI or across machines.
