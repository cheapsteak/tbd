# Pinned worktrees: a fixed dock in the sidebar footer

**Status:** design approved 2026-07-26, not yet implemented.
**Branch:** `tbd/pinned-worktree-dock`, cut from `origin/main` at `6d283de3`.

## Problem

Reaching a worktree you use constantly means finding it in the scrolling repo list every
time. Repos collapse, sections reorder, the list grows — the row moves. There is no surface
that keeps a chosen worktree in the same place on screen.

The Watch Desk has the same problem in a sharper form. When daywatch or nightwatch is on,
the desk is the session you most want one click away, and today the only shortcut to it is a
text label in the app's bottom status bar (`NightwatchDeskStatusLabel`, PR #507). That label
is a one-off: it is not a worktree row, so it carries none of a row's status, PR, or
context-menu affordances, and it lives nowhere near the other worktrees.

## Solution

A **pinned dock**: a fixed region at the bottom of the sidebar, directly above the
`NightwatchModeToggle` and the "Add Repository" bar, holding worktree rows that never scroll
away. Pinning is a per-worktree toggle in the row's right-click menu. When a watch mode is
on, the Watch Desk occupies a fixed slot of its own at the bottom of that region.

### Pinning is a mirror, not a move

A pinned worktree keeps its row under its repo section **and** renders in the dock. Two rows,
one worktree — like a Dock alias. The section row gains a pin glyph so the pinned state is
visible from where you pinned it.

This matters for selection: because both rows are tagged with the same `worktree.id` and both
lists bind the same `appState.selectedWorktreeIDs`, selecting either copy highlights both.
That is the correct reading of mirror semantics and it falls out of the design rather than
needing code.

### The dock row is a real worktree row

`PinnedDockView` renders `WorktreeRowView` unmodified. Status indicator, working/parked
glyphs, PR icon, unread bolding, inline rename, hover child-worktree menu, and the full
right-click menu all behave exactly as they do in the list. **The only difference between a
dock row and a section row is where it sits.** No compact variant, no second row
implementation to drift out of sync.

### The Watch Desk has its own fixed slot

When `nightwatchExperimental` is on and `nightwatchMode != .off`, the desk worktree renders in
a dedicated slot **below** the scrollable pinned area and **directly above** the Day/Night
toggle. It is not a member of the pinned list, so no amount of scrolling in that list can move
it off screen — the desk and its toggle stay adjacent and always visible.

```
┌──────────────────────┐
│ ▾ tbd                │
│    main              │   scrolling repo list
│    daemon-storm      │
├──────────────────────┤
│ ● nightwatch-tint  ▕│▖
│ ○ deeplink         ▕│█  pinned area — scrolls, capped
│ ● testing-slice-e  ▕│▌
├──────────────────────┤
│ ◐ Watch Desk         │  fixed slot — never scrolls
├──────────────────────┤
│ Off │ ◐ Day │🌙 Night│
├──────────────────────┤
│ + Add Repository   ⌄ │
└──────────────────────┘
```

The desk is not stored as a pin — its `pinnedAt` stays `nil` — and its right-click menu offers
**neither** Pin nor Unpin. The Day/Night toggle immediately below is its control: turn mode
off and the slot disappears.

The slot is **exactly one row** and does not expand children, unlike pinned rows. That is what
makes "always directly above the toggle" a guarantee rather than a usual case. It costs
nothing in practice: the desk is a scratch worktree, and `children(of:)` only ever returns
repo worktrees, so a desk with children is hypothetical. If one ever has them, they remain
reachable in the Scratch section.

The desk row shows the worktree's real display name, `"◐ Watch Desk"`, in every mode. The ◐
is baked into `NightwatchDeskPrompts.deskDisplayName`, and swapping it to 🌙 in the dock would
make the row disagree with its own mirror in the Scratch section. Mode is already legible
from the toggle immediately below, so the glyph carries no load.

### Growth is capped

The **pinned area** grows one row per visible row — pins plus any expanded children — up to
`min(5 rows, 40% of sidebar height)`, then scrolls internally. The repo list above therefore
never loses more than 40% of its height plus the one-row desk slot, however many worktrees are
pinned or expanded. With no pins and mode off, the whole footer addition is absent and the
sidebar looks exactly as it does today.

Because an expansion can push the pinned area past its cap, that area scrolls the selected row
into view whenever selection changes to a row it contains. The desk slot never scrolls, so it
is exempt.

## Removals

The status-bar mode tint and desk label from PR #507 both go. Mode indication lives in the
sidebar footer: the Day/Night toggle shows and sets the mode, and the desk row appears
alongside it. The menu-bar `Nightwatch ◐/🌙` CommandMenu title stays — it is the only mode
readout visible when TBD is unfocused.

Delete:

| File / symbol | Why |
|---|---|
| `StatusBarView.statusBarTint`, `.tintOpacity`, its `ZStack` background | Bar returns to plain `.background(.bar)` |
| `Sources/TBDApp/Helpers/NightwatchDeskStatusLabel.swift` | Superseded by the dock row |
| `Sources/TBDApp/Theme/NightwatchModeTheme.swift` | Contains only `tintColor(for:)`; with no tint anywhere it is dead |
| `Tests/TBDAppTests/StatusBarViewTintTests.swift` | Tests deleted code |
| `Tests/TBDAppTests/NightwatchDeskStatusLabelTests.swift` | Tests deleted code |
| `Tests/TBDAppTests/NightwatchModeThemeTests.swift` | Tests deleted code |

`NightwatchDeskStatusLabel()` was the first element of `StatusBarView`'s `HStack`. Removing it
leaves the `Spacer()` as the first child, which is what the bar looked like before PR #507.

## Architecture

### Persistence — DB column

`pinnedAt` is a nullable `DATETIME` on the `worktree` table. `NULL` means unpinned.

This mirrors terminal pinning exactly (`Terminal.pinnedAt`, `TerminalSetPinParams`,
`terminal.setPin`), keeps every per-worktree flag in one place next to `sortOrder` and
`autoArchiveOnMerge`, survives a UserDefaults reset, and gives pin ordering for free.

Three changes in **one commit**, per the migration rule in the root `CLAUDE.md`:

1. `Sources/TBDDaemon/Database/Database.swift` — migration `v60_worktree_pinned_at`:
   `ALTER TABLE worktree ADD COLUMN pinnedAt DATETIME`. Deliberately **no** `DEFAULT`: existing
   rows must land on `NULL` (= unpinned), which is what we want. The
   `ADD COLUMN ... DEFAULT` backfill trap documented in `CLAUDE.md` does not apply, because
   there is no Swift-side default to flip later.
2. `Sources/TBDDaemon/Database/WorktreeStore.swift` — `WorktreeRecord` gains
   `var pinnedAt: Date?`, threaded through its `init(from:)` and its `Worktree` projection.
3. `Sources/TBDShared/Models.swift` — `Worktree.pinnedAt: Date?`, optional so existing
   persisted JSON and DB rows still decode.

### RPC

`worktree.setPin` with `WorktreeSetPinParams { worktreeID: UUID, pinned: Bool }`, in
`Sources/TBDShared/RPCProtocol.swift` next to `TerminalSetPinParams`. The handler writes
`Date()` or `NULL` and emits the existing worktree-changed delta, so the app refreshes through
the path every other row action already uses.

No CLI command in this change. The RPC makes `tbd worktree pin` trivial to add later if it
turns out to be wanted; adding it now is speculative.

### Shared desk predicate

`NightwatchDeskStatusLabel` currently resolves the desk with
`displayName == NightwatchDeskPrompts.deskDisplayName && isScratch`, written inline. That
predicate is about to have two more callers (dock content, menu suppression), so it moves to
`TBDShared`:

```swift
extension Worktree {
    /// The mode-managed Watch Desk scratch worktree, identified by its fixed
    /// display name. Not user-pinnable: the Day/Night toggle controls it.
    public var isNightwatchDesk: Bool {
        isScratch && displayName == NightwatchDeskPrompts.deskDisplayName
    }
}
```

One definition instead of three copies.

### Selected dock rows expand their children

A dock row whose subtree is selected expands to show its descendants, indented, exactly as
`WorktreeSubtreeView` renders them in the list. Deselect and the subtree collapses again. This
keeps the dock compact by default while making a pinned parent's children reachable without
scrolling back up to the list.

"Selected" means **the row itself or any descendant of it is selected**. Scoping it to the row
alone would be self-defeating: you would click a child in the dock, selection would move off
the parent, and the child you just clicked would vanish out from under the cursor.

Expansion is transient view state derived from selection — it is never persisted, and it is
not a disclosure triangle the user toggles.

### Dock contents — a pure function

```swift
struct PinnedDockRow: Identifiable, Equatable {
    let worktree: Worktree
    let depth: Int              // 0 = pinned row; 1+ = expanded descendant
    let sectionRepoID: UUID?    // repoID of this row's top-level ancestor; nil at depth 0
    var id: UUID { worktree.id }
}

enum PinnedDockContent {
    /// Scrollable pinned area. Never contains the desk.
    static func rows(allWorktrees: [Worktree],
                     selectedIDs: Set<UUID>,
                     children: (UUID) -> [Worktree]) -> [PinnedDockRow]

    /// The fixed desk slot, or nil when it should not render.
    static func deskRow(allWorktrees: [Worktree],
                        mode: NightwatchMode,
                        experimentalEnabled: Bool) -> Worktree?
}
```

The two are separate functions because they render into separate containers with different
scroll behaviour. `rows` no longer takes `mode` or `experimentalEnabled` at all — the pinned
area is entirely mode-independent, which is a nice simplification of the original design.

`children` is injected rather than recomputed so the dock and the list agree on what a child
is: the view passes `appState.children(of:)`, which already filters to `.active`/`.creating`
and sorts by `sortOrder`. Tests pass a stub. Duplicating that predicate here would let the two
surfaces drift.

`deskRow` returns the worktree satisfying `isNightwatchDesk` when
`experimentalEnabled && mode != .off`, and `nil` otherwise. It also returns `nil` when mode is
on but no such worktree exists — mode was just turned on and the daemon has not created the
desk yet. That is not an error and gets no placeholder row.

`rows` rules, in order:

1. Every worktree with `pinnedAt != nil`, sorted ascending by `pinnedAt`. Oldest pin first, so
   new pins append and existing rows never move.
2. The desk is excluded even if something set its `pinnedAt`, so it can never appear both in
   the pinned area and in its own slot.
3. Archived worktrees are excluded as top-level rows. Their `pinnedAt` is left untouched, so
   reviving one restores its pin. (`children` already excludes them from expansions.)
4. Each top-level row expands its descendants, depth-first at `depth + 1`, **iff** its own id
   or any descendant id is in `selectedIDs`. Otherwise it contributes one row.
5. A worktree already emitted is never emitted again. A pinned worktree that is also a
   descendant of another pinned worktree keeps its own top-level position and does not repeat
   inside the expansion. This also makes a cyclic `parentWorktreeID` chain terminate, so the
   dock needs no depth cap of its own — unlike `WorktreeSubtreeView`, whose recursion is
   bounded by `kMaxSubtreeDepth` because it has no visited set.

No SwiftUI, no `AppState` — takes values and one closure, returns values, fully unit-testable.

### Dock height — a pure function

```swift
enum PinnedDockMetrics {
    static let rowHeight: CGFloat = 26      // matches defaultMinListRowHeight in SidebarView
    static let maxRows: Int = 5
    static func height(rowCount: Int, availableHeight: CGFloat) -> CGFloat
}
```

Returns `min(rowCount × rowHeight, maxRows × rowHeight, availableHeight × 0.4)`, and `0` for
`rowCount == 0`. The view applies the number; the arithmetic is tested on its own.

### View

`Sources/TBDApp/Sidebar/PinnedDockView.swift`:

```swift
struct PinnedDockView: View {
    let rows: [PinnedDockRow]     // from PinnedDockContent.rows(...)
    let availableHeight: CGFloat  // sidebar height, from the GeometryReader below
    @EnvironmentObject var appState: AppState

    var body: some View {
        if !rows.isEmpty {        // empty dock renders nothing at all — no divider, no gap
            ScrollViewReader { proxy in
                List(selection: $appState.selectedWorktreeIDs) {
                    ForEach(rows) { row in
                        WorktreeRowView(worktree: row.worktree,
                                        indentLevel: row.depth,
                                        sectionRepoID: row.sectionRepoID)
                            .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 0))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .tag(row.worktree.id)
                    }
                }
                .onChange(of: appState.selectedWorktreeIDs) { _, ids in
                    // An expansion can push the dock past its cap; keep the
                    // selected row visible instead of scrolled out of sight.
                    if let target = ids.first, rows.contains(where: { $0.id == target }) {
                        withAnimation { proxy.scrollTo(target) }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(height: PinnedDockMetrics.height(rowCount: rows.count,
                                                    availableHeight: availableHeight))
        }
    }
}
```

`indentLevel: row.depth` is the same parameter `WorktreeSubtreeView` uses for nesting, so
expanded children indent identically to the list.

`sectionRepoID` drives the muted `(repo-name)` suffix that `WorktreeRowView` shows when a row
belongs to a different repo than the section containing it. In the dock:

- **depth 0** — `nil`. A top-level dock row sits under no section, so a suffix there would be
  labelling a section that does not exist.
- **depth ≥ 1** — the top-level ancestor's `repoID`. The pinned parent *is* the section for
  its expansion, so a child pulled in from another repo gets the same `(repo-name)` suffix it
  carries in the list. That is what "behaviour exactly the same" requires.

A second `List` bound to the same selection set is what buys full row fidelity: `.tag`,
native selection highlight, native row metrics, and `.listRowInsets` all work verbatim, so
`WorktreeRowView` is reused with no changes. The alternative — a `VStack` plus hand-rolled
selection chrome — would mean reimplementing List's accent fill, rounded-rect inset, and
inactive-window gray, three things that drift on every macOS release.

Known cost: two `List`s means two keyboard-navigation islands. Arrow keys move within
whichever list has focus rather than crossing between them. Accepted — the dock is a
click target, and full row fidelity was the stated requirement.

The desk slot is a sibling view, `PinnedDockDeskSlot`, built the same way — a single-row
`List(selection:)` at a fixed `PinnedDockMetrics.rowHeight`:

```swift
struct PinnedDockDeskSlot: View {
    let desk: Worktree?           // from PinnedDockContent.deskRow(...)
    @EnvironmentObject var appState: AppState

    var body: some View {
        if let desk {
            List(selection: $appState.selectedWorktreeIDs) {
                WorktreeRowView(worktree: desk)
                    .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .tag(desk.id)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .frame(height: PinnedDockMetrics.rowHeight)
        }
    }
}
```

Using a `List` here rather than a bare `WorktreeRowView` is not ceremony — it is what gives
the desk row the same native selection highlight and row metrics as every other row. A bare
row would need hand-rolled selection chrome, which is the thing this design rejects.

Both slot into `SidebarView`'s existing `.safeAreaInset(edge: .bottom)`, in this order:

```
Divider
PinnedDockView        ← scrolls, capped, absent when empty
Divider               ← only when both the pinned area and the desk slot are present
PinnedDockDeskSlot    ← fixed one row, absent when mode off
NightwatchModeToggle  ← existing
Add Repository + filter bar  ← existing
```

`availableHeight` comes from a `GeometryReader` wrapping the sidebar's `List`, read once and
passed down — the dock must not read geometry from inside its own frame, which would feed its
height back into itself.

### Menu

`RowActionMenu` gains `.pin` and `.unpin`. `RowActionMenuActions` emits:

- nothing, when `worktree.isNightwatchDesk`
- `.unpin`, when `pinnedAt != nil`
- `.pin`, otherwise

That enum already has unit tests, so all three cases are covered without instantiating a view.

### Data flow

Right-click → `.pin` → `appState.setPin(worktreeID:pinned:)` → `worktree.setPin` RPC → daemon
writes `pinnedAt` → worktree-changed delta → `appState.worktrees` updates →
`PinnedDockContent.rows` recomputes → dock re-renders. Identical to every existing row action.

There is no optimistic local update: the dock reflects daemon state. A failed RPC therefore
leaves the dock unchanged and logs via `os.Logger` — the pin visibly does not take, which is
honest, rather than a row that appears and then vanishes.

### Section-row pin glyph

A worktree with `pinnedAt != nil` shows a trailing `pin.fill` SF Symbol in its section row,
`.caption` weight and `.secondary` foreground, alongside the existing trailing indicators — so
the pinned state is discoverable from the place you pinned it. The desk does not get one; it
is not a pin.

## Feature flag

**None.** The root `CLAUDE.md` requires a default-off flag for behavior that acts without a
user gesture, kills processes or mutates persisted state, or wholesale-replaces a load-bearing
path. This is additive UI plus a mirror render, driven entirely by an explicit user gesture,
and it replaces nothing that carries load. It falls under the rule's "small additive UI"
exemption. The dock is invisible until a user pins something.

The desk row remains gated by the existing `nightwatchExperimental` opt-in, fail-closed —
same gate as every other nightwatch surface.

## Testing

Per the `CLAUDE.md` rule that every gating conditional gets a test per branch:

**`PinnedDockContentTests` — `deskRow`**
- Present / absent across all six combinations of `mode ∈ {off, daywatch, nightwatch}` ×
  `experimentalEnabled ∈ {true, false}` — the desk resolves only when the flag is on and mode
  is not off. This is the `CLAUDE.md` branch-coverage requirement for the gate.
- Mode on but no desk worktree exists → `nil`, no crash.

**`PinnedDockContentTests` — `rows`**
- Pins sort ascending by `pinnedAt`; a new pin appends rather than reordering.
- `pinnedAt == nil` excluded.
- Archived worktree with a non-nil `pinnedAt` excluded.
- Desk carrying a stray `pinnedAt` is excluded from `rows` — it must never appear both in the
  scrolling area and in its fixed slot.

**`PinnedDockContentTests` — expansion**
- Nothing selected → every top-level row contributes exactly one row, no children.
- Pinned parent selected → its children follow it at `depth 1`, in `children(of:)` order.
- Grandchild selected → the whole chain expands; the parent stays visible (this is the case
  that would break if "selected" meant the row itself only).
- A sibling pin selected → the *other* pin stays collapsed.
- Expanded child's `sectionRepoID` is the top-level ancestor's `repoID`; a depth-0 row's is
  `nil`.
- A worktree that is both pinned and a descendant of another pin appears exactly once, at its
  top-level position.
- Cyclic `parentWorktreeID` chain terminates and emits each worktree once.
- `children` closure returning `[]` for everything → identical output to nothing selected.

**`PinnedDockMetricsTests`**
- Zero rows → height 0.
- Below the cap → `rowCount × rowHeight`.
- Above `maxRows` → clamped to `maxRows × rowHeight`.
- Short sidebar → clamped to 40% of available height.

**`RowActionMenuTests`** (extend existing)
- Unpinned worktree offers `.pin`, not `.unpin`.
- Pinned worktree offers `.unpin`, not `.pin`.
- Desk worktree offers neither.

**Daemon**
- Migration `v60` adds the column; pre-existing rows read back `nil`.
- `WorktreeStore` round-trips a non-nil `pinnedAt` and a nil one.
- `worktree.setPin` sets a timestamp on `pinned: true` and clears to `NULL` on `false`.

**Deletions:** the three test files listed under Removals.

## Out of scope

- CLI `tbd worktree pin` — the RPC exists; add it when wanted.
- Drag-to-reorder within the dock. Pin order is by pin time.
- A user-toggled disclosure triangle on dock rows. Expansion is derived from selection and
  nothing else — there is no expanded/collapsed state to persist.
- Pinning repos or whole sections. Worktrees and scratch worktrees only.
- Any mode tint. The window-wide wash was rejected in PR #507 and the status-bar tint is
  removed here; mode is text and glyphs, not color.
