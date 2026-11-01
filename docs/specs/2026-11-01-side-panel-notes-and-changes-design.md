# Notes and Changes in the side panel

Status: design, approved for implementation planning
Date: 2026-11-01
Builds on: [`2026-10-30-panel-tabs-design.md`](2026-10-30-panel-tabs-design.md) (panel tabs)

Notes stop being workspace tabs, and the Changes list stops being a column at
the window's right edge. Both become side-panel tabs that belong to the whole
worktree, so they follow the user across the worktree's workspace tabs, and
agents show and hide them through the same `tbd panel` commands as everything
else in the side panel.

## Problem

- **Notes crowd the workspace tab bar.** Every note row becomes a workspace tab
  (`AppState.reconcileNoteTabs`), and every new worktree starts with one, so
  the bar that holds a worktree's agents also holds its scratch text. A note is
  reference material beside the work, which is what the side panel is for.
- **The Changes list is a second right-hand area.** `FileViewerPanel` sits in
  its own column at the window's right edge, toggled from the window toolbar
  (⌘⇧E), beside the side panel that now holds every other viewer. Clicking a
  file in it opens a workspace tab rather than a side-panel tab.
- **Both are about the worktree, not one terminal.** The side region belongs to
  one workspace tab, so a note or the Changes list opened there disappears when
  the user switches to another workspace tab in the same worktree.
- **Agents cannot reach either.** A note shows as a workspace tab, which the app
  owns, and the Changes column is app state.

## Goals

- Notes and the Changes list are side-panel tabs.
- They belong to the worktree: once open, they show in the side panel of every
  workspace tab in that worktree.
- Agents show and hide them with `tbd panel`, and can find a worktree's notes
  without the app.
- The Changes column, its toolbar button and the notes in the workspace tab bar
  go away, and nothing a user had is lost on the way.

## Non-goals

- **A side panel shared by the whole worktree.** Transcripts and opened files
  stay per workspace tab.
- **Note history.** A note panel shows one note and never navigates.
- **Deleting a note's content file.** `note.delete` keeps it, as it does today.

## The model

```swift
struct WorktreePanel {           // one worktree-wide tab in the side strip
    let id: PanelID
    var content: WorktreePanelContent  // .note(noteID) | .changes
}
```

A worktree holds an ordered list of worktree panels. Each workspace tab's
surface carries that list beside its own `SideRegion`, and its strip shows the
worktree panels first, then the tab's own panels.

- **Kinds.** Note and Changes panels are only ever worktree panels, and file,
  web and transcript panels only ever belong to a tab. `PanelKind` gains
  `changes`.
- **At most one worktree panel per note, and at most one Changes panel** per
  worktree.
- **What stays per workspace tab:**
  - **The panel in front.** `activePanelID` may name a worktree panel, so one
    workspace tab can show the note while another shows its transcript.
  - **Collapse.** A collapsed region hides worktree panels in that tab too.
  - **Recency.** It still covers the tab's own panels only and drives the reuse
    rule, which worktree panels take no part in.
- **No history.** A worktree panel has no history, so `history` and `navigate`
  on one are refused, and the strip's history buttons are dimmed in front of
  it, as they are for a transcript.

## Operations

`PanelOperation` keeps its cases. What changes for worktree content:

- **`open(.note(id))` and `open(.changes)`.** If the worktree already has a panel
  for that content, `open` selects it in the target tab and clears that tab's
  `collapsed`. Otherwise it appends a worktree panel, then selects it the same
  way. `newPanel` is ignored: a note is never shown twice.
- **`close` on a worktree panel** removes it from the worktree, so from every
  workspace tab. Each tab that had it in front brings its most recent remaining
  panel forward. Closing alone never deletes a note (see "Notes").
- **`close` on a tab's own panel** works as before, with one addition. When it
  closes the panel in front and leaves the tab with no panels of its own while
  worktree panels remain, the first worktree panel comes forward and the
  region collapses. Nearly every worktree has a note, so without this the
  transcript button and a file's × would leave the region open on the note
  rather than hide it.
- **`select`** is per tab, as before.

A change to the worktree's panel list rewrites every workspace tab surface of
that worktree, each taking a revision from the daemon-wide counter, in one
transaction. One `panelSurfaceChanged` delta carries them all, so the app's
revision guard needs nothing new.

## Daemon

- **Store.** A new table, `worktree_panel`: `id`, `worktreeID` (cascading on the
  worktree row), `position` and `content` (JSON). `PanelSurfaceStore` joins it
  into every surface it reads for that worktree, and writes it inside the
  `applyReducing` transaction.
- **Reclamation**, extended the way the surfaces were (panel tabs spec, "Tab
  sync"): archiving a worktree deletes its worktree panels in the same
  transaction; a scratch promote moves its Changes panel to the main worktree,
  unless the main worktree has one, and deletes its note panels, because a
  promote leaves the notes themselves with the archived scratch worktree, and
  a note's content file is keyed by that worktree; the cascade covers a
  deleted row. Archiving keeps the notes. A revive reopens a worktree panel
  for each of the worktree's notes, in creation order, in the transaction
  that takes the row out of archived.
- **Notes follow their panels.** `note.delete` deletes the note's worktree panel
  in the same transaction and broadcasts the change.
- **New worktrees.** Worktree creation makes the initial "Notes" note as
  before, carryover seed included, and opens it as a worktree panel instead of
  appending it to the tab order. It also writes the surface of the
  worktree's main tab, with the note in front and the region open, so a new
  worktree opens its starter note visibly; the app's first tab sync keeps that
  surface, as it keeps any it can read. The config column
  `auto_create_notes_enabled` keeps its meaning. Its Settings label becomes
  "Open a Notes panel for new worktrees".
- **Imported tabs.** A tab the daemon imports in a tab sync with no panels of
  its own comes out collapsed when its worktree has worktree panels, with the
  first one in front. Most tabs have no surface when the app updates, and
  every new terminal tab is imported, so without this an update, or a new
  tab, would open the side region and narrow the terminal. A tab that brings
  panels of its own keeps its collapse state.
- **Migration.** Existing notes move into the side panel. For every note row,
  the migration:
  - inserts a worktree panel in the worktree's tab order;
  - removes the note's ID from `worktree.tabOrder`;
  - removes its tab row;
  - deletes any surface whose primary is that note, with its side region;
  - removes every panel in a tab's own side region that shows that note, and a
    tab that had one in front brings the note's worktree panel forward.

  Afterwards a note shows only in its worktree panel, which `note.delete`
  removes, so no panel is left showing a deleted note.

  The migration narrows no terminal. Nearly every worktree has its starter
  Notes note, so a worktree panel would otherwise open the side region of
  every tab the moment the app updates, with nothing the user did behind it.
  So a tab whose side region had no panels comes out collapsed, with the
  worktree's first panel in front, one ◫ away. A tab that had panels keeps
  its collapse state and the panel in front, and the worktree panels join its
  strip; the one exception is a tab whose own note panel was in front, which
  brings the note's worktree panel forward, as above. A tab with no surface
  yet comes out collapsed when the app's next tab sync imports it (see
  "Imported tabs"). New worktrees differ on purpose: creation opens the
  starter note visibly in the main tab, which is what the "Open a Notes panel
  for new worktrees" setting asks for.

  The JSON edit of `tabOrder` takes the Swift escape hatch in
  `SQLMigrationLoader.inlineTimestampMigrations`, unless the `.sql` allowlist
  can express it.

## App

- **Notes leave the tab bar.** `reconcileNoteTabs` goes, and with it the note
  branch of `closeTab`. The workspace bar's + menu loses "Note": a note is made
  only from the side strip's + menu, so it is born where it lives. `.note` stays
  a `PrimaryContent` case for decoding, and nothing creates one.
- **The strip.** It reads: history buttons, then the worktree panels, then the
  tab's own panels, then a **+** menu, the active panel's own control, and
  collapse. The + menu offers New Note, Changes, and every note of the worktree
  that has no panel.
- **Closing a note's tab** works as the panel tabs spec says: the app asks
  first when the note has content, then deletes it. The `close` operation alone
  keeps it, so a note an agent closed stays in the + menu.
- **Renaming a note's tab** writes the note's title (panel tabs spec).
- **Changes.**
  - **What it shows:** the Changes panel shows today's `FileViewerPanel` list:
    staged, changes, untracked and branch, with its refresh button.
  - **Clicking a file** sends `open(.file)`, so the reuse rule places it;
    Shift-click sends it with `newPanel`.
  - **What goes:** the right-hand column, its divider, the `filePanel.isVisible`
    and `filePanel.width` keys, and the toolbar's file-panel button.
- **The side panel toggle.** ◫ shows in the workspace tab bar whenever the
  region is hidden. On a collapsed region with panels it expands it; on an empty
  region it opens Changes.
- **⌘⇧E** follows the transcript button's rule for Changes:
  - no Changes panel: open one;
  - open but not in front, or the region collapsed: select it;
  - in front and visible: close it.

  It becomes a menu command, so it works without a toolbar button. A tab the
  daemon could not import, such as one with a terminal split off, still draws
  through the legacy split layout, which has no side region: there ⌘⇧E beeps,
  and the worktree's notes and Changes are reached from any other tab.

## CLI and agent guidance

- `tbd panel open <worktree> --changes` shows the Changes panel. `--note <id>`
  shows a note, now worktree-wide. `close --panel <id>` hides either.
- `tbd panel list` marks worktree panels as worktree-wide and lists them first.
- **A new read-only command**, `tbd note list <worktree> [--json]`, prints each
  note's ID, title, and whether it has a panel, so an agent can show a note
  without the app.
- **The agent guidance** in `TBDSkillContent.swift` says that notes and Changes
  are worktree-wide, that showing one shows it in every workspace tab of the
  worktree, and that closing a panel never deletes a note.

## Rollout

No flag. Panel tabs ship to everyone without one, and this moves existing items
by the same decision of the owner's. The way back is a revert and a release.
Neither a revert nor a downgrade makes the moved notes reappear as workspace
tabs, so they are reached through the side panel's + menu until one does.

## Testing

- **Shared:**
  - The reducer opens, selects and closes worktree panels, and selects per tab.
  - Closing the own panel in front collapses the region when it leaves only
    worktree panels, and changes no collapse otherwise.
  - A close moves each affected tab's front to its most recent remaining panel.
  - `history` and `navigate` on a worktree panel are refused.
  - The validator enforces the kinds rule and both at-most-one rules.
  - The existing 40-seed property test is extended with worktree panels.
- **Daemon:**
  - A worktree panel change rewrites every tab surface of the worktree, each at
    a fresh revision, in one delta.
  - `note.delete` removes the note's panel.
  - Archive deletes the worktree's panels, and promote moves the Changes
    panel and deletes the note panels. A revive reopens a panel for each
    note, in creation order, and duplicates none.
  - Creation opens the initial note as a panel, in front of an open region in
    the main tab, when `auto_create_notes_enabled` is on, and opens none when
    it is off.
  - A tab sync imports a tab with no panels of its own collapsed when the
    worktree has worktree panels, and leaves a tab with its own panels, or in a
    worktree without worktree panels, as it came.
  - The migration moves a note out of `tabOrder` into the worktree's panels,
    replaces a tab's own note panel with the worktree panel (in front when the
    old one was), collapses a tab whose side region had no panels, leaves a
    tab that had panels with its collapse state and front, and leaves a
    worktree with no notes untouched.
- **CLI:** parsing for `--changes` and `tbd note list`.
- **App:**
  - No note becomes a workspace tab.
  - The workspace bar's + menu has no Note item.
  - The side strip's + menu lists exactly the notes without a panel.
  - ◫ opens Changes on an empty region and expands a collapsed one.
  - ⌘⇧E's three states each send the right operation.
  - A file click in Changes sends `open(.file)`, and Shift-click sends it with
    `newPanel`.
  - The right column and its keys are gone.

## Risks

- **Legacy-drawn tabs have no side region.** A tab with a terminal split off
  cannot be imported and draws through the legacy split layout, so with the
  Changes column gone it reaches notes and Changes only through another tab of
  its worktree.
- **Surfaces whose primary was a note lose their side panels** in the
  migration. Those panels were opened beside a note tab, and their files and
  pages can be reopened.
- **One note edit rewrites every tab surface of the worktree.** A worktree has
  few tabs, and the write is one transaction.
- **App and daemon skew.** An app older than this migration finds the notes gone
  from the tab bar and no way to show them until it updates.

## Rejected alternatives

- **Notes and Changes per workspace tab.** No model change, but switching
  workspace tabs hides them, though neither belongs to one tab.
- **One side panel shared by the whole worktree.** It reverses the per-tab model
  that keeps each agent's transcript and opened files beside its own terminal.
- **Only the worktree's first note in the side panel.** Notes would have two
  homes.
- **Reusing a note panel with history, as files do.** A note is a document the
  user keeps open; stepping it through other notes hides one to show another.
- **Moving only the Changes button.** It keeps two right-hand areas side by side.
- **Keeping "Note" in the workspace bar's + menu.** That menu makes workspace
  tabs; a note made there would appear somewhere other than where it was asked
  for.
