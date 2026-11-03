# AppKit window chrome — the sidebar toggle and history beside the window buttons

Status: design, approved for implementation planning
Date: 2026-11-01
Pairs with: the native sidebar ([`2026-10-31-native-sidebar-design.md`](2026-10-31-native-sidebar-design.md))

This spec puts the main window's split and toolbar on AppKit, around the native
sidebar. The sidebar toggle and back/forward sit beside the window buttons, the
repo filter sits over the list it filters, and the worktree title aligns left.

## Problem

A SwiftUI `NavigationSplitView` window with SwiftUI `.toolbar` items places
them where they do not belong:

- **Back/forward sit in a Liquid Glass capsule after the sidebar's edge,** and
  the sidebar toggle draws in its own glass circle at the sidebar's trailing
  edge, though `.toolbar(removing: .sidebarToggle)` asks for none.
- **The toggle cannot do anything, because the sidebar must not collapse.**
  Waking from sleep once collapsed it with no way back (#119). The guard sets
  `canCollapse` and `canCollapseFromWindowResize` to false on SwiftUI's split
  controller, and SwiftUI resets both on every layout pass, so the guard has to
  re-apply them on a timer, every 5 seconds.
- **The title is centred** (`.principal`), away from the sidebar it belongs
  beside.
- **The repo filter sits at the toolbar's far right,** away from the list it
  filters.
- **A gray separator line runs under the sidebar's part of the titlebar,** though
  the window's own `titlebarSeparatorStyle` is `.none`.

SwiftUI cannot place these reliably. Whether toolbar items in the sidebar column
survive a collapse is undocumented; hiding an item's glass leaves extra padding
(Apple Developer Forums thread 816001); and `NavigationSplitView` owns the
window toolbar, so a custom `NSToolbar` cannot sit beside it. A SwiftUI toolbar
also needs workarounds for how SwiftUI lowers it onto AppKit: capsule fusing
rules, and `.id` rebuilds because AppKit materializes a split button's menu
once.

## Goals

- The sidebar toggle, back and forward, in that order, right after the window
  buttons, as plain icons with no capsule, in the same place whether the
  sidebar is shown or collapsed.
- The sidebar collapses and expands from the toggle, and waking from sleep
  still never collapses it.
- The repo filter at the right edge of the sidebar's part of the toolbar,
  hidden while the sidebar is collapsed: with no list on screen, a filter on it
  has nothing to act on.
- The title cluster (repo notepad, project name, worktree title) aligned left in
  the main area's part of the toolbar: just past the sidebar's edge when it is
  shown, right after the arrows when it is collapsed.
- No separator line under the sidebar's part of the toolbar.
- No PR button. A worktree often relates to several PRs, so a toolbar button
  for one PR misreads the worktree; the sidebar rows' PR glyphs and
  `tbd pr list` show them all.
- No file-panel toggle in the toolbar. The Changes panel's toggle is not a
  window toolbar item; ⌘⇧E is a menu command.

## Non-goals

- **Changing what the other toolbar items do.** The Servers split button and
  the remote session buttons keep the behavior their own specs give them.
- **User toolbar customization.**

## Window structure

`ContentView` hosts an `NSSplitViewController`, `MainSplitViewController`,
through an `NSViewControllerRepresentable`, `MainWindowSplitView`:

- **The sidebar item** is `NSSplitViewItem(sidebarWithViewController:)` hosting
  `SidebarView`, the native outline and dock with the footer beneath. Its
  minimum thickness fits every item in the sidebar's part of the toolbar (see
  "Width").
- **The content item** hosts `MainDetailArea`: the detail area,
  `DetailSectionHostPager`, with the status bar, `StatusBarView`, beneath it.
- **Collapse** is the split item's: `canCollapse` is true and
  `canCollapseFromWindowResize` false, the guard against #119. They are set once,
  because nothing resets them.
- **Both items' `titlebarSeparatorStyle` is `.none`.** The running app confirms
  that this is the line's source; if it is the scroll-edge effect instead, that
  effect is turned off for the sidebar's scroll view.

The banners sit above the split in `ContentView`, and the split reaches the
window's bottom edge:

- **The status bar** sits at the foot of the content pane, under the detail
  area only, so the sidebar column runs to the window's bottom edge beside it.
  While the sidebar is collapsed the content pane fills the window, and the
  status bar spans it.
- **The bottom bars line up.** The sidebar's footer and the status bar share
  one height, `WindowBottomBarMetrics.height` (32 pt), and each centres its
  content in it. Both sit on the window's bottom edge, so their tops and centre
  lines meet across the split between the sidebar column and the content
  pane. The status bar keeps that height whatever is selected.

## The toolbar

A `MainToolbarController` owns an `NSToolbar`, is its delegate, and installs it
on the main window when the split appears, with `toolbarStyle = .unified`.
Nothing in the window uses SwiftUI's `.toolbar`. Items, left to right:

1. **Leading buttons** – one item holding three compact buttons side by side
   (see "Compact buttons"): the sidebar toggle, whose action is the split
   controller's `toggleSidebar(_:)`, then back and forward, enabled from
   `AppState.canGoBack` and `canGoForward`. The item is not `isNavigational`,
   which would move it after the separator.
2. **Flexible space.**
3. **Repo filter** – an icon button the size of back and forward, whose click
   pops up a menu of "All Repos" and each repo with the current choice
   checked, then the Show Hidden Repos toggle (see "The repo filter"). It is
   the sidebar's only filter control. It is removed from the toolbar while the
   sidebar is collapsed and put back when it expands.
4. **Tracking separator** – an `NSTrackingSeparatorToolbarItem` that the
   toolbar creates under an identifier of its own, bound to the split's first
   divider and never changed afterwards. Everything before it sits over the
   sidebar, and stays beside the window buttons when the sidebar collapses.
   It is not the standard `.sidebarTrackingSeparator`, because AppKit's own
   item for that identifier finds a divider on its own, and re-binding it
   afterwards raises a KVO exception.
5. **Title cluster** – `ToolbarTitleCluster` in a hosting view, in a borderless
   item. Its width does not follow its text: the item fills the
   space between the tracking separator and the right-hand items, within a
   constant minimum and maximum, and the cluster sits at its leading edge. So
   the cluster starts just past the separator and stays put when back,
   forward or a new selection changes the title. A title wider than the item
   is cut at the item's trailing edge, and nothing else is cut: the notes
   button's hover label reaches past the cluster's leading and bottom edges.
6. **Flexible space.**
7. **The right-hand items:** the Servers split button and the remote session
   buttons (Reconnect, Stop with its confirmation, and
   Transcript, shown on the remote spec's terms). The Servers button is an
   `NSMenuToolbarItem` whose menu an `NSMenuDelegate` builds each time it
   opens, and whose image updates in place, so no item is rebuilt to refresh
   it.

There is no PR button and no file-panel toggle (see "Goals").

Which items are present and in what order is a pure function of a small state
value: whether the sidebar is collapsed, what is selected, the remote session's
state. The controller observes `AppState` with
`withObservationTracking` and applies a changed result on the next main-actor
turn, never during a SwiftUI update, which can re-enter layout. The one input
Observation cannot see, the repo filter's Show Hidden Repos key, reaches it
through a watch on `AppState.userDefaults` (see "The repo filter").

### Compact buttons

The toggle, back and forward match the leading buttons of a macOS 27 toolbar
whose window buttons, toggle and arrows sit 28 pt apart, centre to centre.

- **One item** – the three buttons share one view item. AppKit gives each
  separate unbordered view item a fixed 44 pt slot, centred on its view,
  whatever the view's width: measured in the running app, views 8, 20 and
  32 pt wide all sat about 44 pt apart, with glyph centres 114.5, 157.8 and
  203.0 pt from the window's leading edge. So three items can never sit 28 pt
  apart, and their wider slots push the repo filter into the overflow menu at
  the sidebar's minimum width. One item's view lays out its buttons itself.
- **View** – the item's view is a plain host view, 84 × 28 pt, held by
  required constraints. It holds three `ToolbarIconButton`s, borderless
  `NSButton`s, toggle, back and forward, each 28 pt wide by a required
  constraint. Required constraints chain them from the host's leading edge to
  its trailing edge, hold each button square (height equal to width) and
  centre it vertically in the host, which wins over each button's own
  intrinsic size. AppKit centres items vertically, which puts the
  glyphs on the window buttons' line.
- **Pitch** – 28 pt: each button is one pitch wide and the buttons touch, so
  none of AppKit's spacing between items falls between them.
- **Glyph** – `sidebar.left`, `chevron.left` and `chevron.right`, at 13 pt,
  regular weight and medium scale. The scale is named because a toolbar draws
  its buttons at large control size, which scales up a symbol whose
  configuration names none: measured in the running app, the toggle's ink
  drew 19.5 × 15 pt and each chevron's 8 × 14 pt, about 1.25 times too big.
  At medium scale they draw 15 × 12 pt and 6 × 11 pt, against the reference's
  16 × 13 pt and 6 × 11 pt. Back and forward draw grey while disabled.
- **Hover and hit area** – each button draws a rounded square, corner radius
  6 pt, the size of the button's shorter side, centred and aligned to whole
  device pixels so no blurred edge row makes it read taller than wide. Each
  button is square, so the square fills its 28 × 28 pt frame: the quaternary label colour while the
  pointer is over it, the label colour at 16 % opacity while it is pressed, and
  nothing at rest or while disabled. Both colours are semantic, so they follow
  the light and dark appearance. This matches the Claude desktop app's
  toolbar, whose icon buttons show a light grey square about 28 pt across
  behind the glyph on hover, darker while pressed. An accessory-bar button
  with `showsBorderOnlyWhileMouseInside` shows a hover highlight smaller than
  its frame, so the square is drawn by the button rather than by a bezel. The
  button is borderless, so its hit area is its frame, and the three frames
  tile the host, leaving no gap between them. The hover state comes from a
  tracking area over the button's visible rect and is cleared when the button
  moves to another window or is disabled.
- **No glass** – `NSToolbarItem` forwards `isBordered`, `isEnabled`, target,
  action and image to its view when the view answers them, so a bordered
  button as the item's view would make the item bordered, and a bordered item
  gets a Liquid Glass background. The host answers none of those, so the item
  keeps its own `isBordered = false`, set explicitly, and shows no glass, as
  the title item does; in the running app no capsule shows. The buttons one
  level down are borderless and draw their own hover square.
- **Wiring** – each button carries its own target, action and tool tip, and
  each row of the overflow form its own target and action; the item carries
  none. Back's and Forward's tool tips name their shortcuts ("Back (⌘[)"),
  taken from `MainWindowCommand` so they cannot drift from the menu bar,
  while their accessibility labels stay the bare titles. An item with a
  custom view keeps no target or action its view does
  not answer, so the item reads nil (measured on CI), and it forwards a tool
  tip to any view, where it would sit on the host under the buttons. The item
  stays enabled. Back and forward start disabled, button and row, and each
  apply sets each button and row from the snapshot only when it differs, so
  an apply that changes nothing sets nothing and a row that drifted comes back
  on the next one. The item does not autovalidate: `NSToolbarItem`'s
  `validate` does nothing for an item with a custom view, and the toggle stays
  enabled while back and forward follow the snapshot. The host is not an
  accessibility element, so VoiceOver lands on each button.
- **Copies** – the toolbar never shows a copy, because user customization is
  off (`allowsUserCustomization = false` in `MainToolbarController`). AppKit
  copies a view item by archiving its view and unarchiving the copy's, and
  the host decodes only so that a copy AppKit makes cannot crash: it keeps no
  stored property (its buttons are its subviews, found by their identifiers)
  and marks its constraints `shouldBeArchived`, so a copy keeps its size and
  its buttons' layout. A copied back or forward button keeps its action but
  not its target, since an archive keeps a target only when it archives the
  target too; no displayed item depends on that.

### The repo filter

The filter is an icon like back and forward rather than a menu showing the
repo's name, so a long name never widens the sidebar's part of the toolbar.

- **View** – a view item over a plain host, 28 × 28 pt, held by required
  constraints, holding one `ToolbarIconButton` that fills it. The host
  answers none of the properties an item forwards, so the item stays
  unbordered and shows no glass, as the leading item does; it decodes for
  AppKit's copy in the same way. AppKit gives the item its fixed 44 pt slot,
  centred on the host (see "Width").
- **Glyph** – `line.3.horizontal.decrease`, at the leading buttons' 13 pt,
  regular weight and medium scale, with the same hover square and hit area.
- **Colour** – the other icons' colour while no repo filter is set, and system
  blue while one is. A filter naming a repo that is gone still filters the
  sidebar, to no repo at all, so it stays blue. The Show Hidden Repos toggle
  does not colour it: showing hidden repos widens the sidebar rather than
  narrowing it.
- **Text** – the tool tip reads "Filter sidebar by repository" with no filter,
  "Filtering by" the repo's name with one, and "Filtering by a removed
  repository" when the repo is gone. The accessibility label is "Filter", and
  the value is "All Repos", the repo's name or "Removed repository", so
  VoiceOver reads the choice without opening the menu.
- **Menu** – a click pops up one menu the toolbar controller keeps, its top
  leading corner 4 pt below the button's bottom leading corner: "All Repos", a
  separator, then each repo, hidden ones included and unmarked, the current
  choice checked, or none when the filter names a repo that is gone; then a
  separator and the Show Hidden Repos toggle. Choosing a repo row sets
  `AppState.repoFilter`. Each apply keeps the menu in step: it rebuilds the
  rows only when the options change, sets a check, the toggle's title, the
  tint, the tool tip and the accessibility value only when they differ, and
  changes nothing while the menu or the overflow row's submenu is open, whose
  close schedules an apply that catches up.
- **Show Hidden Repos** – the menu's last row, titled "Show Hidden Repos",
  followed by the number of hidden repos in parentheses while there are any.
  It is checked while `SidebarBuildOptions.showHiddenReposKey` is on, and
  choosing it flips that key in `AppState.userDefaults`, the store the
  sidebar's outline reads and re-filters from. Observation does not track a
  defaults key, so the snapshot carries the toggle's state and the hidden
  count, and the controller watches that store's `didChangeNotification`: a
  change that leaves the key other than the last apply showed queues an
  apply, which updates the row.
- **Which repos the sidebar shows** – one rule,
  `AppState.sidebarShownRepos(showHiddenRepos:)`. A repo chosen in the filter
  shows alone, hidden or not, since choosing it asks to see it, and a hidden
  one draws dimmed as every hidden repo's section does. With no repo chosen,
  every repo shows, less the hidden ones unless Show Hidden Repos is on.

### The overflow menu

An item that does not fit goes to the toolbar's overflow menu (») as its menu
form. AppKit's default form for a view item is a row titled with the item's
label that sends the view's action from an `NSMenuItem`, and `NSToolbarItem.h`
promises a target and action on the default row only for standard items. So
every item but one has an explicit form:

- **Leading buttons** – "Navigation", with a submenu of "Toggle Sidebar",
  "Back" and "Forward", each acting as its button does. The submenu does not
  autoenable; back and forward are disabled, as their buttons are, when
  history has nowhere to go.
- **Repo filter** – "Filter", with a submenu of "All Repos" and each repo, the
  current choice checked, then the Show Hidden Repos toggle: the same rows as
  the button's menu and kept in step with it.
- **Title cluster** – an inert row showing the title, or "No Selection" when
  nothing is selected. It is never hidden: with nothing selected the title
  item still holds its minimum width, so it can be the only item that
  overflows, and a hidden row would leave the menu empty.
- **Remote session buttons** – a row titled with the button's label, carrying
  its action.

The Servers item keeps AppKit's documented default: its menu is its form.

The title's and the filter's rows are replaced, never edited, when what they
show changes, since AppKit may build the overflow menu from copies of them. A
title or filter item the toolbar makes, as when the filter returns after a
collapse, starts from what the last apply showed.

Every action the toolbar wires takes any sender and checks its class, so a row
sending it from an `NSMenuItem` never meets a method typed for another sender.

### Width

AppKit moves a toolbar item that does not fit its section into the overflow
menu, out of its place. So the sidebar's minimum thickness is the sidebar's
section at its narrowest, left to right:

- **Leading inset** – 92 pt from the window's edge to the first item, where
  AppKit places it after the window buttons in this toolbar, measured in the
  running app.
- **Leading buttons** – 84 pt: one item of three 28 pt buttons.
- **Spacing** – 2 × 8 pt: one after the leading item and one before the
  filter, as AppKit spaces both sides of the flexible space between them even
  when it is empty. AppKit does not publish its spacing between items, so
  8 pt is an estimate.
- **Filter** – 44 pt: the slot AppKit gives a separate unbordered view item,
  centred on its view whatever the view's width, measured in the running app.
  The filter's own view is 28 pt wide.
- **Margin** – 20 pt before the tracking separator.

That is 92 + 84 + 2 × 8 + 44 + 20 = 256 pt, below the 400 pt maximum. The
spacing is the one estimate in it: the running app confirms it, and the
thickness grows with it.

### Shortcuts

⌘[, ⌘] and ⌘⇧E are `.commands` menu items, not toolbar button shortcuts, so
each works whether its button is on the toolbar, in the overflow menu or not
in the toolbar at all.

## Parity

The native sidebar spec's parity checklist carries the chrome's items, and a
change to a toolbar item walks them.

No durable resource is added.

## Testing

- **The mounted window:** `ContentView` hosted offscreen builds the split
  controller, whose sidebar pane holds the native sidebar, and puts the AppKit
  toolbar on the window with no item it does not declare. A SwiftUI update of
  the hierarchy leaves that toolbar on the window, checked against a positive
  control in which a test-only root that declares a toolbar does get SwiftUI's
  toolbar bridged onto the same kind of window. The hosted panes read
  `@AppStorage` from the store the window's root gives them. The split reaches
  the window's bottom edge, and the content pane ends its detail area one
  bottom-bar height above the pane's own foot, the band the status bar fills.
- **Item order, as values:** the sidebar shown and collapsed, the filter present
  only while shown, the leading item first and before the separator in both;
  each conditional item against the state that shows it.
- **Collapse settings:** `canCollapse` true and `canCollapseFromWindowResize`
  false after setup and after a layout pass; both separator styles `.none`.
- **The leading buttons survive a collapse:** in a hosted window, the leading
  item is still a toolbar item, at its full width beside the window buttons,
  after the sidebar collapses and after it expands again.
- **Compact buttons:** one unbordered item that does not autovalidate, keeps
  no target or action and is enabled, whose host answers none of the
  selectors an item forwards and holds 84 × 28 pt by required constraints; its
  three buttons tile the host at 0, 28 and 56 pt, each a borderless
  `ToolbarIconButton`, 28 × 28 pt and each with its identifier, tool tip,
  accessibility label, target and action; the hover square's colour for every
  combination of hovered, pressed and enabled; each glyph's ink is within 2 pt
  of the reference; back and forward start
  disabled, button and row, follow the snapshot, and an apply brings back a
  row that drifted; a copy keeps the host, its three buttons with their glyphs
  and actions, and its size; the sidebar's minimum thickness is the "Width"
  formula. The glyph test measures the image drawn on its own, outside any
  control, so it cannot see the control size; the live check does.
- **Repo filter:** one unbordered item that does not autovalidate and keeps no
  target, action or tool tip, whose host answers none of the forwarded
  selectors and holds 28 × 28 pt, filled by one borderless
  `ToolbarIconButton` showing the filter glyph at the leading buttons'
  configuration; a copy keeps the host, its button, its glyph and action, and
  its size; the button's menu, read through the accessor its click pops up,
  since a test cannot pop a menu up, mirrors the options with the current one
  checked, or none for a repo that is gone, changes a check only when it
  differs, and sets the filter when a row is chosen; the Show Hidden Repos
  row carries the hidden count only when there is one, taking a new count in
  place, is checked exactly while the key is on, flips the key both ways in
  the injected store, and follows a change to the key made anywhere through
  the defaults watch, which ignores a change to any other key; the menu sits
  4 pt below the button, flipped or not and right to left; the tint is none
  with no filter and system blue with one, whatever the toggle says, and the
  tool tip and accessibility value name the repo; the item stays 28 pt wide
  for an 80-character repo name; a filter item made after an apply starts
  from it.
- **Which repos show:** with Show Hidden Repos off, a hidden repo chosen in
  the filter shows, dimmed; with it on, it shows too; with no repo chosen,
  hidden repos show only while it is on.
- **Overflow rows:** every item's menu form, or AppKit's default where it has
  none, sends its action from a menu item without raising, the leading item's
  "Navigation" submenu row by row with Toggle Sidebar checked rather than
  sent; the filter's form mirrors the button's menu, Show Hidden Repos
  included, and sets the filter.
- **Title width:** the title item keeps its frame as the title goes from short
  to long and back, and starts at or after the divider; a fitting measurement
  of the title view gives its constant ideal width whatever the text.
- **Shortcuts:** the three commands exist, with their shortcuts.
- **Live, before merge,** on the owner's machine: positions with the sidebar
  shown and collapsed and in full screen, no separator line, the filter hiding,
  nothing overflowing at the minimum width, the leading buttons 28 pt apart
  with no glass behind them, a hover square filling each icon button's frame
  and clickable across it, the filter's menu opening under its button and its
  icon blue while a filter is set, the title staying put across back and
  forward, the sidebar's footer and the status bar lined up across the
  divider, and no collapse after waking from sleep.

## Risks

- **Keeping glass off the compact buttons and the filter relies on
  forwarding.** They have none because their items are unbordered and their
  views forward nothing. If a macOS release gives glass to view items by
  another rule, one capsule would sit behind all three buttons and another
  behind the filter. No test can see glass, so only the live check on screen
  shows whether a capsule appears.
- **Re-enabling collapse could bring back #119** if
  `canCollapseFromWindowResize` is not the whole guard. Waking from sleep is on
  the live checklist.

## Rejected alternatives

- **SwiftUI only:** toolbar items in the sidebar column with
  `.sharedBackgroundVisibility(.hidden)` and `columnVisibility`. About 20 lines,
  but whether the items survive a collapse is undocumented, the hidden glass
  leaves padding, and the collapse guard stays on its 5-second timer.
- **A titlebar accessory beside the window buttons.** It stays outside SwiftUI's
  toolbar, but apps that use one repin AppKit's private title view to stop the
  title overlapping it, and carry fixes for clipping changes across macOS
  releases.
- **Inserting AppKit items into SwiftUI's toolbar.** SwiftUI is that toolbar's
  delegate and does not know the identifiers.
- **The native outline inside a SwiftUI window.** The outline mounts in a
  `NavigationSplitView` as readily as in the AppKit split, but that window keeps
  every problem above. The AppKit split and the native sidebar are one move of
  the window onto AppKit.

Prior art: vvterm (a SwiftUI app with an AppKit toolbar and split, and a test
that the toggle survives a collapse), CodeEdit and NetNewsWire.
