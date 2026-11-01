# AppKit window chrome — the sidebar toggle and history beside the window buttons

Status: design, approved for implementation planning
Date: 2026-11-01
Rides: the native sidebar's flag ([`2026-10-31-native-sidebar-design.md`](2026-10-31-native-sidebar-design.md))

With the native sidebar on, this spec moves the main window's split and toolbar
onto AppKit. The sidebar toggle and back/forward sit beside the window buttons,
the repo filter sits over the list it filters, and the worktree title aligns
left.

## Problem

- **Back/forward sit in a Liquid Glass capsule after the sidebar's edge,** and
  the sidebar toggle draws in its own glass circle at the sidebar's trailing
  edge, though `.toolbar(removing: .sidebarToggle)` asks for none.
- **The toggle does nothing, because the sidebar cannot collapse.** Waking from
  sleep once collapsed it with no way back (#119), so `lockSidebarOpen`
  (`TBDApp.swift`) sets `canCollapse` and `canCollapseFromWindowResize` to false
  on SwiftUI's split controller. SwiftUI resets both on every layout pass, so
  the app re-applies them every 5 seconds.
- **The title is centred** (`.principal`), away from the sidebar it belongs
  beside.
- **The repo filter sits at the toolbar's far right,** away from the list it
  filters.
- **A gray separator line runs under the sidebar's part of the titlebar,** though
  the window's own `titlebarSeparatorStyle` is `.none`.

SwiftUI cannot place these reliably. Whether toolbar items in the sidebar column
survive a collapse is undocumented; hiding an item's glass leaves extra padding
(Apple Developer Forums thread 816001); and `NavigationSplitView` owns the
window toolbar, so a custom `NSToolbar` cannot sit beside it. The toolbar already
carries workarounds for SwiftUI's lowering of it (`Sources/TBDApp/CLAUDE.md`):
capsule fusing rules, and `.id` rebuilds because AppKit materializes a split
button's menu once.

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
- No file-panel toggle in the toolbar. The Changes panel's toggle leaves the
  window toolbar; ⌘⇧E stays as a menu command.

## Non-goals

- **Changing what the other toolbar items do.** The Servers split button and
  the remote session buttons are rebuilt with the behavior they have.
- **The window with the native sidebar off.** It stays SwiftUI, unchanged.
- **User toolbar customization.**

## Window structure

With `useAppKitSidebar` on when the main window is created, `ContentView` hosts
an `NSSplitViewController` through an `NSViewControllerRepresentable` instead
of the `NavigationSplitView`:

- **The sidebar item** is `NSSplitViewItem(sidebarWithViewController:)` hosting
  `SidebarView`, which still chooses the native outline or the `List` from the
  key. Its minimum thickness fits every item in the sidebar's part of the
  toolbar (see "Width").
- **The content item** hosts the detail area, `DetailSectionHostPager`, as
  today.
- **Collapse** is the split item's: `canCollapse` is true and
  `canCollapseFromWindowResize` false, the guard against #119. They are set once,
  because nothing resets them on this path, and `lockSidebarOpen` skips the
  window.
- **Both items' `titlebarSeparatorStyle` is `.none`.** The running app confirms
  that this is the line's source; if it is the scroll-edge effect instead, that
  effect is turned off for the sidebar's scroll view.

The banners above the split and the status bar below it stay where they are in
`ContentView`.

## The toolbar

A `MainToolbarController` owns an `NSToolbar`, is its delegate, and installs it
on the main window when the split appears, with `toolbarStyle = .unified`.
Nothing on this path uses SwiftUI's `.toolbar`. Items, left to right:

1. **Leading buttons** – one item holding three compact buttons side by side
   (see "Compact buttons"): the sidebar toggle, whose action is the split
   controller's `toggleSidebar(_:)`, then back and forward, enabled from
   `AppState.canGoBack` and `canGoForward`. The item is not `isNavigational`,
   which would move it after the separator.
2. **Flexible space.**
3. **Repo filter** – a menu item showing the current filter, as the `Picker`
   does today. It is removed from the toolbar while the sidebar is collapsed
   and put back when it expands.
4. **Tracking separator** – an `NSTrackingSeparatorToolbarItem` that the
   toolbar creates under an identifier of its own, bound to the split's first
   divider and never changed afterwards. Everything before it sits over the
   sidebar, and stays beside the window buttons when the sidebar collapses.
   It is not the standard `.sidebarTrackingSeparator`, because AppKit's own
   item for that identifier finds a divider on its own, and re-binding it
   afterwards raises a KVO exception.
5. **Title cluster** – today's `worktreeTitleItem` content in a hosting view, in
   a borderless item. Its width does not follow its text: the item fills the
   space between the tracking separator and the right-hand items, within a
   constant minimum and maximum, and the cluster sits at its leading edge. So
   the cluster starts just past the separator and stays put when back,
   forward or a new selection changes the title. A title wider than the item
   is cut at the item's trailing edge, and nothing else is cut: the notes
   button's hover label reaches past the cluster's leading and bottom edges.
6. **Flexible space.**
7. **The right-hand items,** with today's behavior: the Servers split button
   and the remote session buttons (Reconnect, Stop with its confirmation, and
   Transcript, shown on the remote spec's terms). The Servers button is an
   `NSMenuToolbarItem` whose menu an `NSMenuDelegate` builds each time it
   opens, and whose image updates in place, so no item is rebuilt to refresh
   it.

The PR split button and the file-panel toggle are not rebuilt (see "Goals").

Which items are present and in what order is a pure function of a small state
value: whether the sidebar is collapsed, what is selected, the remote session's
state. The controller observes `AppState` with
`withObservationTracking` and applies a changed result on the next main-actor
turn, never during a SwiftUI update, which can re-enter layout.

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
  required constraints. It holds three accessory-bar `NSButton`s, toggle,
  back and forward, each 28 pt wide by a required constraint. Required
  constraints chain them from the host's leading edge to its trailing edge
  and pin each to its top and bottom, which wins over the bezel's wider
  intrinsic size. AppKit centres items vertically, which puts the glyphs on
  the window buttons' line.
- **Pitch** – 28 pt: each button is one pitch wide and the buttons touch, so
  none of AppKit's spacing between items falls between them.
- **Glyph** – `sidebar.left`, `chevron.left` and `chevron.right`, at 13 pt,
  regular weight and medium scale. The scale is named because a toolbar draws
  its buttons at large control size, which scales up a symbol whose
  configuration names none: measured in the running app, the toggle's ink
  drew 19.5 × 15 pt and each chevron's 8 × 14 pt, about 1.25 times too big.
  At medium scale they draw 15 × 12 pt and 6 × 11 pt, against the reference's
  16 × 13 pt and 6 × 11 pt. Back and forward draw grey while disabled.
- **Hover** – each button is bordered with `showsBorderOnlyWhileMouseInside`,
  so its bezel shows only while the pointer is over it: it highlights on hover
  and shows no border at rest.
- **No glass** – `NSToolbarItem` forwards `isBordered`, `isEnabled`, target,
  action and image to its view when the view answers them, so a bordered
  button as the item's view would make the item bordered, and a bordered item
  gets a Liquid Glass background. The host answers none of those, so the item
  keeps its own `isBordered = false`, set explicitly, and shows no glass, as
  the title item does; in the running app no capsule shows. The bordered
  buttons one level down keep their own hover highlight.
- **Wiring** – each button carries its own target, action and tool tip, and
  each row of the overflow form its own target and action; the item carries
  none. An item with a custom view keeps no target or action its view does
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
  current choice checked, kept in step with the popup.
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
- **Filter** – 110 pt, its maximum width.
- **Margin** – 20 pt before the tracking separator.

That is 92 + 84 + 2 × 8 + 110 + 20 = 322 pt, below the 400 pt maximum. The
spacing is the one estimate in it: the running app confirms it, and the
thickness grows with it.

### Shortcuts

⌘[, ⌘] and ⌘⇧E move from toolbar buttons to `.commands` menu items on both
paths, so each works wherever its button is drawn.

## Switching

The window structure is chosen when the main window is created. Flipping the
Settings toggle still swaps the sidebar's contents at once, and the window
chrome follows at the next launch; the toggle's help text says so. Until then
the native list can sit in the SwiftUI window or the `List` in the AppKit one,
and both combinations work.

## Rollout

The chrome rides `useAppKitSidebar` and graduates with it; the native sidebar
spec's parity checklist carries the chrome's items. With the key off, the
SwiftUI window runs unchanged. During the soak, a change to a toolbar item's
behavior lands in both toolbars, and its PR says so.

No durable resource is added.

## Testing

- **The flag both ways:** the key off builds the `NavigationSplitView` with the
  SwiftUI toolbar; the key on builds the split controller and the AppKit
  toolbar, with no SwiftUI toolbar.
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
  three buttons tile the host at 0, 28 and 56 pt, each 28 × 28 pt and each
  with its identifier, tool tip, accessibility label, target and action; each
  glyph's ink is within 2 pt of the reference; back and forward start
  disabled, button and row, follow the snapshot, and an apply brings back a
  row that drifted; a copy keeps the host, its three buttons with their glyphs
  and actions, and its size; the sidebar's minimum thickness is the "Width"
  formula. The glyph test measures the image drawn on its own, outside any
  control, so it cannot see the control size; the live check does.
- **Overflow rows:** every item's menu form, or AppKit's default where it has
  none, sends its action from a menu item without raising, the leading item's
  "Navigation" submenu row by row with Toggle Sidebar checked rather than
  sent; the filter's form mirrors the popup and sets the filter.
- **Title width:** the title item keeps its frame as the title goes from short
  to long and back, and starts at or after the divider; a fitting measurement
  of the title view gives its constant ideal width whatever the text.
- **Shortcuts:** the three commands exist on both paths.
- **Live, before merge,** on the owner's machine: positions with the sidebar
  shown and collapsed and in full screen, no separator line, the filter hiding,
  nothing overflowing at the minimum width, the leading buttons 28 pt apart
  with no glass behind them and a hover highlight, the title staying put across
  back and forward, and no collapse after waking from sleep.

## Risks

- **Two toolbars to keep in step** until the SwiftUI path is deleted.
- **Keeping glass off the compact buttons relies on forwarding.** They have
  none because their item is unbordered and its view forwards nothing. If a
  macOS release gives glass to view items by another rule, one capsule would
  sit behind all three buttons. No test can see glass, so only the live check
  on screen shows whether a capsule appears.
- **Re-enabling collapse could bring back #119** if
  `canCollapseFromWindowResize` is not the whole guard. Waking from sleep is on
  the live checklist.

## Rejected alternatives

- **SwiftUI only:** toolbar items in the sidebar column with
  `.sharedBackgroundVisibility(.hidden)` and `columnVisibility`. About 20 lines,
  but whether the items survive a collapse is undocumented, the hidden glass
  leaves padding, and the 5-second lock stays.
- **A titlebar accessory beside the window buttons.** It stays outside SwiftUI's
  toolbar, but apps that use one repin AppKit's private title view to stop the
  title overlapping it, and carry fixes for clipping changes across macOS
  releases.
- **Inserting AppKit items into SwiftUI's toolbar.** SwiftUI is that toolbar's
  delegate and does not know the identifiers.
- **Shipping without a flag.** This replaces the window's split and toolbar, a
  load-bearing path.
- **A flag of its own.** The AppKit split and the native sidebar are one move of
  the window onto AppKit, and the native sidebar's flag is already soaking.

Prior art: vvterm (a SwiftUI app with an AppKit toolbar and split, and a test
that the toggle survives a collapse), CodeEdit and NetNewsWire.
