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

1. **Sidebar toggle** – a borderless item (`isBordered = false`) whose action is
   the split controller's `toggleSidebar(_:)`.
2. **Back** and 3. **Forward** – borderless items, enabled from
   `AppState.canGoBack` and `canGoForward`. They are not `isNavigational`, which
   would move them after the separator.
4. **Flexible space.**
5. **Repo filter** – a menu item showing the current filter, as the `Picker`
   does today. It is removed from the toolbar while the sidebar is collapsed
   and put back when it expands.
6. **`.sidebarTrackingSeparator`** – everything before it sits over the
   sidebar, and stays beside the window buttons when the sidebar collapses.
7. **Title cluster** – today's `worktreeTitleItem` content in a hosting view, in
   a borderless item.
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

### Width

AppKit drops a toolbar item that does not fit its section, silently, with no
overflow. So the sidebar's minimum thickness is at least the width of the
window buttons, the three icons and the filter. The running app confirms the
number.

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
- **Shortcuts:** the three commands exist on both paths.
- **Live, before merge,** on the owner's machine: positions with the sidebar
  shown and collapsed and in full screen, no separator line, the filter hiding,
  nothing dropped at the minimum width, and no collapse after waking from sleep.

## Risks

- **Two toolbars to keep in step** until the SwiftUI path is deleted.
- **macOS 27 reportedly draws a bar behind toolbar buttons;** unverified for
  borderless items.
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
