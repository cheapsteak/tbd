# Side panel toggle pills

The side region's Changes, transcript and Notes are each reached by one
button at the window's right edge. The transcript and Notes buttons are pills
that always read their panel's name, Changes is an icon, and the one whose
panel is in front is filled. An open panel gets no tab of its own. The Changes
button shows only while the worktree has changes or its panel is open. A
worktree has one note.

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
  from one pill.
- Each pill keeps one size in every state and at every strip width.
- No Changes control for a worktree with nothing to show in it.
- One note per worktree.
- No + menu in the strip.
- No pill is ever clipped: the side region is never narrower than its strip's
  controls with both labels shown.

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

The drag gap fills the width between the last tab and the trailing group, so
a strip whose only open panels have pills is history buttons, drag gap, and
the trailing group.

## Pills

Each pill has three states: off; on, in front; and on, behind another panel or
with the region collapsed. In all of them, hovered or not, its icon and any
label draw in the grey of the left sidebar's row icons,
`NSColor.secondaryLabelColor` (`SidePanelPillMetrics.foregroundColor`). The
pill names that colour concretely, so the strip matches the sidebar exactly;
the row style's hierarchical secondary can resolve to a different grey.

A pill's shape belongs to its kind, and neither its state nor the strip's width
changes it (`TabRowEdgeItem.pillLabel`, `SidePanelPillButton.size(for:)`):

- **Changes** – its icon alone, in the 28 × 28 hover square every row icon
  button draws (`RowIconButtonStyle`), in every state.
- **Transcript** – its icon and the label "Transcript", in every state.
- **Notes** – its icon and the label "Notes", in every state, whatever the
  note's title.

A labelled pill's icon sits where the square would centre it, and the label
follows, so the pill is `SidePanelPillMetrics.labelledWidth` wide, in whole
points.

Only the fill shows which panel is in front. The pill in front is filled as the
selected tab is, in its own shape: the square for Changes, the pill for the
transcript and Notes. A pill that is off and one that is behind draw alike: a
transcript or Notes pill shows its label with no fill, and Changes its icon
with no fill. So only the pill in front is marked.

Each pill draws one icon in every state, never a filled one:

- **Changes** – `plusminus`, the Changes tab's symbol
  (`PanelKind.changesSystemImage`).
- **Transcript** – `bubble`, empty whether its panel is open or not.
- **Notes** – `pencil.line`, the symbol a note's tab shows too
  (`PanelKind.noteSystemImage`). SF Symbols has had it since macOS 13, so it
  draws on every macOS the app runs on.

Each pill's hover and pressed square is the row's, sized to the pill's width,
so the feedback covers the shape the pill draws.

**Width.** The side region is never narrower than its strip's fixed controls
(`SideStripMetrics.fixedControlsWidth`): the history buttons; a full trailing
group of the active panel's control, the Changes square, the transcript and
Notes pills at their labelled widths, and collapse; and the strip's trailing
inset. The tabs between them scroll, so they give up their room first, and no
pill is ever clipped. The width comes from the labels measured in the 11 pt
system font, in whole points: on macOS 27 the transcript pill is 87 pt, the
Notes pill 64 pt, and the minimum 335 pt. It counts the transcript pill and the
Changes pill even where they are not drawn, so it stays put as they come and
go; a pill that is not drawn only leaves the tabs more room. The divider's
smallest share is that width's share of the space
(`PanelSurfaceWorkspaceView.minimumSideShare`).

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
expand button. The Changes button shows by the Changes pill's rule. They draw
as plain icons, with the pills' symbols and in the pills' grey,
`NSColor.secondaryLabelColor`, whatever their panel's state, so the bar and
the strip match. A disabled one draws that grey dimmed,
as the row style dims a disabled button. No panel is in view, so none shows a
fill or an accent colour, either of which would read as a panel showing, and
none carries a label: they are icon buttons like the rest of the bar's
trailing end. A click follows the pill's rule ("Clicks"), so it expands the
region.

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
- **Icons:** `plusminus` for Changes in the pill, the tab and the bar; an
  empty `bubble` for the transcript, on and off, in the pill and the bar;
  `pencil.line` for Notes and a note's tab, which the system draws.
- **Colour:** the pills' grey is `NSColor.secondaryLabelColor`, the tint of the
  sidebar's row icons, and the bar's three icons name the same colour in every
  state, enabled or disabled.
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
- **Labels:** the transcript and Notes pills show theirs off, behind and in
  front, enabled or not, and Changes shows none in any state. A pill's size is
  its labelled width for the transcript and Notes and the row's square for
  Changes, in every state.
- **The minimum width:** the fullest strip's fixed controls, with the pills at
  the sizes they draw and the tabs given no room, take exactly
  `SideStripMetrics.fixedControlsWidth`, a whole number of points; the
  divider's smallest share is that width's share of the space, held to the
  model's range.
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
- **A pill behind reads as off.** Only the fill marks a pill's state, and it
  marks the one in front. A click on either brings its panel to the front, so mistaking
  one for the other loses nothing.
- **The side region is never narrower than 335 pt** on macOS 27, the width its
  controls need with both labels shown, so a terminal beside an open side
  region always gives up at least that much.

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
- **Labels that drop when the strip is narrow.** A label that comes and goes
  with the strip's width moves the controls around it as the divider is
  dragged. A fixed label keeps each control in one place, and the region's
  minimum width holds it.
- **A label on the Changes pill too.** It would add about 52 pt to the side
  region's minimum width, to about 387 pt, which every terminal beside a side
  region gives up at the region's narrowest.
- **A label only on the pill in front.** The label would come and go as
  panels move to the front, moving the controls around it.
- **The label colour for a pill that is on.** It tells a pill behind from one
  that is off, but draws the pills darker than the row's other icons and the
  sidebar's, which are grey.
- **A filled bubble while the transcript is open.** The fill already marks
  the pill in front, and no other pill changes its symbol with its state.
- **Changes always shown.** For a worktree with nothing changed, it is a pill
  that opens an empty list.
- **Polling every mounted worktree's Changes list.** The window keeps several
  worktrees mounted, and each poll runs git; only the one on screen draws a
  Changes control.
