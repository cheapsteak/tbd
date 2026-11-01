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

1. **Sidebar toggle** – a compact button (see "Compact buttons") whose action
   is the split controller's `toggleSidebar(_:)`.
2. **Back** and 3. **Forward** – compact buttons, enabled from
   `AppState.canGoBack` and `canGoForward`. They are not `isNavigational`, which
   would move them after the separator.
4. **Flexible space.**
5. **Repo filter** – a menu item showing the current filter, as the `Picker`
   does today. It is removed from the toolbar while the sidebar is collapsed
   and put back when it expands.
6. **Tracking separator** – an `NSTrackingSeparatorToolbarItem` that the
   toolbar creates under an identifier of its own, bound to the split's first
   divider and never changed afterwards. Everything before it sits over the
   sidebar, and stays beside the window buttons when the sidebar collapses.
   It is not the standard `.sidebarTrackingSeparator`, because AppKit's own
   item for that identifier finds a divider on its own, and re-binding it
   afterwards raises a KVO exception.
7. **Title cluster** – today's `worktreeTitleItem` content in a hosting view, in
   a borderless item. Its width does not follow its text: the item fills the
   space between the tracking separator and the right-hand items, within a
   constant minimum and maximum, and the cluster sits at its leading edge. So
   the cluster starts just past the separator and stays put when back,
   forward or a new selection changes the title. A title wider than the item
   is cut at the item's trailing edge, and nothing else is cut: the notes
   button's hover label reaches past the cluster's leading and bottom edges.
8. **Flexible space.**
9. **The right-hand items,** with today's behavior: the Servers split button
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

- **View** – each is a view item whose view is a plain host view, 20 pt wide
  and 28 pt tall, held by required constraints. The host holds an
  accessory-bar `NSButton` pinned to its four edges by required constraints,
  which win over the bezel's wider intrinsic size. AppKit centres items
  vertically, which puts the glyphs on the window buttons' line.
- **Pitch** – 28 pt: the 20 pt host plus AppKit's spacing between items,
  which is not public and is estimated at 8 pt.
- **Glyph** – `sidebar.left`, `chevron.left` and `chevron.right`, at 13 pt and
  regular weight. Back and forward draw grey while disabled.
- **Hover** – the button is bordered with `showsBorderOnlyWhileMouseInside`,
  so its bezel shows only while the pointer is over it: it highlights on hover
  and shows no border at rest.
- **No glass** – `NSToolbarItem` forwards `isBordered`, `isEnabled`, target,
  action and image to its view when the view answers them, so a bordered
  button as the item's view would make the item bordered. A bordered item
  gets a Liquid Glass background, and adjacent glass items share one capsule,
  so the three buttons would sit together on one. The host answers none of
  those, so the item keeps its own `isBordered = false`, set explicitly, and
  shows no glass, as the title item does. The bordered button one level down
  keeps its own hover highlight.
- **Wiring** – the target and action are set on the button and the overflow
  row. An item with a custom view keeps no target or action its view does
  not answer, so the item reads nil (measured on CI); glass follows
  `isBordered`, not these. For the same reason the
  item is a `ToolbarIconButtonItem`, an `NSToolbarItem` subclass that
  reports its button's state: setting the item's flag sets the button and the
  overflow row, and the setter compares the item's own flag, the button and
  the row, and sets each only when it differs. Back and forward set the item
  alone, and only when the item or its row differs from the snapshot, because
  calling the `isEnabled` setter posts KVO change notifications for `enabled`
  even when nothing changes. So an apply that changes nothing sets nothing,
  and a row that drifted comes back on the next one. No compact item
  autovalidates: `NSToolbarItem`'s `validate` does nothing for an item with a
  custom view, and none of the three wants validating. The host is not an
  accessibility element, so VoiceOver lands on the button.
- **Copies** – the toolbar never shows a copy, because user customization is
  off (`allowsUserCustomization = false` in `MainToolbarController`). AppKit
  copies a view item by archiving its view and unarchiving the copy's, and
  the host decodes only so that a copy AppKit makes cannot crash: it keeps no
  stored property (its button is its subview) and marks its constraints
  `shouldBeArchived`, so a copy keeps its size and edges. The item subclass
  keeps no stored property either, so it inherits `init(itemIdentifier:)`,
  which a copy calls on the item's own class. A copied Back or Forward button
  keeps its action but not its target, since an archive keeps a target only
  when it archives the target too; no displayed item depends on that.

### The overflow menu

An item that does not fit goes to the toolbar's overflow menu (») as its menu
form. AppKit's default form for a view item is a row titled with the item's
label that sends the view's action from an `NSMenuItem`, and `NSToolbarItem.h`
promises a target and action on the default row only for standard items. So
every item but one has an explicit form:

- **Toggle, back and forward** – a row acting as the button does; back and
  forward are disabled when history has nowhere to go.
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

- **Leading inset** – 88 pt from the window's edge to the first item, where
  AppKit places it after the window buttons, estimated from the reference
  toolbar.
- **Buttons** – 3 × 20 pt.
- **Spacing** – 4 × 8 pt: one after each button, and one more before the
  filter, as AppKit spaces both sides of the flexible space between forward
  and the filter even when it is empty.
- **Filter** – 110 pt, its maximum width.
- **Margin** – 20 pt before the tracking separator.

That is 88 + 3 × 20 + 4 × 8 + 110 + 20 = 310 pt, below the 400 pt maximum. The
spacing and the inset are estimates: the running app confirms them, and the
spacing is the one constant to tune if the buttons do not sit 28 pt apart.

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
  only while shown, the toggle and arrows before the separator in both; each
  conditional item against the state that shows it.
- **Collapse settings:** `canCollapse` true and `canCollapseFromWindowResize`
  false after setup and after a layout pass; both separator styles `.none`.
- **The toggle survives a collapse:** in a hosted window, the toggle and arrows
  are still toolbar items after the sidebar collapses.
- **Compact buttons:** each is an unbordered `ToolbarIconButtonItem` that does
  not autovalidate, whose host answers none of the selectors an item forwards
  and holds 20 × 28 pt, and whose button fills the host, with its tool tip,
  target and action, which the item does not keep (it reads nil); back and forward start
  disabled, button included, and an apply brings back a row that drifted;
  setting the toggle item's `isEnabled` moves its button and row; a copy keeps
  the subclass, the host, its layout and the button's glyph and action, and
  its flag is its button's; the sidebar's minimum thickness is the "Width"
  formula.
- **Overflow rows:** every item's menu form, or AppKit's default where it has
  none, sends its action from a menu item without raising; the filter's form
  mirrors the popup and sets the filter.
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
  macOS release gives glass to view items by another rule, the three buttons
  would share one capsule; the live check confirms none shows.
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
