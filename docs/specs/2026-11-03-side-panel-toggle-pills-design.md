# Side panel toggle pills

The side region's Changes, transcript and Notes are each reached by one
button at the window's right edge. While one is open, that button draws as a
labelled pill, and the panel gets no tab of its own. A worktree has one note.

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
4. **The pills:** Changes, transcript, Notes. The transcript pill is drawn only
   where the transcript button is today (a Claude terminal, with the
   transcript view on).
5. **Collapse.**

With Tabs in the toolbar on, the drag gap fills the width between the last
tab and the trailing group, as before, so a strip whose only open panels have
pills is history buttons, drag gap, and the trailing group.

## Pills

Each pill has three states:

- **Off:** its icon alone, in the 28 × 28 hover square every row icon button
  draws (`RowIconButtonStyle`).
- **On, in front:** icon and label, filled as the selected tab is.
- **On, behind** another panel, or with the region collapsed: icon and label,
  with an outline and no fill.

Labels: "Changes", "Transcript", "Notes". The Notes pill reads "Notes" whatever
the note's title.

**When the strip is narrow,** the pills that are on keep their outline and fill
and drop their labels, so on, off, in front and behind still read. The tabs
give up their room first. One pure function of the strip's width and the
pills' states decides whether the labels show, so it can be tested without a
view. The pills' icon-only widths equal the buttons they replace (Changes takes
the + menu's slot), so `SideStripMetrics.fixedControlsWidth` stays 240 pt.

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
expand button. They draw as icons, tinted while their panel is open, as the
transcript and Notes buttons do today: no panel is in view, so none shows a
label. A click follows the rule above, so it expands the region.

## Rollout

This ships without a setting. It moves items users rely on: the transcript and
note tabs leave the strip, and the + menu goes. The repo's rule asks for a
default-off setting for such changes, and the project's owner chose to ship it
directly. Going back is a revert; no state changes, so a revert restores the
old strip with every panel and note intact.

## Testing

- **`SideRegionStrip.tabs`** leaves out the transcript panel, the first note's
  panel and the Changes panel, and keeps files, web pages and extra notes.
- **Trailing items:** the order (active panel control, Changes, transcript,
  Notes, collapse) with and without an active panel control and a transcript
  pill; no + menu.
- **Pill state:** off, in front, and behind, for each pill, including a
  collapsed region reading as behind.
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
