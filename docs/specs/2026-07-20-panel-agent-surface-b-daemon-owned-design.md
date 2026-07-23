# Panel Agent Surface — Approach B: Daemon-Owned Panel State

**Date:** 2026-07-20
**Status:** Draft for review (competing spec: `2026-07-20-panel-agent-surface-a-mirror-design.md`)
**Approach:** The daemon database becomes the single source of truth for the pane tree. The app is a renderer of subscribed state; every mutation — user click, divider drag, agent command — is a daemon RPC.

## 1. Context & Goals

TBD agents currently have no way to see or control the panel layout of their worktree. The bundled `tbd` skill (`Sources/TBDShared/TBDSkillContent.swift`) never mentions panels; the only UI levers an agent has are `tbd notify` and `tbd terminal focus`. Meanwhile the app already has a real pane model — `PaneContent` + a recursive `LayoutNode` split tree — but it lives entirely in `TBDApp`, persisted as a UserDefaults JSON blob the daemon never sees.

Goals of this design:

- **See** — an agent can query which panels exist in its worktree, their split arrangement, and what each renders (references only: file paths, URLs, terminal IDs — never rendered contents).
- **Arrange** — an agent can split, close, resize, move panes, and switch tabs, through the same semantics the user's clicks use.
- **Per-panel history** — every pane slot remembers its last ~10 contents; users navigate back/forward from the pane header.
- **Unify** the five copy-pasted divider implementations into one component with a native-feeling hover affordance.
- Establish the state architecture that later supports two-way interaction (agent reads view state; user annotations on content).

Non-goals for v1: rendering new content types ("show this HTML/markdown" — deferred to a separate design), reading rendered contents, annotations.

## 2. Current State

Anchored summary; full detail in the research notes.

- **Model (good):** `PaneContent` — five cases: `.terminal(terminalID)`, `.webview(id:url:)`, `.codeViewer(id:path:)`, `.note(noteID)`, `.liveTranscript(id:terminalID:)` (`Sources/TBDApp/Terminal/PaneContent.swift:5`). `Tab` wraps one primary `PaneContent` (`PaneContent.swift:25`). `LayoutNode` is a recursive `.pane`/`.split(direction:children:ratios:)` tree with helpers (`splitPane`, `removePane`, `replacingContent(at:with:)`) and a backward-compatible hand-written Codable (`Sources/TBDApp/Terminal/LayoutNode.swift:12,192`).
- **State & persistence (split-brained):** `AppState.layouts: [UUID: LayoutNode]` with `didSet { persistLayouts() }` to a UserDefaults blob (`Sources/TBDApp/AppState.swift:401,878-887`). Tab labels/order/active tab live in the daemon DB (`tab` table + `worktree.tabOrder`/`activeTabID`, migrations `v19`/`v20`, `Sources/TBDDaemon/Database/Database.swift:433-449`). The daemon has no knowledge of the pane tree.
- **Dual keying (footgun):** `layouts` is keyed by `tab.id` in the single-worktree path (`Sources/TBDApp/Terminal/TerminalContainerView.swift:268-269`) and by `worktreeID` in the multi-worktree grid (`TerminalContainerView.swift:572-576`) — one dictionary, two semantics.
- **Mutation paths:** no central API. Splits/closes happen by rebinding `layout` inside `PanePlaceholder` (`splitRight` `:523`, `createTerminalSplit` `:546`, `routeFileClick` via `Sources/TBDApp/Panes/ViewerRouting.swift:15`, `toggleTranscript` via `Sources/TBDApp/Panes/TranscriptRouting.swift:21`). Tab ops in `Sources/TBDApp/AppState+Tabs.swift`. Tab existence is re-derived by reconciliation against live terminals (`reconcileTerminalTabs`, `AppState.swift:1704-1748`), which also prunes panes whose terminals died (`removingTerminalPanes(notIn:)`).
- **Resize:** five hand-rolled `DragGesture` dividers (file panel `ContentView.swift:672-694`, terminal splits `SplitLayoutView.swift:161-233`, dock split `TerminalContainerView.swift:605-668`, dock cells `PinnedTerminalDock.swift:50-100`, archived list `ArchivedWorktreesView.swift:203-218`). Terminal-adjacent dividers deliberately defer commit to release because live resize fires tmux resize RPCs (debounced ~100ms, `TerminalPanelView.swift:1009-1049`).
- **History:** none for panes. Only sidebar selection history (`AppState+Navigation.swift`).
- **Transcript:** `.liveTranscript` is already an ordinary pane; the toolbar toggle and pane routing share `isLiveTranscriptPane` (`TranscriptRouting.swift:10`) so the trigger already reflects visibility. (The unrelated History *mode* and click-to-zoom overlay are out of scope.)

## 3. Decisions

Fixed inputs to this design (settled during brainstorming; identical in both competing specs):

1. v1 agent verbs are **See** (layout + content references) and **Arrange** (split, close, resize, move, switch tabs). **Show/render is deferred** to a separate future design; v1 introduces no new content types.
2. Agent-created splits may hold any *existing* pane type: terminal (new or existing), live transcript, code viewer on a path, webview on a URL, note.
3. The transcript is a panel like any other — no special-casing, no protection. The toolbar transcript trigger reflects visibility (dark when no transcript pane): already implemented via the shared `isLiveTranscriptPane` check; no change required beyond keeping that invariant when mutations move server-side.
4. Two-way interaction (agent reads view state; user annotations) is the future direction; v1 ships one-way arrange plus reference/layout queries only.
5. Per-panel history: last 10 contents per pane slot; back/forward buttons in the pane header; right-click shows a dropdown of entries; survives restart.
6. Agent operations are scoped to the agent's own worktree by default (`TBD_WORKTREE_ID`); cross-worktree requires explicit `--worktree`.
7. One shared divider component with hover affordance and the existing `CursorRectView` cursor bridge; deferred-commit preserved for terminal panes. Not NSSplitView.
8. Edge cleanups in scope: the dual-keyed `layouts` dictionary; dead split stubs (`AppState+Worktrees.swift:1012-1034`). Out of scope: `Tab.content` redundancy, transcript overlay/History-mode sprawl.

## 4. Architecture

### 4.1 Ownership

The daemon owns the pane tree per `(worktreeID, tabID)`. The app holds a local replica and renders from it. All mutations are expressed as **semantic operations** sent to the daemon:

```
splitPane(tabID, targetPaneID, direction, newContent)
closePane(tabID, paneID)
setRatios(tabID, splitPath, ratios)
replaceContent(tabID, paneID, newContent)   // also drives history
movePane(tabID, paneID, toTargetPaneID, direction)
setActiveTab(worktreeID, tabID)             // exists today as worktree.setActiveTab
```

The daemon applies the operation to its stored tree, bumps a per-tab version, persists, appends to history where applicable, and broadcasts a `layoutChanged` StateDelta carrying the full new tree + version for that tab. Both the app and (indirectly) CLI queries observe the same authoritative state. Whole-tree *writes* from clients are rejected by design — semantic ops are the only mutation interface — so two concurrent editors (user + agent) interleave at operation granularity instead of clobbering each other's trees. The one exception is the one-time UserDefaults import (§5.4) and a `layout.set` escape hatch used only by the migration/import path, not exposed in the CLI.

### 4.2 Interactivity: optimistic apply + version reconcile

The render loop must never wait on a socket. Protocol:

1. App performs the mutation **locally first** (same pure `LayoutNode` helpers as today), tags it with a client-generated `opID`, renders immediately.
2. App sends the semantic op (with `opID` and the base version it applied against) to the daemon.
3. Daemon applies against its authoritative tree. If the base version matches, result is identical to the app's optimistic state; the echoed `layoutChanged(tree, version, opID)` is a no-op for the originating app (it recognizes its own `opID` and just adopts the version).
4. If versions diverge (an agent op landed between the app's read and write), the daemon still applies the semantic op to the *current* tree (semantic ops compose: split-by-target-pane, close-by-paneID, ratios-by-split-path all address stable IDs). The echo's tree differs from the optimistic one; the app replaces its replica with the echo. Because ops address pane IDs rather than indices, the common races (agent closes pane X while user splits pane Y) merge correctly; a genuinely conflicting op (both target the same pane) resolves in daemon arrival order — last writer wins at op granularity, and the user sees the merged result within one round-trip (~1ms on a Unix socket).
5. **Divider drags never stream.** During drag the divider shows the existing preview indicator (deferred-commit behavior, `SplitLayoutView.swift:160`); exactly one `setRatios` op is sent on release. Ratio previews are pure local view state. This matches today's behavior and keeps 60fps with zero socket traffic mid-drag.

`replaceContent`-class churn from user clicks (e.g. `routeFileClick` swapping a code-viewer path per click) follows the same path — one op per click is well within budget.

### 4.3 Structural stability guarantee

The known failure class is terminal-destroying re-renders: swapping the container structure kills SwiftTerm views and their tmux sessions (comment at `TerminalContainerView.swift` on `DockSplitView`; the `routeFileClick` pane-ID-preserving swap exists for the same reason, `ViewerRouting.swift`). Therefore the app **never rebuilds its replica wholesale while healthy**: echoes that match the optimistic state are ignored; divergent echoes are applied by *diffing pane IDs* (panes present in both survive with identity intact; only added/removed panes mount/unmount). This diff-apply is the riskiest new code in Approach B and gets dedicated tests (§11).

### 4.4 Failure modes

- **Daemon down / socket error:** the app keeps mutating its local replica and queues unsent ops (bounded, coalescing ratio ops). On reconnect it replays the queue; if the daemon's version moved meanwhile (it can't have — only the app and CLI mutate, and the CLI requires the daemon — but crash-recovery skew can), the app performs one full-tree `layout.set` reconcile guarded by the migration escape hatch. Layout editing is never blocked by daemon absence.
- **User drag races agent op:** handled by §4.2 step 4; worst case the user's ratio commit applies to a tree where the target split vanished — the daemon rejects with a stale-target error, the app drops the op and adopts the echo. No crash, no zombie state.
- **App crash mid-apply:** daemon state is authoritative and durable; on relaunch the app loads trees via `layout.get` and reconciliation prunes dead terminals (§5.3). Nothing depends on the app having acked.
- **Two app instances:** already disallowed by the single-app model (LaunchServices/one-daemon); not designed for.

## 5. Data Model & Persistence

### 5.1 Model relocation

`PaneContent`, `Tab`, `SplitDirection`, `LayoutNode` move from `Sources/TBDApp/Terminal/` to `Sources/TBDShared/` (the daemon must decode and manipulate them). The hand-written backward-compatible Codable (`LayoutNode.swift:192`, legacy `{"type":"terminal"}` format) moves with it unchanged — the DB rows and the UserDefaults import both flow through it. App-only rendering helpers stay behind in TBDApp as extensions.

This also resolves the dual-keying cleanup: the daemon schema forces the key to be `(worktreeID, tabID)`; the multi-worktree grid's `layouts[worktreeID]` hack (`TerminalContainerView.swift:572-576`) is rewritten against the same keyed store with an explicit synthetic tab, not a UUID pun.

### 5.2 Schema (migration `v53_pane_layouts`)

```sql
CREATE TABLE pane_layout (
    worktreeID TEXT NOT NULL,
    tabID      TEXT NOT NULL,
    tree       TEXT NOT NULL,   -- LayoutNode JSON (existing Codable)
    version    INTEGER NOT NULL DEFAULT 0,
    updatedAt  DATETIME NOT NULL,
    PRIMARY KEY (worktreeID, tabID)
);
CREATE TABLE pane_history (
    worktreeID TEXT NOT NULL,
    tabID      TEXT NOT NULL,
    paneID     TEXT NOT NULL,
    position   INTEGER NOT NULL,        -- 0 = newest
    content    TEXT NOT NULL,           -- PaneContent JSON
    replacedAt DATETIME NOT NULL,
    PRIMARY KEY (worktreeID, tabID, paneID, position)
);
```

Per the three-place rule (CLAUDE.md): migration in `Database.swift`, GRDB record types (`PaneLayoutStore.swift`), and Codable models in `TBDShared/Models.swift` (the moved `LayoutNode`/`PaneContent` serve as the models; new fields optional/defaulted) — one commit. `tree` stays a JSON blob *per tab* (not per-pane rows): the tree is small (<2KB), always read/written whole, and the semantic-op merge happens in Swift, not SQL. History is row-per-entry because it's append/trim and queried per-pane.

Config flags (same migration): `config.agent_arrange_enabled` default **0**, `config.daemon_layout_enabled` default **0** (§10).

### 5.3 Reconciliation moves daemon-side (genuine advantage)

Today `reconcileTerminalTabs` (`AppState.swift:1704-1748`) prunes panes whose terminals died — app-side, on app timelines, and only while the app runs. Under B, the daemon owns both the layout **and** the terminal lifecycle (it creates/destroys terminals), so pruning becomes an internal daemon consequence: terminal removal → prune `.terminal`/`.liveTranscript` panes referencing it across stored trees → broadcast `layoutChanged`. The app's reconciliation shrinks to tab-list presentation. This closes a real hole: layouts stay consistent even when terminals die while the app is closed (today the blob goes stale and is patched at next launch).

### 5.4 One-time import

On first app launch with `daemon_layout_enabled`, the app decodes the existing UserDefaults blob (`AppState.swift:882-887`), pairs entries with known tabs, and pushes them via the `layout.set` import path; the daemon accepts only rows it has no entry for. The blob is left in place (rollback safety) and ignored thereafter; deleted in a later release.

## 6. RPC & CLI Surface

### 6.1 RPC methods (`RPCProtocol.swift`, naming per existing `noun.verb` convention)

| Method | Params → Result | Notes |
|---|---|---|
| `layout.get` | worktreeID, tabID? → trees + versions (+ optional history heads) | See; app relaunch load |
| `layout.split` | tabID, targetPaneID, direction, newContent, opID?, baseVersion? → tree, version | newContent restricted to existing `PaneContent` cases; `terminal` may be `new` (daemon spawns via existing terminal-create path) or an existing terminalID |
| `layout.close` | tabID, paneID, opID?, baseVersion? → tree, version | auto-unwraps single-child splits (existing `removePane` semantics) |
| `layout.setRatios` | tabID, splitPath, ratios, … → tree, version | one op per drag release |
| `layout.replaceContent` | tabID, paneID, newContent, … → tree, version | pushes old content to history |
| `layout.move` | tabID, paneID, targetPaneID, direction, … → tree, version | |
| `layout.historyGet` / `layout.historyNavigate` | paneID (+offset) → entries / tree | §7 |
| `layout.set` | worktreeID, tabID, tree | import/reconcile escape hatch; not in CLI |

New StateDelta: `case layoutChanged(LayoutDelta)` — worktreeID, tabID, tree, version, originOpID?, plus `case paneHistoryChanged(PaneHistoryDelta)`. Wire-up follows the standard six-step RPC recipe (skill §"Adding New RPC Methods").

Agent calls are validated: worktree scoping (params must match the caller's `TBD_WORKTREE_ID` unless `--worktree` given), `agent_arrange_enabled` flag gate on all mutating methods when the caller is a CLI session (the app's own calls bypass the flag), content-type allowlist (reject unknown/future `PaneContent`).

### 6.2 CLI (`tbd panel …`, new `Sources/TBDCLI/Commands/Panel.swift`)

```
tbd panel list   [--worktree <id>] [--json]     # tabs + tree + references per pane
tbd panel split  --pane <paneID> --direction right|down
                 --content terminal|transcript|file:<path>|url:<url>|note [--terminal <id>]
tbd panel close  --pane <paneID>
tbd panel resize --split <splitPath> --ratios 0.6,0.4
tbd panel move   --pane <paneID> --target <paneID> --direction right|down
tbd panel tab    --activate <tabID>
tbd panel history --pane <paneID> [--back|--forward|--go <n>]
```

`panel list` output (JSON) is the See contract: per tab — id, label, active; tree of `{split, direction, ratios, children}` / `{pane, id, type, ref}` where `ref` is the file path, URL, terminal ID, or transcript's terminal ID. Never contents. Human-readable default output is an indented tree.

Because the daemon is the source of truth, `panel list` needs no app round-trip and is correct even while the app is closed; mutations equally apply daemon-side and render whenever the app is (re)attached — CLI results are real acks (the RPC response carries the post-op tree), not eventual-consistency reads.

## 7. Panel History

**Viewer-slot navigation (ships ahead of this spec as a standalone app-side PR):** viewer-class panes (`.liveTranscript`, `.codeViewer`, `.webview`) form one interchangeable *slot* per tab; content-navigation gestures (command-click on a file link, transcript toggle-on) replace within the slot — preserving the pane UUID — instead of splitting a new column. Explicit splits remain structural. Under B, those replacements become `replaceContent` ops.

History is keyed by stable `paneID` (which `routeFileClick` already deliberately preserves across content swaps, `ViewerRouting.swift`). On every `replaceContent` (user click or agent op), the daemon prepends the outgoing `PaneContent` to `pane_history`, trims to 10, broadcasts `paneHistoryChanged`. Back/forward are `layout.historyNavigate` calls that atomically swap current content with the history entry (forward stack maintained by position sign or a cursor column — implementation detail for the plan).

UI: pane headers gain back/forward buttons (enabled per history availability); right-click (or long-press) on either button shows an `NSMenu` of up to 10 entries labeled by reference (filename, URL host+path, "Terminal ⌗", "Transcript"). Selecting jumps directly.

Daemon-side history is the architectural freebie of Approach B: durable across app restarts by construction, no extra sync, and later queryable by agents ("what was this pane showing before") without new plumbing. Close-pane discards history for that paneID (panes are slots; a closed slot is gone — revisit if users ask for "reopen closed pane").

## 8. Divider Unification

One `PaneDivider` component (new file, `Sources/TBDApp/Terminal/PaneDivider.swift`) replacing the five implementations:

- Configurable axis, hit-target width (8pt), min/max constraint (absolute or ratio), and commit mode: `.live` (file panel, archived list) or `.deferred` (all terminal-adjacent dividers — preview indicator during drag, commit on release; rationale comments preserved).
- Hover affordance: on hover (and during drag) the 1pt separator line animates to a 3pt accent-tinted bar — approximating NSSplitView's divider feedback; plus the existing `CursorRectView` cursor bridge (`SplitLayoutView.swift:237-274`), kept because `.onHover` push/pop is unreliable under attached gestures (comment at `:238-240`).
- Double-click resets to the ideal/default width or 50:50 ratio (native splitter convention).
- Under B, `.deferred` commit for layout-tree dividers emits `layout.setRatios`; `.live` dividers (file panel width — not part of the pane tree) keep their `@AppStorage` binding. The component is agnostic: it takes a commit closure.

The sidebar stays on `NavigationSplitView` (already native). `MainAreaSizeKey` measurement points (`TerminalContainerView.swift:19,202,489,549`) are untouched — `PaneDivider` is a drop-in at existing positions in the view tree.

## 9. Skill Guidance

New section in `TBDSkillContent.body` (after "Pin / unpin a terminal"):

```markdown
### See and arrange the panel layout

Each worktree tab is a tree of panels (terminals, transcript, file viewer,
web view, notes). You can inspect and rearrange it:

    tbd panel list --json          # tabs, split tree, and what each panel shows
                                   # (references only: paths, URLs, terminal ids)
    tbd panel split --pane <id> --direction right --content file:docs/plan.md
    tbd panel close --pane <id>
    tbd panel resize --split <path> --ratios 0.7,0.3

Guidelines:
- Check `panel list` before arranging — respect the user's current layout;
  prefer splitting your own terminal's pane over rearranging others.
- The transcript is a normal panel; don't close it unless asked.
- Every panel keeps back/forward history, so replacements are recoverable —
  but don't rely on the user to undo your changes.
- Requires the "agent panel control" setting; if commands fail with
  "disabled", tell the user to enable it in TBD settings.
```

(Exact copy finalized in the implementation plan; the skill already documents discovery via `tbd --help`.)

## 10. Flag & Rollout

Two independent flags, per the CLAUDE.md default-off policy:

1. **`daemon_layout_enabled`** (config column, default 0) — gates the ownership move itself. This wholesale-replaces a load-bearing path (layout state/persistence), squarely inside the flag policy. OFF: app keeps today's UserDefaults path; daemon tables exist but idle. ON: import runs, app switches to replica+ops. Soak on the developer's install; graduate by flipping via forcing `UPDATE` migration (per the `auto_hibernate` lesson), then delete the UserDefaults path a release later.
2. **`agent_arrange_enabled`** (config column, default 0) — gates CLI/agent *mutations* only (`panel list` See queries are always allowed; read-only). Requires `daemon_layout_enabled`. Graduates independently once arrange semantics have soaked.

Both branches tested (CLAUDE.md branching-conditional rule). Rollout order: land schema + store + RPC (inert) → land app replica path behind flag 1 → dogfood → enable flag 2 → skill section ships with flag 2's graduation.

**Honest phasing note for reviewers:** Phase "schema + store + RPC + app dual-writes while still authoritative" is, almost verbatim, the whole of Approach A. Approach B is not an alternative to A so much as A **plus** an ownership inversion at the end. If B is chosen, the de-risked path still builds A first and then flips authority; the real decision is whether to commit now to the second step (and its diff-apply/optimistic-echo machinery) or defer it until two-way features demand it.

## 11. Testing

- **LayoutNode op semantics (TBDShared):** pure-function tests for split/close/move/setRatios/replaceContent against ID-addressed trees, including stale-target rejection and single-child unwrap. Property test: any op sequence yields a valid tree (ratios sum ~1, no empty splits).
- **Daemon store (TBDDaemonTests, in-memory GRDB):** versioning, history append/trim/navigate, terminal-death pruning across stored trees, import-only-when-absent, both flag branches (mutations rejected when `agent_arrange_enabled=0`; UserDefaults path untouched when `daemon_layout_enabled=0`).
- **Optimistic-echo reconcile (app-side unit):** own-op echo is a no-op; divergent echo diff-apply preserves pane identity for surviving panes (assert same object identity via pane-ID diff output, the §4.3 guarantee); queued-op replay after simulated disconnect.
- **RPC integration:** CLI-shaped calls through the router with `TBD_HOME` isolation; worktree-scope enforcement; content-type allowlist rejection.
- **Divider component:** commit-mode behavior (deferred emits exactly one op per drag), constraint clamping. Visual hover affordance verified live (per project precedent, layout/visual issues are live-only — screenshot pass in the PR).
- Tests must not touch `~/tbd` (`TBD_HOME` seams) and reuse `TmuxManager(dryRun:)` where terminal spawns are implied.

## 12. Risks & Open Questions

- **Diff-apply replica updates (highest risk).** Getting pane-identity-preserving echo application wrong destroys terminal views (the documented failure class). Mitigation: §4.3 tests + the flag; but this machinery does not exist today and is the bulk of B's app-side cost.
- **Rewrite surface.** All layout mutation sites (`PanePlaceholder`, `ViewerRouting`, `TranscriptRouting`, `AppState+Tabs`, reconciliation ~`AppState.swift:1700-1780`, multi-worktree grid) move from direct binding writes to op-emission; the five divider sites are touched twice (unification + op plumbing). Estimated 2–3× the diff of Approach A for the same v1 feature set.
- **Two sources of truth during the soak.** While `daemon_layout_enabled` is off for some installs and on for others, bugs bifurcate by flag state; support burden until graduation.
- **Op granularity of `setRatios` addressing (`splitPath`).** Split nodes have no stable IDs today; path-addressing is fragile under concurrent structural edits. Open question: add stable IDs to `.split` nodes (Codable change, still backward-compatible via the custom decoder) — recommended, decide in the plan.
- **Terminal spawn inside `layout.split --content terminal:new`.** Composing terminal creation (async, session instrumentation) with a layout op needs care to avoid a pane referencing a terminal that failed to spawn. Likely: spawn first, then split referencing the concrete ID; the CLI does this in two RPCs under the hood.
- **Note panes** are worktree-scoped app constructs (`AppState+Notes.swift`); verify note creation via agent op doesn't need extra daemon knowledge.
- Does the multi-worktree grid get real tabs (synthetic tab row) or stay a special case reading a single tree? Leaning synthetic tab; decide in the plan.

## 13. Future Work

- **Show/render (deferred design):** new content types — rendered HTML strings, diffs, richer markdown targets — arrive as new `PaneContent` cases; under B they slot in with zero new sync work (one enum case + renderer + allowlist entry).
- **Two-way:** agent queries of view state (scroll position, selection) and eventually user **annotations** on content. B's daemon-owned store is the natural home: annotations become rows keyed by (paneID, content ref), agents read them via `layout.get` extensions.
- **Pane-content read-back** (agent reads what a panel displays) — explicitly out of scope until the show/render design lands.
- Migrating the three sanctioned TUI scrapers and the transcript overlay/History-mode sprawl remain independent tracks.
