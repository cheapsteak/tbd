# Tabs in the toolbar — each pane's tab strip in the window's top row

Status: design, approved for implementation planning
Date: 2026-11-02
Pairs with: the AppKit window chrome ([`2026-11-01-appkit-window-chrome-design.md`](2026-11-01-appkit-window-chrome-design.md))

Each pane's tab strip draws in the main window's toolbar row. The worktree's
title sits in the same row, on one line after the notes button and the project
name, as the toolbar sets it on pages without a tab bar. The terminal and the
side panel start directly under the toolbar, and the Servers control sits in
the status bar.

## Problem

A window whose tab strips sit in a row of their own under the toolbar spends
two rows on chrome before its content starts:

- **The toolbar row** holds the window buttons, the sidebar's controls and,
  over the main area, the title cluster: the repo notes button, the project
  name and the worktree title. The rest of that row is empty.
- **The tab row** sits under it, 30 pt tall: the session tabs over the main
  pane, and the side panel's strip over the side panel.

Measured on the owner's window with that layout, the terminal started 82 pt
below the window's top edge: a 52 pt toolbar, then the 30 pt tab row. Most of
the toolbar row over the main area carried nothing.

## Goals

- Each pane's tab strip sits in the toolbar row, so both panes' content starts
  directly under it.
- The title cluster keeps the notes button with its popover, and the project
  name and the worktree title with their menus, at full length when there is
  room, and reads the same as the toolbar's title on every other page.
- A worktree keeps any number of session tabs; none is hidden while the title
  can still give up room.
- The window can still be dragged and double-clicked by its top row.

## Non-goals

- **Changing what any tab, button or menu does.** Only where they sit is
  decided here.
- **Pages without a worktree tab bar.** Repo pages, remote sessions, the
  multi-select grid and the empty state keep the toolbar's title.
- **User toolbar customization**, as in the window chrome spec.

## Who draws the row

The toolbar keeps its items over the sidebar and gives up the main area to the
panes:

- **Toolbar items:** the leading buttons, the repo filter while the sidebar is
  shown, and the tracking separator, as the window chrome spec lays them out.
  While the detail area shows a worktree's tab bar, nothing follows the
  separator: no title cluster, no flexible space. On every other page the
  title cluster follows it. The toolbar has no Servers item; the status bar
  holds it (see "Servers in the status bar").
- **The state:** `MainToolbarLayoutState.panesDrawTopRow` is true while the
  detail area shows a worktree's tab bar. The detail area's own choice of
  `SingleWorktreeView` and the toolbar's input come from one function
  (`MainDetailContent`), so they cannot disagree.
- **Why nothing may follow the separator:** a click under the unified toolbar
  reaches the content view only where no toolbar item sits. Measured with a
  standalone AppKit window on macOS 27 (full-size content view, transparent
  title bar, unified toolbar): a hit test under the toolbar returned the
  content's view wherever no item covered the point, and the item's own viewer
  wherever one did, a flexible space's included.

The panes draw the row in their own content, which reaches under the title
bar (`ContentView` lets the split ignore the top safe area, and the detail
area's pager and the worktree's view ignore it while a worktree's tab bar
shows):

- **On the daemon path,** `PanelSurfaceWorkspaceView` draws the main row over
  the primary's column and the side panel's row over the side region.
- **On every other single-worktree path,** `SingleWorktreeView` draws the main
  row across the detail area.

## The row's height and alignment

- **Height:** the toolbar's height, read as the content pane's top safe-area
  inset, never a constant. The toolbar controller measures it in AppKit after
  each layout and publishes it on `AppState.windowChrome`
  (`WindowChromeState`), with the leading item's edge. The panes read both
  from `AppState`, because the detail area's nested hosting controllers
  (`DetailSectionHostPager`, `WorktreePager`) start from a fresh environment.
  The owner's toolbar measured 52 pt; the probe window's measured 66 pt, so
  the height depends on the toolbar's contents. Before the first measurement
  the row takes 30 pt (`TabRowMetrics.height`), so it never lays out with no
  height.
- **Centre line:** every label, tab and button centres on the row's midline,
  the line the window buttons centre on.
- **Rule:** a divider runs under the row, between it and the panes' content.

## The main row

Left to right:

1. **Leading inset.** While the sidebar is collapsed, the toolbar's leading
   item (window buttons, sidebar toggle, back and forward) still sits over the
   main pane's top-left corner. The toolbar controller reports that item's
   trailing edge in window coordinates; the row starts 8 pt past it. While the
   sidebar is shown, the edge lies left of the pane and the row starts 16 pt in.
   Both rows, this one and the side region's strip, end 12 pt short of their
   trailing edge, so the last icon button's hover square clears the window's
   edge; the row's background still reaches the edge.
2. **Title cluster.** One line, set as the toolbar's title item sets it on
   every page without a tab bar (`WorktreeTitleView`), centred on the midline.
   Left to right: the notes button, the project name in 11 pt in the secondary
   colour, and the worktree title in 14 pt semibold, 6 pt apart. The row's
   column (`WorktreeTitleColumn`) and the toolbar's title item read those sizes
   from the same constants (`WorktreeTitleMetrics`), so the two cannot drift.
   The notes button draws its symbol in the secondary colour at 13 pt, the size
   the toolbar's button takes from its hosting view's default font. Its hit
   area reaches a little past the symbol, and it keeps its popover. It names
   itself on hover with a help tag rather than the toolbar's hover label, which
   draws under the button, where the pane would cut it off. Each text keeps its
   menu. A worktree with no project (a scratch space) shows the notes button,
   then the title.
3. **Session tabs**, then the + button 4 pt after the last tab
   (`TabsThenAddLayout`), so its hover square clears the pill, in the pill
   style below.
4. **Drag gap,** at least 24 pt, taking all spare width (see "Dragging the
   window").
5. **Session History,** and while the side region is hidden, the transcript,
   Notes and expand buttons.

**When the row runs short,** the title gives way before the tabs:

- With room for everything, the cluster and the tabs take their ideal widths.
- Short of room, the title column shrinks first, down to a floor of 110 pt.
  Within it the project name gives way first, truncating at its end, and then
  the title, truncating in the middle; the notes button keeps its size.
  Hovering the title shows it in full, and the sidebar's selected row shows it
  too.
- Only once the title is at its floor do the tabs scroll.

One pure function decides the two widths from the cluster's ideal width, its
floor, the tabs' ideal width, the fixed items' width and the width available,
so the rule is tested as values.

## Tabs in pills

Both rows draw their tabs the same way:

- **Active tab:** a rounded rectangle 28 pt tall, corner radius 7 pt, filled
  with the primary colour at 7.5% opacity. No line under it.
- **Hover:** the same shape at 4.5%.
- **Spacing:** 2 pt between tabs.
- A pill keeps the tab's label, glyph, close button, drag to reorder, context
  menu and hover card.

## The side panel's row

The side region's strip draws at the row's height with pill tabs: search, back
and forward, its tabs, the active panel's control, then the Changes, transcript
and Notes pills and collapse (see
[`2026-11-03-side-panel-toggle-pills-design.md`](2026-11-03-side-panel-toggle-pills-design.md)). It starts at the split divider and follows it
while the divider is dragged, because it is part of the side region. The
divider runs up to the window's top edge.

## Dragging the window

The row's empty space must still move the window:

- **The drag gap** in the main row, and the empty width in the side panel's
  row, are an AppKit view whose `mouseDownCanMoveWindow` is true, so the
  window's own title-bar handling drags it and answers a double-click with the
  action System Settings names (zoom, fill, minimize or nothing).
- **Tabs stay tabs.** A drag that starts on a tab reorders tabs and never moves
  the window: no view in the rows but the gap's answers
  `mouseDownCanMoveWindow`.

## Servers in the status bar

The Servers control sits in the status bar, at the start of the bar's
right-hand group, before the open-in-editor buttons:

- **Shown** under `AppState.showsServersButton`: while the selected worktree
  has any servers, declared or running.
- **Running:** a capsule filled with the system green at 15%, holding a 6 pt
  green dot and "2 running" in green, medium weight, at the bar's font size.
  It does not animate: the bar stays on screen for hours, and a pulse there
  would pull the eye from the terminal.
- **Nothing running:** the `server.rack` glyph and "Servers" in the secondary
  colour, with no capsule.
- **Click:** opens the menu `ServersToolbarMenu` builds, upward: its bottom
  edge on the chip's top edge, leading edges aligned. The position is a pure
  function of the chip's frame and the menu's height, so it is tested as
  values.
- **Accessibility:** the label comes from `ServersButtonLabel`.

The chip covers every page: it follows the one selected worktree
(`ServersMenu.selectedWorktreeID(in:)`), whatever the detail area shows, and
the status bar runs under the content pane on every page.

## Pages without a worktree tab bar

Repo pages, a remote session, the Provider Desk, the multi-select grid and the
empty state draw no tab bar, so the toolbar keeps its title cluster for them,
inline, and their content starts under the toolbar. A remote session's
Transcript, Reconnect and Stop stay in the toolbar, after the title and a
flexible space.

## Testing

- **Toolbar items, as values:** with a worktree tab bar showing, the list ends
  at the tracking separator, with the sidebar shown and collapsed. On any
  other page, the title cluster follows the separator, and a remote session's
  buttons follow the title and the flexible space. No list holds a Servers
  item.
- **Clicks reach the row:** in a window hosted offscreen, a hit test at a
  tab's centre returns a view inside the pane's hosting view, not a toolbar
  viewer. With the sidebar collapsed, a hit test on back returns the toolbar's
  button.
- **The shared choice:** the toolbar's `panesDrawTopRow` and the detail area's
  choice of `SingleWorktreeView` agree for every kind of selection.
- **Row height:** the row's height equals the hosted pane's top safe-area
  inset.
- **Title cluster:** one line with or without a project: a project leaves the
  column as tall as a scratch space's and widens it by the project name and one
  spacing. The row's column and the toolbar's title item are the same size,
  with a project and without, and the row's notes button is the toolbar's
  size.
- **Overflow, as values:** everything fits; the title shrinks and the tabs
  keep their width; the title at its floor and the tabs scrolling; a title
  already narrower than the floor never grows.
- **Servers chip:** hidden with no servers, muted with none running, green with
  a count; drawn only for a worktree with servers; the menu's position puts
  its bottom on the chip's top.
- **Live,** on the owner's machine: the rows with the sidebar shown and
  collapsed, the side panel shown and hidden, light and dark; dragging and
  double-clicking the window by each row's gap; reordering a tab by dragging;
  the notes popover and a tab's hover card; full screen; the Servers chip
  running and idle, and its menu opening upward.

## Risks

- **Full screen.** The toolbar hides in full screen and slides down over the
  content when the pointer reaches the top of the screen. Whether it covers the
  rows there, and what the top safe-area inset reads, is unmeasured.
- **Title-bar drag handling** may stop applying to a content view under the
  toolbar in some macOS release. The fallback is for the gap's view to call
  `NSWindow.performDrag(with:)` on mouse-down and map a double-click from the
  global `AppleActionOnDoubleClick` default itself, as a pure function with a
  test per value.
- **A tab drag might start a window drag** if any view under the tab reports
  `mouseDownCanMoveWindow`. Only the gap's view may.

## Rejected alternatives

- **A separate tab row under the toolbar, offered beside this one.** It costs
  both panes 30 pt of height for a toolbar row that stays mostly empty, and a
  second layout doubles what the toolbar, the panes and their tests must keep
  in step: which items follow the separator, the rows' heights and the tabs'
  drawing.
- **Both strips in one toolbar item.** The side panel's row must follow the
  SwiftUI split divider, including a drag in progress, which lives in the
  workspace view's state; a toolbar item lays out in a separate view tree with
  insets AppKit chooses. Keeping the two aligned across that boundary would be
  fragile.
- **No `NSToolbar`, a hand-drawn title bar.** It undoes the window chrome
  spec's toolbar and leaves the window buttons' placement to TBD.
- **Only the main strip in the toolbar row.** The two strips share one row;
  putting only one there would leave the side panel's content 30 pt lower than
  the terminal's.
- **The title over the project name,** the way macOS sets a window's subtitle
  under its title. At the owner's window size the toolbar's one-line cluster
  took about 280 pt of a 516 pt main pane, and setting the project under the
  title frees the project name's width, about 65 pt, most of a tab. But the
  title then reads differently in the row than in the toolbar's title item,
  which every page without a tab bar shows, and changes shape whenever the
  selection moves from one to the other. The title floor, and the project name
  giving way before the title, bound what one line costs the tabs.
- **The tabs scroll and the title stays whole.** A tab scrolled out of view
  shows nowhere else, while the title also shows in the sidebar's selected row.
- **A 2 pt line under the active tab, or an active tab that opens into its
  pane.** The line needs a rule under the row to read against, and an open
  tab takes its pane's colour, which differs between the terminal and the side
  panel. A pill reads the same in both rows.
- **Servers at the window's right edge.** The side panel's row holds that
  corner.

## Parity

The native sidebar spec's parity checklist carries the chrome's items; the
toolbar items and the status bar chip here walk it.

No durable resource is added.
