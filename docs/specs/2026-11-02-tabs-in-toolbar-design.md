# Tabs in the toolbar — each pane's tab strip in the window's top row

Status: design, approved for implementation planning
Date: 2026-11-02
Pairs with: the AppKit window chrome ([`2026-11-01-appkit-window-chrome-design.md`](2026-11-01-appkit-window-chrome-design.md))

This spec moves each pane's tab strip up into the main window's toolbar row,
behind a setting that is off by default. The worktree's title moves into the
same row, set over its project name. The terminal and the side panel then start
at the top of the window, and the Servers button moves to the status bar.

## Problem

A worktree's window spends two rows on chrome before its content starts:

- **The toolbar row** holds the window buttons, the sidebar's controls and,
  over the main area, the title cluster: the worktree title, the project
  name and the repo notes button after it. The rest of that row is empty.
- **The tab row** sits under it, 30 pt tall: the session tabs over the main
  pane, and the side panel's strip over the side panel.

Measured on the owner's window, the terminal starts 82 pt below the window's
top edge: a 52 pt toolbar, then the 30 pt tab row. Most of the toolbar row over
the main area carries nothing.

## Goals

- Each pane's tab strip sits in the toolbar row, so both panes' content starts
  directly under it, 30 pt sooner.
- The title cluster keeps the worktree title and the project name, each with
  its menu, at full length when there is room, and the notes button after the
  project name, with its popover.
- A worktree keeps any number of session tabs; none is hidden while the title
  can still give up room.
- The window can still be dragged and double-clicked by its top row.
- With the setting off, the window is exactly as it is today.

## Non-goals

- **Changing what any tab, button or menu does.** Only where they sit changes.
- **Pages without a worktree tab bar.** Repo pages, remote sessions, the
  multi-select grid and the empty state keep today's toolbar title.
- **User toolbar customization**, as in the window chrome spec.

## The setting

- **Key:** `window.tabsInToolbar` in `AppState.userDefaults`, named by
  `AppState.tabsInToolbarKey`, with its default in one place,
  `AppState.tabsInToolbarDefault`, `false`.
- **Toggle:** Settings → General → Experimental, "Tabs in the toolbar", whose
  help text says the tabs and title move into the window's top row and the
  Servers button moves to the status bar.
- **Readers:** the panes read it from `AppState.windowChrome`
  (`WindowChromeState.tabsInToolbar`), which follows the key in
  `AppState.userDefaults` through that store's change notification, and the
  Settings toggle writes it there. `@AppStorage` would not serve: the detail
  area's nested hosting controllers (`DetailSectionHostPager`,
  `WorktreePager`) do not carry the store `MainWindowSplitView` passes its
  panes, and the key's dot reads as a key path separator to the key-value
  observation `@AppStorage` relies on. The toolbar controller already
  watches its defaults store for the Show Hidden Repos key (the window chrome
  spec, "The repo filter"); a change to this key queues the same compare-first
  apply, and other keys queue nothing.
- **Graduation:** the owner soaks it. Once the live checks below pass and a
  week of use shows no regressions, `tabsInToolbarDefault` flips to `true`.
  The setting, and the drawing it switches off, are deleted in a later
  release, when the window chrome spec absorbs this one.

Everything below describes the window with the setting on.

## Who draws the row

The toolbar keeps its items over the sidebar and gives up the main area to the
panes:

- **Toolbar items:** the leading buttons, the repo filter while the sidebar is
  shown, and the tracking separator, as today. While the detail area shows a
  worktree's tab bar, nothing follows the separator: no title cluster, no
  flexible space, no Servers. On every other page the title cluster follows it,
  as today. The Servers item never appears; it lives in the status bar (see
  "Servers in the status bar").
- **The state:** `MainToolbarLayoutState` gains `panesDrawTopRow`, true when the
  setting is on and the detail area shows a worktree's tab bar. The detail
  area's own choice of `SingleWorktreeView` and the toolbar's input come from
  one function, so they cannot disagree.
- **Why nothing may follow the separator:** a click under the unified toolbar
  reaches the content view only where no toolbar item sits. Measured with a
  standalone AppKit window on macOS 27 (full-size content view, transparent
  title bar, unified toolbar): a hit test under the toolbar returned the
  content's view wherever no item covered the point, and the item's own viewer
  wherever one did, a flexible space's included.

The panes draw the row in their own content, which already reaches under the
title bar (`ContentView` lets the split ignore the top safe area):

- **On the daemon path,** `PanelSurfaceWorkspaceView` draws the main row over
  the primary's column and the side panel's row over the side region, as it
  draws the 30 pt row today.
- **On every other single-worktree path,** `SingleWorktreeView` draws the main
  row across the detail area, as it draws its full-width tab bar today.

## The row's height and alignment

- **Height:** the toolbar's height, read as the content pane's top safe-area
  inset, never a constant. The toolbar controller measures it in AppKit after
  each layout and publishes it on `AppState.windowChrome`, with the leading
  item's edge. The owner's toolbar measured 52 pt; the probe window's
  measured 66 pt, so the height depends on the toolbar's contents.
- **Centre line:** every label, tab and button centres on the row's midline,
  the line the window buttons centre on.
- **Rule:** the existing divider under the tab row stays, now under the
  toolbar row.

## The main row

Left to right:

1. **Leading inset.** While the sidebar is collapsed, the toolbar's leading
   item (window buttons, sidebar toggle, back and forward) still sits over the
   main pane's top-left corner. The toolbar controller reports that item's
   trailing edge in window coordinates; the row starts 8 pt past it. While the
   sidebar is shown, the edge lies left of the pane and the row starts 16 pt in.
   Every tab row (this one, the classic row and the side region's strip) ends
   12 pt short of its trailing edge, so the last icon button's hover square
   clears the window's edge; the row's background still reaches the edge.
2. **Title cluster.** A column of two lines: the worktree title in 13 pt
   semibold, and under it the project name in 11 pt, secondary colour, the way
   macOS sets a window's subtitle under its title. The notes button follows the
   bottom line's text, 4 pt after the project name, its symbol drawn at the line's
   11 pt in the same secondary colour, so the line is no taller than its text.
   Its hit area reaches a little past the symbol, it names itself on hover with
   a help tag, and it keeps its popover. Each line keeps its menu. A worktree
   with no project (a scratch space) shows the title alone, centred on the
   midline, with the notes button following that line at the title's 13 pt.
3. **Session tabs**, then the + button 4 pt after the last tab
   (`TabsThenAddLayout`), so its hover square clears the pill, in the pill
   style below.
4. **Drag gap,** at least 24 pt, taking all spare width (see "Dragging the
   window").
5. **Session History,** and while the side region is hidden, the transcript,
   Notes and expand buttons, as the tab bar's trailing items today.

**When the row runs short,** the title gives way before the tabs:

- With room for everything, the cluster and the tabs take their ideal widths.
- Short of room, the title column shrinks first, down to a floor of 110 pt.
  Both lines truncate at the column's width, the title in the middle and the
  project name at the end; the notes button keeps its size. Hovering the
  title shows it in full, and the sidebar's selected row shows it too.
- Only once the title is at its floor do the tabs scroll, as they do today.

One pure function decides the two widths from the cluster's ideal width, its
floor, the tabs' ideal width, the fixed items' width and the width available,
so the rule is tested as values.

## Tabs in pills

Both rows draw their tabs the same way:

- **Active tab:** a rounded rectangle 28 pt tall, corner radius 7 pt, filled
  with the primary colour at 7.5% opacity. No 2 pt line under it.
- **Hover:** the same shape at 4.5%.
- **Spacing:** 2 pt between tabs.
- Labels, glyphs, close buttons, drag to reorder, context menus and hover cards
  are unchanged.

## The side panel's row

The side region's strip draws at the row's height with pill tabs: search, back
and forward, its tabs, then its + menu, the active panel's control, transcript,
Notes and collapse, as today. It starts at the split divider and follows it
while the divider is dragged, because it is part of the side region. The
divider runs up to the window's top edge.

## Dragging the window

The row's empty space must still move the window:

- **The drag gap** in the main row, and the empty width in the side panel's
  row, are an AppKit view whose `mouseDownCanMoveWindow` is true, so the
  window's own title-bar handling drags it and answers a double-click with the
  action System Settings names (zoom, fill, minimize or nothing).
- **The live check confirms it.** If AppKit does not apply its title-bar
  handling to a content view under the toolbar, the view calls
  `NSWindow.performDrag(with:)` on mouse-down and maps a double-click from the
  global `AppleActionOnDoubleClick` default itself; that mapping is then a pure
  function with a test per value.
- **Tabs stay tabs.** A drag that starts on a tab reorders tabs and never moves
  the window. The live check covers it.

## Servers in the status bar

The Servers button leaves the toolbar for the status bar, at the start of the
bar's right-hand group, before the open-in-editor buttons:

- **Shown** under today's rule, `AppState.showsServersButton`: while the
  selected worktree has any servers, declared or running.
- **Running:** a capsule filled with the system green at 15%, holding a 6 pt
  green dot and "2 running" in green, medium weight, at the bar's font size.
  It does not animate: the bar stays on screen for hours, and a pulse there
  would pull the eye from the terminal.
- **Nothing running:** the `server.rack` glyph and "Servers" in the secondary
  colour, with no capsule.
- **Click:** opens the menu `ServersToolbarMenu` builds today, with the same
  items, upward: its bottom edge on the chip's top edge, leading edges aligned.
  The position is a pure function of the chip's frame and the menu's height,
  so it is tested as values.
- **Accessibility:** the label comes from `ServersButtonLabel`, as the toolbar
  item's does.

## Pages without a worktree tab bar

Repo pages, a remote session, the Provider Desk, the multi-select grid and the
empty state draw no tab bar, so the toolbar keeps its title cluster for them,
inline as today, and their content starts under the toolbar. A remote
session's Transcript, Reconnect and Stop stay in the toolbar.

## Testing

Each gated behaviour is tested with the setting on and off.

- **Toolbar items, as values:** with the setting off, every state gives
  today's list. With it on and a worktree tab bar showing, the list ends at the
  tracking separator, with the sidebar shown and collapsed. With it on and any
  other page, the title cluster follows the separator. With it on, no state
  lists Servers. The remote session items are the same either way.
- **The defaults watch:** a change to `window.tabsInToolbar` queues an apply
  while the toolbar is installed; other keys queue nothing.
- **Clicks reach the row:** in a window hosted offscreen with the setting on, a
  hit test at a tab's centre returns a view inside the pane's hosting view, not
  a toolbar viewer. With the sidebar collapsed, a hit test on back returns the
  toolbar's button.
- **The shared choice:** the toolbar's `panesDrawTopRow` and the detail area's
  choice of `SingleWorktreeView` agree for every kind of selection.
- **Row height:** the row's height equals the hosted pane's top safe-area
  inset.
- **Title cluster:** a worktree with a project shows two lines, the notes
  button following the project's; a scratch space shows the title alone, the
  notes button following it.
- **Overflow, as values:** everything fits; the title shrinks and the tabs
  keep their width; the title at its floor and the tabs scrolling; a title
  already narrower than the floor never grows.
- **Servers chip:** hidden with no servers, muted with none running, green with
  a count; the menu's position puts its bottom on the chip's top. With the
  setting off, the status bar shows no Servers chip and the toolbar's Servers
  item is unchanged.
- **Live, before merge,** on the owner's machine, with the setting on: the
  rows with the sidebar shown and collapsed, the side panel shown and hidden,
  light and dark; dragging and double-clicking the window by each row's gap;
  reordering a tab by dragging; the notes popover and a tab's hover card; full
  screen; the Servers chip running and idle, and its menu opening upward. With
  the setting off: the window unchanged.

## Risks

- **Full screen.** The toolbar hides in full screen and slides down over the
  content when the pointer reaches the top of the screen. Whether it covers the
  rows there, and what the top safe-area inset reads, is unmeasured; the live
  check finds out before the default flips.
- **Title-bar drag handling** may not apply to a content view under the
  toolbar; "Dragging the window" names the fallback.
- **A tab drag might start a window drag** if any view under the tab reports
  `mouseDownCanMoveWindow`. Only the gap's view may.

## Rejected alternatives

- **Both strips in one toolbar item.** The side panel's row must follow the
  SwiftUI split divider, including a drag in progress, which lives in the
  workspace view's state; a toolbar item lays out in a separate view tree with
  insets AppKit chooses. Keeping the two aligned across that boundary would be
  fragile.
- **No `NSToolbar`, a hand-drawn title bar.** It undoes the window chrome
  spec's toolbar and leaves the window buttons' placement to TBD.
- **Only the main strip moves up.** The two strips share one row today; moving
  one would leave the side panel's content 30 pt lower than the terminal's.
- **The title on one line, before the tabs.** At the owner's window size the
  inline cluster took about 280 pt of a 516 pt main pane, and one tab fit
  before the strip scrolled. Setting the project under the title frees the
  project name's width, about 65 pt, most of a tab.
- **The tabs scroll and the title stays whole.** A tab scrolled out of view
  shows nowhere else, while the title also shows in the sidebar's selected row.
- **Today's 2 pt line under the active tab, or an active tab that opens into
  its pane.** The line needs a rule under the row to read against, and an open
  tab takes its pane's colour, which differs between the terminal and the side
  panel. A pill reads the same in both rows.
- **Servers at the window's right edge.** The side panel's row now holds that
  corner.

## Parity

The native sidebar spec's parity checklist carries the chrome's items; the
toolbar items and the status bar chip here walk it.

No durable resource is added.
