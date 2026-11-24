# Usage bars in the account menus

Two menus list Claude accounts. The tab's right-click menu has the **Swap profile** and **Fork
Session** submenus, and the tab bar's **+** button opens the new-tab menu. Each of them shows an
account's usage as text, such as `Gmail — 5h 40% ↺8pm · wk 16%`. Text gives no pace color, and the
numbers sit at a different place on each row, so accounts are hard to compare at a glance.

This change draws the 5-hour and weekly bars from the worktree picker on each account row in both
menus. The two bars sit side by side on the same line as the name.

The menus come from [account load balancing](2026-09-05-account-load-balancing-design.md) §8.2.
The pace rule is `ProfileUsagePresentation.fillLevel`, the rule the worktree picker's
`UsageBarsView` draws with.

## Goal

When I swap or fork a session onto another account, or open a new tab on one, I want each account's
5-hour and weekly usage drawn as the pace-colored bars the worktree picker shows, so I can see at a
glance which account has room.

## Scope

- **In scope:** the Swap profile and Fork Session submenus of the tab's right-click menu, and the
  account rows of the + new-tab menu.
- **Out of scope:** the Fable, Opus and Sonnet buttons of the worktree picker. These menus choose an
  account, not a model.
- **Out of scope:** the worktree picker itself, the "Choose account…" sheet, the limit banner, and the
  sidebar row's "Fork session" item. That item forks on the session's own account and lists none.
- **No flag.** The project rule asks for a default-off flag when a surface moves from SwiftUI to
  AppKit. The project owner chose to ship this without one. The change touches two menus, stores no
  data and acts only on a click, so reverting the commit restores the old menus.

## What the user sees

**Each account row** is one line: the account name, then the two bars in a column shared by every
row of that menu.

- Each bar has a short label, the bar and a percent: `5h ▬▬▬|▭ 40%` and `wk ▬|▭▭▭ 16%`.
- The bars look and behave like the worktree picker's. The fill and the percent take the pace color:
  green when the account is on track to stay under 75%, orange when it is on track to reach 75–100%,
  red when it is on track to run out. A dark tick marks how far through the window the account is.
- The row does not show reset times. The row's tooltip does, for example
  "5-hour: 40% used · resets 8pm — Weekly: 16% used · resets Fri 7pm".
- **No 5-hour limit.** Some accounts, such as Ultra accounts, have a weekly limit only. Their 5h slot
  stays empty and keeps its width, so the weekly bar lines up with the weekly bars of the other rows.
- **No usage data.** The row shows the name only, as it does today.
- **Old or failing data.** Both menus follow the rule the + menu's second line follows today
  (`ProfileUsagePresentation.secondaryLine`). If the last fetch failed, the row shows the short note
  in place of the bars, for example "rate-limited · 3h old". If the data is good but old, the row
  shows the bars, then a small grey age note.
- **Current account.** A standard macOS checkmark marks it, in place of the "●" prefix.
- **Default (logged in).** The row shows no bars, as today. TBD keeps no usage data for the default
  login.
- **Highlight.** When the pointer is on a row, the name turns white as usual. The bars keep their
  colors.
- **Appearance.** Light and dark mode follow the system.

**Unchanged:**

- The warning at the foot of Swap profile, "Resumes in this tab on the new account — interrupts
  current run", shows when the session is running.
- The + menu keeps its "Choose account…" row, and its account rows keep their indent under "Claude".
- Every other item of the right-click menu keeps its title, its order and the rule that decides
  whether it shows.

## Why the tab menu moves to AppKit

The tab's right-click menu is a SwiftUI `.contextMenu`. SwiftUI turns each item into an `NSMenuItem`
with a text title and one small leading icon. It offers no place for a drawing after the name and
no way to line a column up across rows.

An AppKit `NSMenuItem` takes an attributed title, and an attributed title can hold an image inline
(`NSTextAttachment`). The row stays a normal menu item, so highlight, arrow keys, type-to-select and
VoiceOver keep working. The + menu is already built in AppKit and already sets attributed titles.

**Rejected alternatives:**

- **Bars in the SwiftUI item's icon slot.** The slot sits before the title, so every row would show
  the bars first and the name after. Nothing documents whether SwiftUI keeps a wide, colored image at
  full size in a menu.
- **"Swap profile…" opening a second menu.** The SwiftUI menu would close and an AppKit menu with the
  bars would open in its place. Two menus in a row for one choice feels broken.
- **Custom views in menu items (`NSMenuItem.view`).** These need the same AppKit menu, and a custom
  view must also draw its own highlight and handle clicks and keys.
- **The worktree picker's floating panel.** It would turn a one-gesture submenu into a separate panel.

## Design

### Right-click on a tab

The tab drops its `.contextMenu`. A thin AppKit layer covers the tab instead.

- The layer takes a mouse event only for a right-click or a Control-click. Its `hitTest(_:)` returns
  nil for every other event, so dragging, double-click rename, hover, the close button and the hover
  card work as before.
- On a right-click or Control-click, it asks the tab for a menu built at that moment and shows it as
  a context menu at the pointer.
- `NSMenuItem` holds its target weakly, so the menu retains its target object as an associated
  object, as the + menu already does.

### The menu builder

One function builds the whole right-click menu: `TabContextMenu.build(model:perform:) -> NSMenu`.

- `model` is a value that describes the tab: its file target and Open With apps, its link, its Claude
  session ID, its pin title, whether the move to the pty holder is offered, whether it is a Claude
  tab, its profile header, whether an in-place swap is offered, the accounts and the current one,
  whether the session is running, whether Continue in Codex shows, its park action, whether a resume
  is scheduled, and whether it can be renamed.
- The tab fills `model` from the helpers that decide each item today: `WorkspaceTabFileMenu`,
  `CopyClaudeSessionIDMenu`, `TabPinMenu`, `TransportMigrationMenu`, `SwapProfileMenu`,
  `ContinueInCodexMenu` and `TabParkMenuModel`. The rules stay in one place.
- `perform` receives one `TabContextMenu.Action` per click: copy path, reveal, open with an app, copy
  link, copy session ID, pin or unpin, move to the holder, swap to an account, fork to an account,
  continue in Codex, hibernate, wake, cancel the scheduled resume, rename, or close. The tab maps each
  action to the `AppState` call the SwiftUI menu makes today.
- The Swap profile and Fork Session submenus share one account list: "Default (logged in)", a
  separator, then one row per model profile in `appState.modelProfiles` order. Swap profile ends with
  the running warning when it applies.

### The bars picture

One drawing of the two bars serves both menus. It is an `NSImage` drawn by a handler, so its colors
resolve for the menu's light or dark appearance when it draws.

- It draws from `ProfileUsagePresentation.bucketPresentation`, the values `UsageBarsView` draws from:
  percent, pace fill level and elapsed fraction.
- `FillLevel` gains an `NSColor` form beside `barColor(_:)`. Both read the same values: the adaptive
  green pair, system orange and system red.
- A missing bucket leaves its slot empty at full width, so the picture is the same size on every row.
- The image's `accessibilityDescription` gives the usage in words, for example "5-hour 40%, weekly
  16%".

Measurements, in points:

- Label column ("5h", "wk"): 14 wide, 10 pt type, secondary label color.
- Bar: 44 × 5, corner radius 2.5, on a faint track.
- Time tick: 2.5 × 9, centered on the bar.
- Percent column: 27 wide, right-aligned, 10 pt semibold rounded type with tabular digits, in the
  pace color.
- Gap inside a slot: 4. Gap between the two slots: 14.

### The account row

`AccountMenuRow` builds a row's attributed title for both menus:

1. the name, in the menu font. Each menu keeps the name text it shows today: the profile name in
   the tab menu, and the name with its login suffix ("— needs /login") in the + menu;
2. a clear spacer image, so every row's bars start at the same x. Its width is the widest name
   among the rows of that menu that show bars or a note, minus this row's name, plus a 22 pt gap;
3. the bars picture, vertically centered on the text;
4. the grey note, when there is one.

The item's plain `title` stays the name alone, for type-to-select and accessibility, as `AddTabMenu`
already does. The current account sets `state = .on`. The tooltip carries the reset times.

A pure function, `ProfileUsagePresentation.menuUsage(for:now:)`, picks one of four results for a
row:

- **Bars:** the snapshot is healthy and has a 5-hour or a weekly all-models bucket.
- **Bars with an age note:** the same, and `stalenessNote` reports the data as old.
- **A note only:** the snapshot is not healthy and `stalenessNote` has a note.
- **Nothing:** no snapshot, or no note.

### The + new-tab menu

`AddTabMenu.build` makes each account row with `AccountMenuRow`. The row keeps its blank leading icon,
which indents it under "Claude".

### What is deleted

- From `TabBar.swift`: `contextMenuContent`, `swapProfileMenuItems(mode:)` and
  `formatProfileSubmenuLabel(_:)`.
- `AddTabMenu.twoLineAttributedTitle(_:)` and its tests.
- `SwapProfileMenu.menuLabel(for:usage:liveSessions:)` and its tests.
- Any other helper that loses its last caller. `ProfileUsagePresentation.usageSummary` stays: the
  account picker sheet and the limit banner use it.

## Confirm first

The design rests on one AppKit behavior that no code in this repo exercises yet: an `NSMenu` draws
an `NSTextAttachment` image inside an item's attributed title at the image's own size, a clear
attachment holds its width, and the highlight still covers the row. Check this on screen before
anything else is built. If it does not hold, stop and bring the design back to the owner.

## Testing

Unit tests, with no menu shown:

- **Right-click menu:** for a shell tab, a live Claude tab, a parked Claude tab, a live Claude tab
  still on tmux (Fork Session but no Swap profile), a file tab, a pinned tab, a tab with a scheduled
  resume and a running session (the warning shows), assert the item titles, their order, the
  submenus and which items are enabled.
- **Actions:** each account row sends the right action: swap in place or fork, with that profile's
  ID, or with nil for the default login.
- **Alignment:** on every row of a menu, the name's width plus the spacer's width is the same. A row
  with no 5-hour bucket has a bars picture of the same size.
- **Usage states:** each of the four `menuUsage` results comes from the snapshot that should give it.
- **Bars picture:** each bucket draws in the fill level `bucketPresentation` gives it. The
  accessibility description reads as specified.
- **+ menu:** account rows are one line, the indent stays, and "Choose account…" follows them.
- **Right-click layer:** `hitTest(_:)` returns the layer for a right-click and for a Control-click,
  and nil for a plain left click.

On screen, before merge: build, restart, and right-click a Claude tab in light and dark mode. Check
the alignment, the highlight, a row with no 5-hour bucket and the tooltip, then open the + menu. The
GUI driver cannot open TBD's context menus, so the owner checks what a window capture cannot show.
