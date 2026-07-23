# Panel Agent Surface — Approach A: App-Owned Runtime, Daemon-Persisted Mirror

**Status:** Draft for review (competing spec: Approach B, daemon-owned source of truth — see `2026-07-20-panel-agent-surface-b-daemon-owned-design.md`)
**Date:** 2026-07-20

## 1. Context & Goals

TBD's app already has a real panel model (a recursive split tree of typed panes per tab), but it is invisible and unreachable from outside the app process. Agents spawned by TBD have exactly two UI levers today — `tbd notify` and `tbd terminal focus` — and the bundled `tbd` skill never mentions panels. Meanwhile panel layout persists only as a UserDefaults JSON blob the daemon knows nothing about, while tab labels/order/active-tab persist in the daemon DB: a split-brain.

Goals of this design:

1. **See** — an agent can query the pane tree for its worktree: which tabs and panes exist, the split arrangement and ratios, and what each pane renders as a *reference* (file path, URL, terminal ID, "transcript") — never rendered contents.
2. **Arrange** — an agent can split, close, resize, move panes and switch tabs, through the same code paths user gestures use.
3. **Unify persistence** — panel layout becomes reconstructable from the daemon DB, ending the UserDefaults/SQLite split-brain and laying the foundation for later two-way features (agent read-back of view state, user annotations).
4. **Per-panel history** — each pane keeps a back/forward stack of its last ~10 contents, surviving app restart.
5. **Native-feeling resize** — one shared divider component with a hover affordance replaces the five hand-rolled divider implementations.

Non-goals (v1): rendering *new* content types ("show this HTML/markdown/diff" — deferred to a separate design), reading rendered contents back, annotations, cross-worktree arrangement by default.

## 2. Current State (anchored)

- **Model:** `PaneContent` enum — `.terminal(terminalID)`, `.webview(id,url)`, `.codeViewer(id,path)`, `.note(noteID)`, `.liveTranscript(id,terminalID)` (`Sources/TBDApp/Terminal/PaneContent.swift:5`). `Tab` wraps one primary `PaneContent` (`PaneContent.swift:25`). `LayoutNode` is the recursive `.pane`/`.split(direction,children,ratios)` tree (`Sources/TBDApp/Terminal/LayoutNode.swift:12`) with helpers (`splitPane`, `removePane`, `allPaneIDs`, `replacingContent(at:with:)`) and a hand-written Codable that keeps legacy on-disk compat (`LayoutNode.swift:192`).
- **State:** all in `AppState`: `layouts: [UUID: LayoutNode]`, `tabs`, `activeTabIndices`, `worktreeTabOrders` (`Sources/TBDApp/AppState.swift:401-406`). The tree for a tab is `layouts[tab.id] ?? .pane(tab.content)` (`TerminalContainerView.swift:267-270`).
- **Persistence split-brain:** layout trees → UserDefaults blob (`persistLayouts()`/`restoreLayouts()`, `AppState.swift:878-887`); tab labels/order/active → daemon DB (`tab` table + `worktree.tabOrder`/`activeTabID`, migrations `v19`/`v20`, `Sources/TBDDaemon/Database/Database.swift:433-449`; sparse rows per `TabStore.swift:44`).
- **Mutation paths:** splits/close/viewer-reuse live in `PanePlaceholder.swift` (`splitRight()` :523, `createTerminalSplit` :546, `routeFileClick` via `Panes/ViewerRouting.swift:15`, `toggleTranscriptPane` :535 → `TranscriptRouting.swift:21`); tab switch/close/reorder in `AppState+Tabs.swift`.
- **Agent surface:** none. No panel RPC, no panel CLI, no skill mention. Only push channel is `StateDelta` broadcast (`Sources/TBDShared/StateDelta.swift:6`), and the only agent-reachable UI deltas are notifications/focus.
- **Known warts in scope:** `layouts` dict keyed by `tab.id` in the single-worktree path but by `worktreeID` in the multi-worktree grid (`TerminalContainerView.swift:572-576`); dead split stubs (`AppState+Worktrees.swift:1012-1034`).
- **Dividers:** five hand-rolled `DragGesture` implementations (file panel `ContentView.swift:672-694`; terminal splits `SplitLayoutView.swift:161-233`; dock split `TerminalContainerView.swift:605-668`; dock cells `PinnedTerminalDock.swift:50-100`; archived list `ArchivedWorktreesView.swift:203-218`), sharing only the `.cursor()` AppKit cursor-rect bridge (`SplitLayoutView.swift:237-274`). Terminal-adjacent dividers deliberately defer commit to drag-end because live resize fires tmux resize RPCs (debounce serializer, `TerminalPanelView.swift:1009-1049`).

## 3. Decisions (fixed, not open)

- v1 agent verbs are **See** (layout + content references, never contents) and **Arrange** (split, close, resize ratios, move panes, switch tabs). **Show/render is deferred** to a separate future design; v1 introduces no new content types.
- Agent-created splits may hold any *existing* pane type: terminal (new or existing), live transcript, code viewer on a path, webview on a URL, note.
- **Transcript is a panel like any other.** No special-casing. The toolbar transcript trigger already derives its lit/dark state from the shared `isLiveTranscriptPane` check (`TranscriptRouting.swift:10`, used by both the toggle at `PanePlaceholder.swift:535` and the open-state check at `:540`), so "goes dark when not visible" already holds; no change needed beyond *not* adding protections.
- Two-way (read-back, annotations) must not be precluded by the data model, but v1 is one-way push + reference/layout queries.
- Per-panel history: stack of last **10** contents per pane slot; back/forward in the pane header; right-click on either button shows a jump menu; survives app restart.
- Agent operations default-scope to the agent's own worktree (`TBD_WORKTREE_ID`); `--worktree <id|name>` overrides explicitly.
- One shared divider component; hover affordance + existing `CursorRectView` cursor bridge; deferred-commit preserved for terminal panes; **not** NSSplitView.
- Edge cleanups in scope: dual-keyed `layouts` dict, dead split stubs. Out of scope: `Tab.content` redundancy, transcript overlay/history-mode sprawl.
- Arrange ships behind a **default-off** daemon config flag (CLAUDE.md: acts without a user gesture). See-queries are ungated.

## 4. Architecture

**Ownership rule: the app is the sole runtime authority and sole writer of the pane tree. The daemon holds a persisted, write-through mirror.**

```
             See (panel.list)                       Arrange (panel.split/close/...)
  agent CLI ────────────────► daemon                agent CLI ──► daemon ─┐ validate vs mirror + flag
                               │  answers from                            │ broadcast .panelCommand(cmdID)
                               │  mirror (SQLite)                         ▼
                               │                                         app ── applies via existing
                               ▲                                          │     splitPane/removePane/
                               │  panel.syncLayout (write-through,        │     routeFileClick paths
                               │  debounced, echoes appliedCommandIDs)    │
                               └──────────────────────────────────────────┘
                                daemon completes CLI request when echo arrives
```

- **Persistence moves** from the UserDefaults blob to the daemon DB. `persistLayouts()` is replaced by a debounced `panel.syncLayout` RPC; `restoreLayouts()` is replaced by a fetch during initial state load. UserDefaults becomes a one-time import source (§5.4).
- **See** is served entirely from the mirror. No app round-trip, works while the app is busy or closed (with an explicit staleness signal, §6.1).
- **Arrange** flows CLI → daemon → validation → `StateDelta.panelCommand` broadcast → app applies on the main actor via the *same* functions user gestures call → app's next `syncLayout` echoes the applied command ID → daemon completes the CLI's pending request with the resulting layout. Commands are never applied by the daemon to its own copy; the mirror only ever changes because the app wrote it. This keeps exactly one writer and makes the sync protocol the easy kind.

Why this shape (vs. Approach B): all the interactive, latency-sensitive, terminal-lifecycle-entangled mutation code stays where it is and keeps working; the daemon gains durable knowledge of layout without ever needing to understand SwiftUI-side invariants (e.g. "DockSplitView must stay mounted", `TerminalContainerView.swift` comments). The cost is a sync protocol whose failure modes are enumerated in §12.

### 4.1 Types move to TBDShared

`PaneContent`, `Tab`, `SplitDirection`, and `LayoutNode` move from `Sources/TBDApp/Terminal/` to `Sources/TBDShared/PaneLayout.swift` so the daemon can decode, validate, and summarize trees. They are already `Codable`/`Sendable` and depend only on Foundation (+`CGFloat`, available via Foundation on macOS). The legacy-format Codable compat (`LayoutNode.swift:192-213`) moves with them. App files re-export via `typealias` during the PR to keep the diff reviewable. View-layer helpers that reference app types stay behind in an app-side `extension`.

### 4.2 Fixing the dual-keyed `layouts` dict (prerequisite)

The multi-worktree grid keys the same `[UUID: LayoutNode]` store by `worktreeID` (`TerminalContainerView.swift:572-576`) while everything else keys by `tab.id`. Before mirroring, this becomes explicit: a `LayoutKey` enum (`case tab(UUID)`, `case worktreeGrid(UUID)`) or — simpler and preferred — the grid path gets its own small `gridLayouts: [UUID: LayoutNode]` store that is *not* mirrored (the grid is an ephemeral viewing mode, not worktree state). The mirror then contains only `tab.id`-keyed trees, and `panel.list` output is unambiguous. Dead stubs at `AppState+Worktrees.swift:1012-1034` are deleted in the same commit.

## 5. Data Model & Persistence

### 5.1 New table: `tab_layout`

Migration `v53_tab_layouts` (next after `v52`, `Database.swift:875`):

```sql
CREATE TABLE tab_layout (
  tab_id      TEXT PRIMARY KEY,   -- == Tab.id (== terminal/note UUID for those tabs)
  worktree_id TEXT NOT NULL,
  layout      TEXT NOT NULL,      -- LayoutNode JSON (existing wire format)
  history     TEXT NOT NULL DEFAULT '{}',  -- {paneID: {entries:[PaneContent], cursor:Int}}
  revision    INTEGER NOT NULL DEFAULT 0,  -- app-incremented, monotonic per tab
  updated_at  DATETIME NOT NULL
);
CREATE INDEX idx_tab_layout_worktree ON tab_layout(worktree_id);
```

A dedicated table (rather than a column on `tab`) because `tab` rows are deliberately sparse — only labeled tabs get rows (`TabStore.swift:44`) — and un-sparsing `tab` would ripple through reconciliation.

Per CLAUDE.md's three-place rule: (1) migration above; (2) new GRDB record `TabLayoutRecord` in `Sources/TBDDaemon/Database/TabLayoutStore.swift`; (3) shared Codable models in `Sources/TBDShared/PaneLayout.swift` (`PaneLayoutSnapshot`, `PaneHistory` — new fields optional/defaulted). Same commit.

Also in `v53`: `config.panel_arrange_enabled BOOLEAN NOT NULL DEFAULT 0` (flag, §10).

### 5.2 Write-through sync (app → daemon)

`AppState.persistLayouts()` (`AppState.swift:878`) is replaced by:

- Coalesce layout/history changes per worktree with a **250 ms debounce** (same spirit as the terminal resize debounce; a divider drag commit, which lands once on drag-end, produces one write).
- RPC `panel.syncLayout` carries: `worktreeID`, full `[tabID: {layout, history, revision}]` for that worktree, and `appliedCommandIDs: [UUID]` (ack vehicle, §6.2). Full-state-per-worktree, not diffs — trees are small (KBs), and full writes make the mirror self-healing.
- Revision increments on every app-side mutation. The daemon rejects writes whose revision is *lower* than stored (protects against a delayed in-flight write landing after a newer one).
- On app launch and on daemon reconnect, the app pushes a full sync for every worktree it holds state for (self-heal after crashes; §12).

### 5.3 Restore (daemon → app)

During initial state load (where `loadTabStates` runs today, `AppState+Tabs.swift:19`) the app fetches `panel.getLayouts` for all worktrees and seeds `layouts` + history. The existing reconciliation (`reconcileTerminalTabs`, `AppState.swift:1704-1748`) then prunes panes whose terminals died, exactly as it does today — and the resulting corrections flow back through `syncLayout`, so the mirror converges.

### 5.4 One-time UserDefaults import

Only the app can read its own UserDefaults domain, so the import is app-side: at launch, if `panel.getLayouts` returns zero rows **and** the legacy `layoutsKey` blob exists, decode it and push via `syncLayout`. The UD key is left in place for one release as a rollback path, then the read/import code is deleted. No daemon involvement.

## 6. RPC & CLI Surface

### 6.1 See (ungated)

New `RPCMethod` constants (`Sources/TBDShared/RPCProtocol.swift`, following the `config.setX` naming convention at :181-211):

- `panel.list` — params `{worktreeID: UUID}` → result:

```json
{
  "worktreeID": "…",
  "appConnected": true,
  "stalenessSeconds": 0.4,
  "activeTabID": "…",
  "tabs": [{
    "tabID": "…", "label": "claude", "isActive": true,
    "layout": {"split": {"direction": "horizontal", "ratios": [0.62, 0.38],
      "children": [
        {"pane": {"id": "…", "type": "terminal", "terminalID": "…", "shortID": "a3f2"}},
        {"pane": {"id": "…", "type": "codeViewer", "path": "Sources/…/Foo.swift", "shortID": "9c41"}}
      ]}}
  }]
}
```

  References only: `terminal` → terminalID (+ agent type from the terminal row), `codeViewer` → path, `webview` → URL, `liveTranscript` → its terminalID, `note` → noteID. Never contents. `appConnected` is derived from the app's live delta subscription; `stalenessSeconds` is `now - updated_at`. When the app is not connected, results are served anyway and marked stale — See degrades gracefully.
- `panel.getLayouts` — app-restore fetch (app-only, not surfaced in CLI).
- `panel.syncLayout` — app-only write-through (above).

CLI: `tbd panel list [--worktree <id|name>] [--json]`. Human output is an indented tree with 4-char short IDs; `--json` is the raw result. Default worktree from `TBD_WORKTREE_ID`.

### 6.2 Arrange (gated by `panel_arrange_enabled`)

One command RPC per verb, all sharing the ack machinery:

| RPCMethod | Params (all include `worktreeID`, optional `tabID` defaulting to active tab) |
|---|---|
| `panel.split` | `paneID` (target), `direction: h\|v`, `content: PaneContentSpec`, `ratio?` |
| `panel.close` | `paneID` |
| `panel.resize` | `paneID`, `ratio` (the pane's share within its parent split, 0.1–0.9) |
| `panel.move` | `paneID`, `targetPaneID`, `direction: h\|v` |
| `panel.selectTab` | `tabID` or `index` |

`PaneContentSpec` (shared Codable): `terminal` (spawn new — reuses the `createTerminalForSplit` path, `AppState+Terminals.swift:253`), `terminal(existingID)`, `transcript(terminalID)`, `codeViewer(path)`, `webview(url)`, `note`. Note: `codeViewer`/`webview` here open *existing viewer types* as split content — this is arrange (placement of a known viewer), not the deferred show/render design (new content types, richer targeting, reuse policy).

**Flow and ack.** The daemon: (1) rejects if the flag is off (clear error naming the flag); (2) rejects if no app is subscribed (`"TBD app is not running"` — commands never queue); (3) validates against the mirror (pane exists, ratio bounds, path exists for codeViewer, transcript's terminal is a claude session); (4) broadcasts `StateDelta.panelCommand(PanelCommandDelta)` — `{commandID: UUID, worktreeID, op}` — and parks the request. The app applies the op on the main actor through the existing mutation functions, records `commandID`, and its debounced `syncLayout` echoes `appliedCommandIDs`. When the echo lands, the daemon completes the parked request with the fresh `panel.list` payload. Timeout **3 s** → error `"app did not confirm within 3s (command may still have applied — re-run 'tbd panel list')"`. The app may also NACK in the echo (`failedCommands: [{commandID, reason}]`) for races the daemon's mirror validation couldn't see (e.g. pane closed by the user mid-flight).

CLI:

```
tbd panel list        [--worktree W] [--json]
tbd panel split  <paneID> --right|--below --content terminal|terminal:<id>|transcript[:<terminalID>]|code:<path>|web:<url>|note [--ratio 0.4]
tbd panel close  <paneID>
tbd panel resize <paneID> --ratio 0.6
tbd panel move   <paneID> --target <paneID> --right|--below
tbd panel select-tab <tabID|--index N>
```

`<paneID>` accepts full UUIDs or the unambiguous short-ID prefixes shown by `list`. All commands print the post-change tree (from the ack payload) so agents see the result without a second call.

New `StateDelta` case: `panelCommand(PanelCommandDelta)` (`StateDelta.swift:6-34`). No `panelLayoutChanged` broadcast delta — there is exactly one app instance, and it is the writer.

## 7. Panel History

- **Model:** per pane slot (stable `paneID`), `PaneHistory { entries: [PaneContent], cursor: Int }`, capped at 10 (drop oldest). Lives in `AppState` beside `layouts`, mirrored in `tab_layout.history` via the same `syncLayout` write — restart-durable for free.
- **Viewer-slot navigation (ships ahead of this spec as a standalone PR):** viewer-class panes (`.liveTranscript`, `.codeViewer`, `.webview`) form one interchangeable *slot* per tab. Content-navigation gestures — command-click on a file link, transcript toggle-on — **replace within the slot** (preserving the pane UUID for view identity and history keying) instead of splitting a new column; explicit split gestures still create panes. This distinguishes *navigate* (replace in slot, push history) from *arrange* (structural intent) and is why "transcript → markdown → back" works.
- **Push points:** any in-place content replacement of a pane — `routeFileClick`'s slot reuse (`ViewerRouting.swift:15`), `toggleTranscript`'s slot navigation, and other `replacingContent(at:with:)` callers; agent-driven replacement joins later with show/render. Splits *create* panes (history starts fresh); closing a pane discards its history (its slot is gone). Terminal panes effectively never accumulate history today — fine.
- **UI:** back/forward chevrons in the viewer pane header (`HeaderFileActions.swift` area), enabled per cursor position. Implemented as SwiftUI `Menu` with `primaryAction` (macOS 26): click = step, long-press/right-click = menu of up to 10 entries labeled by reference (file basename, URL host+path, "Transcript — <tab>"). This avoids the known `.onTapGesture`-blocks-`.contextMenu` trap.
- Back/forward re-applies the entry via the same `replacingContent` path, which itself pushes nothing when navigating (a `isNavigating` reentrancy guard).
- v1 history is **user-facing only**; `panel.list` does not expose stacks (two-way later). The daemon already persists them, so exposing is additive.

## 8. Divider Unification

One component, `PaneDivider(axis:style:commit:)` in `Sources/TBDApp/Terminal/PaneDivider.swift`:

- **Two commit styles**, both today's semantics: `.live(Binding<CGFloat>, min, max)` (file panel, archived list) and `.deferred(preview: …, onCommit: …)` (terminal splits, dock split, dock cells — preserves the "one resize RPC per drag" property the debounce comments demand, `SplitLayoutView.swift:160`).
- **Hover affordance:** the 1 pt separator line thickens to a 3 pt accent-tinted bar on hover (0.12 s fade), 8 pt hit target unchanged; cursor via the existing `CursorRectView` bridge (`SplitLayoutView.swift:248-274`), which exists precisely because `.onHover` push/pop is unreliable under attached gestures. During drag the bar stays highlighted (deferred style keeps its existing accent preview line).
- **Double-click** resets to the split's even ratio (native NSSplitView behavior worth copying; trivial with `onTapGesture(count: 2)` on the divider, which carries no competing context menu).
- Replaces all five call sites; the sidebar stays on native `NavigationSplitView`. No geometry model change — absolute-width and ratio-based callers keep their models; only the divider view unifies.

This section is identical under Approach B — it is orthogonal to the ownership fork.

## 9. Skill Guidance

New section in `TBDSkillContent.body` (`Sources/TBDShared/TBDSkillContent.swift`), after "Pin / unpin a terminal":

```markdown
### See and arrange panels

Each worktree tab is a tree of panels (terminals, file viewers, web views,
transcript, notes). Inspect yours:

    tbd panel list            # tree with short IDs, contents shown as references

Rearrange (requires the user to have enabled panel control in settings):

    tbd panel split a3f2 --right --content code:docs/plan.md   # open a file viewer beside pane a3f2
    tbd panel split a3f2 --below --content transcript          # transcript under your terminal
    tbd panel resize 9c41 --ratio 0.5
    tbd panel close 9c41
    tbd panel select-tab --index 0

Rules:
- Check `tbd panel list` first; prefer reusing/resizing existing panels over
  creating new splits. Don't exceed ~3 panes per tab.
- The layout belongs to the user. Don't close panels you didn't open, and
  don't rearrange unprompted — arrange when asked, or when presenting
  something the user requested.
- Rendering new content (html strings, diffs) is not available yet — only
  files on disk (`code:`), URLs (`web:`), terminals, transcript, notes.
```

The "Discovering current commands" section already tells agents to run `tbd panel --help`, so drift risk is bounded.

## 10. Flag & Rollout

- **Flag:** `config.panel_arrange_enabled`, default **OFF**, added in `v53` (`.defaults(to: false)`). Daemon-side gate in every `panel.*` arrange handler (See handlers ungated). Follows the `control_mode_enabled` / `hibernate_input_veto_enabled` precedent (`Database.swift:796,865`).
- **Enable for soak:** `tbd config set panel-arrange on` (new `config.setPanelArrange` RPC + settings toggle in the app's settings pane, mirroring existing config toggles).
- **Tests both branches** (CLAUDE.md): flag off → arrange RPC returns the gate error and no delta is broadcast; flag on → command flows. See-queries work regardless.
- **Graduation:** ≥2 weeks dogfood with agents actively arranging; then flip the migration default for fresh installs **and** ship a forcing `UPDATE config SET panel_arrange_enabled = 1` migration for existing installs, accepting that an explicit opt-out is indistinguishable from backfill (documented trade; the cautionary `auto_hibernate` precedent is why we ship OFF first). Flag deletion one release later.

## 11. Testing

- **Daemon (`Tests/TBDDaemonTests`):** `v53` migration round-trip; `TabLayoutStore` CRUD + revision-rejection; `panel.syncLayout` persists and completes parked commands (ack correlation, including `failedCommands` NACK); `panel.list` staleness + `appConnected` fields; arrange validation failures (unknown pane, bad ratio, flag off, app not subscribed); timeout path (parked command expires with the re-check error).
- **Shared:** `LayoutNode` moved intact — existing tests move with it; legacy-format decode compat test; `PaneHistory` push/cap/cursor/navigate-no-repush unit tests (pure logic).
- **App-side (logic level):** command application maps each `PanelCommandOp` onto the same mutation functions user gestures call — test via `AppState` with injected `UserDefaults(suiteName:)` per CLAUDE.md; grid-store split (§4.2) regression test: grid layout changes never enter the mirrored store.
- **CLI integration:** socket-level probe (echo JSON to `~/tbd/sock` pattern already used for `pr.list` diagnostics) exercising list → split → list with a fake app subscriber harness.
- **Live verification** (not automated): divider hover affordance and history menu are visual — verify per the transcript-live-verify discipline (screenshot + eyes), since headless harnesses pass green while live rendering is broken.

## 12. Risks & Open Questions

Honest failure modes of the mirror:

1. **App crash between apply and write-back.** A command is applied, the 250 ms debounce hasn't fired, app dies → mirror is stale and the CLI got a timeout. Mitigation: full-state push on next app launch converges the mirror; the timeout error text tells agents to re-run `panel.list`. Residual: a See query in the crash window returns pre-command state, and `stalenessSeconds` does not reveal this (the mirror's last write is recent). Accepted as rare; the ack timeout is the agent's signal that state is uncertain.
2. **Stale mirror with app closed.** `panel.list` serves last-known state with `appConnected: false`. Arrange refuses outright. This is the designed degradation, but agents must be taught (skill text) that `appConnected: false` means "the user isn't looking at this."
3. **Concurrent user drag vs. agent command.** Both mutate the same tree on the main actor, serialized by construction; syncs are whole-tree, so the mirror converges to whatever the app last held. A user drag can land between validation and apply (e.g. user closes the target pane) — the app NACKs with a reason. No locks needed.
4. **Reconciliation prunes agent panes.** `reconcileTerminalTabs` (`AppState.swift:1707-1732`) drops layouts whose terminals died. An agent's split vanishing with its terminal is correct behavior, but the agent only learns via the next `panel.list`. Acceptable for v1.
5. **Delayed writes / reordering.** Monotonic per-tab `revision` + daemon rejection of lower revisions; debounce coalescing makes this near-impossible to hit in practice.
6. **Types-to-TBDShared layering.** `PaneContent.liveTranscript` etc. are UI concepts now visible to the daemon. The daemon treats them as opaque data + validation targets; it must never grow behavior keyed on pane *semantics* (that would be Approach B by accretion). Review guard: daemon code may switch on pane type only inside validation.

Open questions for review:

- Should `panel.selectTab` be arrange-gated? It's the least destructive verb; but it steals the user's visual context, which is exactly what the gesture-free-action rule targets. **Spec says: gated**, revisit at graduation.
- Short-ID stability: short IDs are prefixes of pane UUIDs, stable for a pane's life. Good enough, or should `list` emit ordinal names (`t1`, `v2`)? Prefix chosen for greppability against `--json`.
- Is 3 s the right ack timeout under heavy SwiftUI load (e.g. mid-transcript-stream)? Measure during soak.

## 13. Future Work

- **Show/render (next design):** new content types (render HTML string, markdown scratch content, diffs), reuse-vs-split placement policy, richer targeting ("beside my terminal"), agent-initiated content *replacement* (which then feeds pane history). The `PaneContentSpec` vocabulary and command/ack plumbing built here carry over unchanged.
- **Two-way:** expose pane history and view state (scroll position, visible file region) through `panel.list`; the mirror already persists history, so this is additive daemon work plus app-side view-state capture.
- **Annotations:** user marks on rendered content flowing back to the agent — requires the show/render design plus a content-addressing scheme; the `tab_layout` table's JSON columns are the natural anchor.
- **Migration path to Approach B**, if ever needed: because all mutations already flow through typed command ops and the DB already holds the tree, promoting the daemon to owner is a directional flip of the same protocol, not a rewrite.
