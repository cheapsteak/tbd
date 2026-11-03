# Side panel toggle pills

The side region's Changes, transcript and Notes are each reached by one
button at the window's right edge. While one is open, that button draws as a
labelled pill, and the panel gets no tab of its own. The Changes button shows
only while the worktree has changes or its panel is open. A worktree has one
note.

Related specs: [`2026-11-01-side-panel-notes-and-changes-design.md`](2026-11-01-side-panel-notes-and-changes-design.md)
(worktree panels, the notes model) and
[`2026-11-02-tabs-in-toolbar-design.md`](2026-11-02-tabs-in-toolbar-design.md)
(the strip as the window's top row, `RowIconButtonStyle`).

## Problem

- **Two controls for one panel.** The transcript button opens a transcript
  panel, which then shows as a tab with its own ×. The button that opened it
  closes it too. So one panel has two close controls, and the button that
  turned it on sits at the far end of the strip from the tab it made. Notes
  work the same way.
- **The × on a note's tab deletes the note**, while the Notes button only
  closes its panel. Two controls on the same note do different things.
- **Several notes per worktree** give notes a + menu, a second note's tab, a
  "first note" for the button, and a deleting × beside a closing button.
- **Changes is buried in a menu.** It is reached from the strip's + menu or
  ⌘⇧E, though it is as worktree-wide as the notes.

## Goals

- One control per panel: Changes, the transcript and Notes each turn on and off
  from one pill, which shows the panel's name while it is open.
- No Changes control for a worktree with nothing to show in it.
- One note per worktree.
- No + menu in the strip.
- The strip keeps its 240 pt minimum width.

## Non-goals

- **Files and web pages.** They keep their tabs, each with its ×.
- **The workspace tab bar's + menu**, which makes workspace tabs, is unchanged.
- **Merging or deleting existing extra notes.** No data changes (see "Notes").
- **Daemon changes.** The panels, their operations and `note.create` stay as
  they are.

## The strip

Left to right:

1. **History buttons** (search, back, forward), unchanged.
2. **Tabs:** files, web pages, and any legacy extra note (see "Notes"), each
   with its ×. `SideRegionStrip.tabs` leaves out the transcript panel, the
   first note's panel and the Changes panel: their pills stand for them.
3. **The active panel's own control** (`SideRegionStrip.trailingControl`): a
   file's rendered/source toggle, a web page's copy-address, Changes' refresh.
4. **The pills:** Changes, transcript, Notes. The Changes pill is drawn only
   while the worktree has changes or its panel is open (see "The Changes
   pill"). The transcript pill is drawn wherever the transcript button is: on
   every tab while the transcript view is on, disabled in front of anything
   but a Claude terminal.
5. **Collapse.**

With the Changes pill absent, the trailing group is the active panel's
control, transcript, Notes and collapse.

With Tabs in the toolbar on, the drag gap fills the width between the last
tab and the trailing group, as before, so a strip whose only open panels have
pills is history buttons, drag gap, and the trailing group.

## Pills

Each pill has three states:

- **Off:** its icon alone, in the row's grey, in the 28 × 28 hover square every
  row icon button draws (`RowIconButtonStyle`).
- **On, in front:** icon and label in the label colour, filled as the selected
  tab is.
- **On, behind** another panel, or with the region collapsed: icon and label in
  the label colour, with no fill and no outline.

Labels: "Changes", "Transcript", "Notes". The Notes pill reads "Notes" whatever
the note's title. Icons: `plusminus` for Changes, `bubble` for the transcript,
filled (`bubble.fill`) while its panel is open, and `doc.text` for Notes.
Changes' tab symbol (`PanelKind.changesSystemImage`) is the same `plusminus`.

Each pill's hover and pressed square is the row's, sized to the pill's width,
so the feedback covers the shape the pill draws.

**When the strip is narrow,** the pills that are on keep their label colour,
and the one in front its fill, and drop their labels, so on, off, in front and
behind still read. The tabs give up their room first. One pure function of the
strip's width and the pills' states decides whether the labels show, so it can
be tested without a view. The pills' icon-only widths equal the buttons they
replace (Changes takes the + menu's slot), so `SideStripMetrics.fixedControlsWidth`
stays 240 pt. That width is a minimum: a pill that is not drawn only leaves the
tabs more room.

## The Changes pill

**When it shows.** The Changes pill, and the Changes button at the bar's end
while the region is hidden, show while the worktree's Changes list
(`ChangesSnapshot`) has anything in it, staged, unstaged or untracked files or
files the branch changed, or while the Changes panel is open in the tab, so an
open panel can always be closed. They are hidden while the last load found an
empty list, and before any load has finished. One pure function of the list's
emptiness and whether the panel is open decides it
(`TabRowEdgeControls.showsChanges`). ⌘⇧E still opens the Changes list
whatever it holds, and a ◫ press that finds the region empty still opens
Changes.

**Where the answer comes from.** The app's existing Changes cache
(`AppState.changesSnapshots`, `loadChangesSnapshot`, `ChangesSnapshotCache`);
the daemon is unchanged. Each load records whether its list is empty in an
observed per-worktree value (`AppState.changesListIsEmpty`), written only when
the answer changes, so a poll that finds what the last one found redraws
nothing.

**How it stays fresh.** `ChangesListPoller` loads the list of the worktree on
screen, the single selected worktree, and never of the other worktrees the
window keeps mounted. It polls:

- **when a worktree comes on screen**, through a change of the selection;
- **when TBD becomes active** (`NSApplication.didBecomeActiveNotification`);
- **every `ChangesSnapshotCache.maxAge` (10 s) while TBD is active**, counted
  from when the previous poll's loads finish.

A poll skips a list the cache holds fresh
(`changesSnapshotNeedsLoad(refresh: false)`) and a list a load is still
reading, so the poller never starts a second load of one worktree's list.
While TBD is inactive nothing polls. The poller sleeps on an injected clock
(`clock: any Clock<Duration> = ContinuousClock()`), so its schedule is tested
in virtual time.

## Clicks

Each pill follows the rule its button already follows (`PanelToggleDecision`):

- **Off:** open the panel, in front in this tab, expanding a collapsed region.
- **On, behind, or the region collapsed:** select it, which expands the region.
- **On, in front and visible:** close it. Closing a note's panel keeps the note.

The transcript pill sends what the transcript button sends
(`PaneActions.toggleTranscript`), the Notes pill what the Notes button sends
(`AppState.toggleNotesPanel`), and the Changes pill what ⌘⇧E sends, scoped to
the strip's own workspace tab rather than the tab on screen.

## Right-click menus

- **Transcript:** the file menu its tab had (`headerFileContextMenu` for the
  session's `.jsonl`).
- **Notes:** Delete Note…, which asks first when the note has text and then
  deletes it, as a note tab's × does. When the worktree has a legacy extra note
  with no panel, the menu also lists each one under Open Other Note, which opens
  it as a tab; with the + menu gone, nothing else reaches it.
- **Changes:** none.

The pills sit in the trailing group, under `RowIconButtonStyle`. A custom
`ButtonStyle` in the environment of a `.contextMenu` makes SwiftUI rebuild the
open menu continuously, which closes any open submenu (`Sources/TBDApp/CLAUDE.md`).
So each pill's menu content resets the style with `.buttonStyle(.automatic)`,
and the transcript's file menu, which has submenus, is checked live by logging
NSMenu's item notifications while it is open.

## Notes

- **One note per worktree:** the first, oldest by creation, as the Notes
  button's rule already picks. The Notes pill is its only control.
- **Nothing makes a second note.** The + menu's New Note goes. The Notes pill
  creates a note titled "Notes" only when the worktree has none, as the button
  does today. Worktree creation's starter note is that first note. The CLI
  has no note-creating command, and `note.create` stays as it is.
- **Legacy extra notes.** A worktree made before this change can have more than
  one. Each extra note whose panel is open shows as an ordinary tab with its ×,
  which deletes it, asking first when it has text. One with no panel is listed
  in the Notes pill's menu (above). Nothing merges, hides or deletes them, so a
  worktree drops to one note as its extras are deleted.
- **Deleting the first note** makes the next-oldest note the first: its tab
  goes, and the Notes pill stands for it.

## Side region hidden

While the region is hidden, the workspace tab bar's trailing end holds the
Changes, transcript and Notes buttons (`TabBarTrailingItem.edge`), then the
expand button, with Tabs in the toolbar on or off. The Changes button shows by
the Changes pill's rule. They draw as plain icons in the row's grey whatever
their panel's state, and a disabled one in the secondary colour: no panel is
in view, so none shows a label, an accent colour, or a filled symbol, each of
which would read as a panel showing. The transcript's is a plain `bubble`. A
click follows the pill's rule ("Clicks"), so it expands the region.

## Rollout

This ships without a setting. It moves items users rely on: the transcript and
note tabs leave the strip, and the + menu goes. The repo's rule asks for a
default-off setting for such changes, and the project's owner chose to ship it
directly. The Changes poller runs on a timer, which the same rule covers; it
only reads git, for the one worktree on screen while TBD is active, as the
Changes list already does when it appears. Going back is a revert; no state
changes, so a revert restores the old strip with every panel and note intact.

## Testing

- **`SideRegionStrip.tabs`** leaves out the transcript panel, the first note's
  panel and the Changes panel, and keeps files, web pages and extra notes.
- **Trailing items:** the order (active panel control, Changes, transcript,
  Notes, collapse) with and without an active panel control, a transcript pill
  and a Changes pill; no + menu.
- **Pill state:** off, in front, and behind, for each pill, including a
  collapsed region reading as behind.
- **Icons:** `plusminus` for Changes in the pill, the tab and the bar; the
  transcript pill's bubble filled while on; the bar's three icons in the row's
  grey, with a plain `bubble`, in every state.
- **The Changes pill's show rule**, one case per branch: no list loaded and the
  panel closed, hidden; an empty list and the panel closed, hidden; a list with
  files, shown; the panel open with an empty list or none, shown. The strip and
  the bar draw no Changes control for a worktree whose list is empty or not
  loaded.
- **The poller**, on a test clock: nothing polls while TBD is inactive;
  activation loads at once and then once per interval; a fresh list is not
  loaded; a list still being read is not loaded again; another worktree on
  screen loads at once; resigning active stops the polling. A load records
  whether its list is empty and counts as in flight while it reads git, and
  the poller follows the single selected worktree only.
- **The label rule** at its boundaries: labels at the width that fits them,
  icons one point narrower, and icons for every pill that is off.
- **The Changes pill's decision** for its own workspace tab: open, select, close.
- **Notes menu:** Open Other Note lists exactly the extra notes with no panel,
  and is absent when there are none.
- **Live:** the transcript pill's file menu keeps its submenus open, checked
  with NSMenu's item notifications as in the tabs-in-toolbar work.

## Risks

- **A worktree's extra notes without panels are reachable only from the Notes
  pill's menu.** That is one right-click deeper than the + menu put them.
- **The transcript's file menu moves under the button style.** The style reset
  on the menu's content is what keeps it stable; the live check guards it.

## Rejected alternatives

- **Pills that always toggle**, closing a panel that is behind another. A click
  would close something the user cannot see, and switching between open panels
  would need another control.
- **Transcript and Notes exclusive**, like a segmented control. Switching
  between them would close one each time, and the in-front state already shows
  which one is in view.
- **Every note behind the Notes pill**, the pill titled with the note in front
  and its menu listing all of them. It keeps several notes per worktree, which
  the problem above is about.
- **Merging extra notes into the first.** It rewrites user files once, for
  worktrees whose extras the user can delete in a click.
- **Labels always shown**, with the strip's minimum width grown to about
  385 pt to fit three. It narrows every terminal beside a side region.
- **A label only on the pill in front.** It hides which other panels are on.
- **Changes always shown.** For a worktree with nothing changed, it is a pill
  that opens an empty list.
- **Polling every mounted worktree's Changes list.** The window keeps several
  worktrees mounted, and each poll runs git; only the one on screen draws a
  Changes control.
