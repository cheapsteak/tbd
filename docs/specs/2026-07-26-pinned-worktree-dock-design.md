# Pinned worktrees: a fixed dock in the sidebar footer

**Status:** design approved 2026-07-26, not yet implemented.
**Branch:** `tbd/pinned-worktree-dock`, cut from `origin/main` at `6d283de3`.

## Problem

Reaching a worktree you use constantly means finding it in the scrolling repo list every
time. Repos collapse, sections reorder, the list grows — the row moves. There is no surface
that keeps a chosen worktree in the same place on screen.

## Solution

A **pinned dock**: a fixed region at the bottom of the sidebar, directly above the
"Add Repository" bar, holding worktree rows that never scroll away. Pinning is a per-worktree
toggle in the row's right-click menu.

```
┌──────────────────────┐
│ ▾ tbd                │
│    main              │   scrolling repo list
│    daemon-storm      │
├──────────────────────┤
│ ● sidebar-polish   ▕│▖
│ ○ deeplink         ▕│█  pinned area — scrolls, capped
│ ● testing-slice-e  ▕│▌
├──────────────────────┤
│ + Add Repository   ⌄ │
└──────────────────────┘
```

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

### Growth is capped

The **pinned area** grows one row per visible row — pins plus any expanded children — up to
`min(5 rows, 40% of sidebar height)`, then scrolls internally. The repo list above therefore
never loses more than 40% of its height, however many worktrees are pinned or expanded. With
no pins, the whole footer addition is absent and the sidebar looks exactly as it does today.

Because an expansion can push the pinned area past its cap, that area scrolls the selected row
into view whenever selection changes to a row it contains.

## Architecture

### Persistence — DB column

`pinnedAt` is a nullable `DATETIME` on the `worktree` table. `NULL` means unpinned.

This mirrors terminal pinning exactly (`Terminal.pinnedAt`, `TerminalSetPinParams`,
`terminal.setPin`), keeps every per-worktree flag in one place next to `sortOrder` and
`autoArchiveOnMerge`, survives a UserDefaults reset, and gives pin ordering for free.

Three changes in **one commit**, per the migration rule in the root `CLAUDE.md`:

1. `Sources/TBDDaemon/Database/Database.swift` — migration `v63_worktree_pinned_at`
   (originally authored as `v60`; renumbered on rebase after main took v60–v62 first —
   safe because the body uses the idempotent `addColumnIfMissing` helper):
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
    /// Scrollable pinned area.
    static func rows(allWorktrees: [Worktree],
                     selectedIDs: Set<UUID>,
                     children: (UUID) -> [Worktree]) -> [PinnedDockRow]
}
```

`children` is injected rather than recomputed so the dock and the list agree on what a child
is: the view passes `appState.children(of:)`, which already filters to `.active`/`.creating`
and sorts by `sortOrder`. Tests pass a stub. Duplicating that predicate here would let the two
surfaces drift.

`rows` rules, in order:

1. Every worktree with `pinnedAt != nil`, sorted ascending by `pinnedAt`. Oldest pin first, so
   new pins append and existing rows never move.
2. Archived worktrees are excluded as top-level rows. Their `pinnedAt` is left untouched, so
   reviving one restores its pin. (`children` already excludes them from expansions.)
3. Each top-level row expands its descendants, depth-first at `depth + 1`, **iff** its own id
   or any descendant id is in `selectedIDs`. Otherwise it contributes one row.
4. A worktree already emitted is never emitted again. A pinned worktree that is also a
   descendant of another pinned worktree keeps its own top-level position and does not repeat
   inside the expansion. This also makes a cyclic `parentWorktreeID` chain terminate, so the
   dock needs no depth cap of its own — unlike `WorktreeSubtreeView`, whose recursion is
   bounded by `kMaxSubtreeDepth` because it has no visited set.

No SwiftUI, no `AppState` — takes values and one closure, returns values, fully unit-testable.

### Dock height — a pure function

```swift
enum PinnedDockMetrics {
    static let rowHeight: CGFloat = WorktreeRowView.rowHeight   // 28
    static let maxRows: Int = 5
    static func height(rowCount: Int, availableHeight: CGFloat) -> CGFloat
}
```

`rowHeight` must be **28**, sourced from a shared `WorktreeRowView.rowHeight` constant rather
than written as a literal. Verified live: `WorktreeRowView` sets `.frame(height: 28)`, so three
rows need exactly 84pt. `SidebarView`'s `.environment(\.defaultMinListRowHeight, 26)` is a red
herring — it is a floor, and the row overrides it. A dock height computed from 26 clips the
last row and shows a scrollbar at three pins. Hardcoding 84 would also mean a future change to
the row's height silently breaks the dock with no compile error.

Also verified: `.listStyle(.plain)` on macOS 26 already has zero vertical content margins here,
so the height is exactly `rowCount × rowHeight` with no correction term. Do **not** add
`.contentMargins(.vertical, 0, for: .scrollContent)` — measured to be inert, and it would imply
margins are being managed when they are not.

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

A second `List` bound to the same selection set is what buys **click-to-select**.
`WorktreeRowView` has no tap gesture of its own (verified: no `onTapGesture`,
`simultaneousGesture`, or wrapping `Button` anywhere in the file) — selection happens entirely
through the enclosing `List`'s `.tag(worktree.id)`.

Note that the *highlight* is not what the `List` provides. The row paints its own
(`WorktreeRowView.swift:261-264`: a `RoundedRectangle` filled with `Color.accentColor.opacity(0.2)`
when `appState.selectedWorktreeIDs.contains(worktree.id)`), which is why selection already
renders correctly in both mirrors the moment the shared binding updates.

The alternative — a `VStack` plus `.onTapGesture` to set selection — is the trap here.
**`.onTapGesture` blocks `.contextMenu` on macOS**, so the dock rows would silently lose their
right-click menu, breaking the "behaviour exactly the same" requirement in the least visible
way possible. Using a `List` sidesteps it entirely.

Known cost: two `List`s means two keyboard-navigation islands. Arrow keys move within
whichever list has focus rather than crossing between them. Accepted — the dock is a
click target, and full row fidelity was the stated requirement.

It slots into `SidebarView`'s existing `.safeAreaInset(edge: .bottom)`, in this order:

```
Divider               ← the ONLY divider; marks the top of the whole footer group
PinnedDockView        ← scrolls, capped, absent when empty
Add Repository + filter bar  ← existing
```

**One divider, at the very top.** A second `Divider()` below the dock was verified live to make
the dock read as belonging to the scrolling list above rather than to the footer. With one, the
dock and Add Repository read as a single visual group, which is the intent.

Worth knowing for anyone tempted to "fix" the footer's color: `.bar` renders **white**
(255,255,255) in this window, not gray — measured. The sidebar list above is (234,234,234), and
`.bar` composited over it lands at white. The dock and the Add Repository row share that
background. `.scrollContentBackground(.hidden)` on the inner `List` is load-bearing and already
correct (verified both directions: removing it makes the List paint opaque white over the
material). If the footer should read gray, that is a background-material decision affecting the
whole group — not something the dock's `List` can or should fix.

`availableHeight` comes from a `GeometryReader` wrapping the sidebar's `List`, read once and
passed down — the dock must not read geometry from inside its own frame, which would feed its
height back into itself.

### Menu

`RowActionMenu` gains `.pin` and `.unpin`. `RowActionMenuActions` emits:

- `.unpin`, when `pinnedAt != nil`
- `.pin`, otherwise

That enum already has unit tests, so both cases are covered without instantiating a view.

### Data flow

Right-click → `.pin` → `appState.setPin(worktreeID:pinned:)` → `worktree.setPin` RPC → daemon
writes `pinnedAt` → worktree-changed delta → `appState.worktrees` updates →
`PinnedDockContent.rows` recomputes → dock re-renders. Identical to every existing row action.

There is no optimistic local update: the dock reflects daemon state. A failed RPC therefore
leaves the dock unchanged and logs via `os.Logger` — the pin visibly does not take, which is
honest, rather than a row that appears and then vanishes.

### Section-row pin glyph

Pinning is reachable two ways.

**The row-action menu** carries Pin / Unpin, as described above — the discoverable, keyboard-
and accessibility-friendly path.

**A hover button on the leading edge of the row** is the fast path, mirroring the existing
nested-worktree `+`. `WorktreeRowView` already renders that `+` as an
`.overlay(alignment: .trailing)` gated on `isRowHovered`, so it floats above the row without
consuming layout width. The pin button is the same construction at `.leading`:

```swift
.overlay(alignment: .leading) {
    if isRowHovered, !isMain {
        SectionHeaderPlusButton(...)-shaped 20×20 button
            .offset(x: CGFloat(indentLevel) * 16)
    }
}
```

Three details it must respect:

- **The indent offset is required.** `.padding(.leading, CGFloat(indentLevel) * 16)` is applied
  to the row's content, but an `.overlay(alignment: .leading)` anchors to the row's *outer*
  edge — so without the offset the button floats left of the hierarchy guide lines on any
  nested row. The guide-line overlay already compensates the same way
  (`.offset(x: CGFloat(depth) * 16 + 8)`).
- **It covers `leadingIcon()` while hovering.** That slot holds the PR-status icon or the
  pending spinner. This is the same trade the trailing `+` already makes, and it is what
  "floating button" buys: zero layout impact, at the cost of occluding during hover only.
- **The glyph reflects the state, not the action**: hollow `pin` when unpinned, solid
  `pin.fill` when pinned. The `.help` text still names the action ("Pin to dock" /
  "Unpin from dock"), so hovering resolves any ambiguity about what clicking will do.

  An earlier build used `pin` / `pin.slash`, encoding the *action* instead. The crossed-out
  slash read as ugly and cluttered at caption size in a dense sidebar. Hollow-versus-filled is
  the quieter signal and matches how the rest of the sidebar's indicators behave.

**A pinned row shows its solid pin persistently, not only on hover.** The gutter button is
visible when `isRowHovered || pinnedAt != nil`, so:

| | not hovered | hovered |
|---|---|---|
| **unpinned** | nothing | hollow `pin` |
| **pinned** | solid `pin.fill` | solid `pin.fill` |

It stays a live button in the persistent case — clicking a visible solid pin unpins. There is
no separate non-interactive indicator variant.

A previous draft rejected a persistent glyph, but that draft placed it *trailing*, where it
consumed row width and fought the "don't push content right" requirement. In the leading
gutter it is free: the overlay costs no layout at either state, so the objection does not
apply and pinned rows become identifiable at a glance without hovering each one.

Whatever gates the button must also gate the hierarchy-guide-line break that keeps the thread
from striking through it — the two conditions are the same condition.

A repo's main row gets no pin button.

## Feature flag

**None.** The root `CLAUDE.md` requires a default-off flag for behavior that acts without a
user gesture, kills processes or mutates persisted state, or wholesale-replaces a load-bearing
path. This is additive UI plus a mirror render, driven entirely by an explicit user gesture,
and it replaces nothing that carries load. It falls under the rule's "small additive UI"
exemption. The dock is invisible until a user pins something.

## Testing

Per the `CLAUDE.md` rule that every gating conditional gets a test per branch:

**`PinnedDockContentTests` — `rows`**
- Pins sort ascending by `pinnedAt`; a new pin appends rather than reordering.
- `pinnedAt == nil` excluded.
- Archived worktree with a non-nil `pinnedAt` excluded.

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

**Daemon**
- Migration `v63` adds the column; pre-existing rows read back `nil`.
- `WorktreeStore` round-trips a non-nil `pinnedAt` and a nil one.
- `worktree.setPin` sets a timestamp on `pinned: true` and clears to `NULL` on `false`.

## Out of scope

- CLI `tbd worktree pin` — the RPC exists; add it when wanted.
- Drag-to-reorder within the dock. Pin order is by pin time.
- A user-toggled disclosure triangle on dock rows. Expansion is derived from selection and
  nothing else — there is no expanded/collapsed state to persist.
- Pinning repos or whole sections. Worktrees and scratch worktrees only.
