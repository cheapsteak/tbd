# Transcript card rework — header-only rows + click-to-open overlay

**Status:** Approved design, awaiting implementation plan.
**Tracking:** [#129](https://github.com/cheapsteak/tbd/issues/129) (recurring transcript freeze class).
**Date:** 2026-05-23.

## Motivation

The live-transcript pane has accumulated a recurring class of main-thread UI hangs from SwiftUI's layout system measuring variable-height rows inside a `LazyVStack`. The 2026-05-22 hang (35+ seconds, force-quit, transcript of only **71 items**) traced cleanly to the nested `ScrollView` inside a `.frame(maxHeight:)` inside `BashCard` / `WriteCard`. `maxHeight` produces a `_FlexFrameLayout` — a *range* — so SwiftUI must measure the child's ideal size before clamping. The child is a `ScrollView`, whose ideal size is its full content size, so every layout invalidation triggers a full `ScrollViewLayoutComputer.Engine` pass inside each row. The 600 pt cap from PR #137 (`commit 937c1c4`) clamps the *result* but does not stop the *measurement*. This is documented in detail in the issue thread.

Rather than continue capping individual contributors, we remove the structural trap entirely: no transcript row card has *any* inline expanded body, so no row's intrinsic-size computation can become expensive. Long content moves to a click-triggered overlay that lives outside the `LazyVStack` and is therefore free to use a real `ScrollView`.

The redesign also addresses a long-standing UX inconsistency. `ReadCard` / `EditCard` already render plain clipped content with an "Open in viewer" affordance; `BashCard` / `WriteCard` are the outliers with nested scrollers. The chevron-driven expand model is replaced with a uniform "click row → see the full thing in a big panel where the terminal is" model.

## Out of scope

- `AskUserQuestionCard` — interactive, must stay inline.
- `ChatBubbleView` — not an activity row; its rendering is unchanged.
- Any change to `LazyVStack` → `List` migration. Recycling is orthogonal to per-row sizing cost (see issue #129 discussion).
- Long-hover / peek-mode interactions. Explicitly rejected during brainstorming as too easy to trigger accidentally.

## Interaction model

### Row affordance
- The shared `ActivityRowChrome` loses its `expanded: Binding<Bool>` parameter and chevron entirely.
- Each row renders only its existing collapsed header content — one line, no body.
- The entire row is the click target.
- On hover the row background lifts subtly, and a small `⌖` glyph fades in on the trailing edge where the chevron used to sit. The glyph is a passive affordance, not a separate click target — clicking it is equivalent to clicking the row.

### Cards affected
All cards currently using `ActivityRowChrome` lose inline expand. Concretely: `BashCard`, `WriteCard`, `ReadCard`, `EditCard`, `SkillBodyRow`, `GrepCard`, `GlobCard`, `GenericToolCard`, `AgentCard`, `ThinkingRow`, `SystemReminderRow`. Each card's per-row `@State private var expanded` field is removed.

The collapsed header content of each card is unchanged — it's the same one-line summary each card already renders before the user expands. No new copy or formatting is needed.

### Opening, swapping, closing
- **Open**: click any transcript row → overlay opens showing that row's content.
- **Swap**: while an overlay is open, clicking a different row swaps the overlay's content to that row. The overlay stays open.
- **Close**: any of: press `Esc`, click anywhere outside the overlay region (including empty space inside the transcript pane), or click the same row that's currently shown in the overlay.
- At most one overlay is open per window.

### Where the overlay appears
- **Primary**: covers the pane region of the *bound terminal*. Each transcript pane already carries a `terminalID`; the layout tree (`AppState.layouts[tabID]`) is walked to find that terminal's pane node, and the overlay is rendered as a SwiftUI `.overlay` on that pane's view.
- **Fallback**: if the bound terminal is not currently in the visible layout (terminal closed, History pane, single-pane mode, or the transcript pane is not adjacent to any terminal), the overlay falls back to a centered modal panel over the window. Size: ~70 % width × 80 % height, with the same dismiss rules.

### Streaming updates
Overlay content binds to the live transcript-item snapshot in the data store. If the displayed row is still streaming (a running Bash command, a partial assistant message inside an Agent subagent transcript), the overlay re-renders as updates arrive. If the row disappears from the store (e.g., a subagent transcript reset), the overlay closes gracefully.

## Overlay content

Each overlay has three regions, top to bottom:

1. **Header bar**: row icon, the same one-line label the collapsed row shows, timestamp, and a trailing `✕` close button. For nested `AgentCard` overlays, the header also shows a leading `←` back affordance when a back-frame is available (see *AgentCard recursion* below).
2. **Body**: a straight reuse of each card's existing expanded-body rendering — monospace text for Bash / Write / Read, syntax-highlighted diff hunks for Edit, the nested `TranscriptItemsView` for Agent, and so on. The body is **unbounded**: no `maxHeight`, hosted inside its own real `ScrollView`. Safe here because the overlay is *not* a row in a `LazyVStack` — there is no `_FlexFrameLayout` measure-then-clamp trap to fall into.
3. **Footer affordances**: existing per-card affordances survive — `PreviewFileButton`, `TruncationFooter` for daemon-fetch of un-truncated content. They render inline beneath the body inside the overlay.

### AgentCard recursion
Clicking an `AgentCard` row opens an overlay rendering the subagent's nested `TranscriptItemsView`. The rows inside the overlay are themselves header-only and click-to-overlay. Clicking one of those nested rows pushes the current overlay onto a single-frame back-stack and swaps overlay content to the nested row.

The back-stack is one frame deep — sufficient to support "drill into a subagent's tool call, return to the subagent's transcript." Going deeper than that is supported by repeated clicking (each step replacing the back-frame), but the user can never go back more than one step. Deep recursion is not a stated user need; we revisit if it becomes one.

## Architecture

### State location
A new per-window `TranscriptOverlayCoordinator`, exposed via `AppState` (or a sibling observable owned at the same lifetime). Holds at most one active overlay:

```swift
struct OverlayRequest {
    let terminalID: UUID            // the transcript's bound terminal
    let itemID: String              // the transcript item to show
    let parentFrame: OverlayRequest? // one-deep back-stack, AgentCard only
}

@Published var openOverlay: OverlayRequest?
```

### Open / swap / close
Transcript cards receive a `@Environment(\.openTranscriptOverlay)` closure of type `(TranscriptItem) -> Void`, injected by the transcript pane (which knows its own `terminalID`). The card's row click handler calls it. The closure mutates `coordinator.openOverlay`. Swap is the same call with a different item; the coordinator detects same-item and clears (close), different-item and replaces (swap).

Esc and click-outside dismissals: handled by a transparent click-catcher rendered behind the overlay view itself, plus a key-equivalent on the overlay's containing view for `Esc`. Both call `coordinator.openOverlay = nil`.

### Rendering
Two render sites subscribe to the coordinator:

1. **Terminal panes**: every `PanePlaceholder.terminal(...)` rendering attaches a `.overlay { … }` that returns the overlay view if `coordinator.openOverlay?.terminalID == this terminal's id` *and* the bound transcript pane is in the window. Otherwise it renders nothing.
2. **Window root** (in `ContentView`'s detail area): a fallback `.overlay { … }` that renders the centered modal panel when `coordinator.openOverlay != nil` *and* no terminal pane in the visible layout matches. A small helper on `LayoutNode` returns the set of currently-rendered terminal IDs; the fallback renders only when the open overlay's `terminalID` is absent from that set.

This split means each terminal pane only pays for its own overlay state, and the fallback path is consulted only when no terminal renders the overlay.

### Removed code
- `ActivityRowChrome.expanded: Binding<Bool>` and the chevron button. The header `Button(action: { expanded.toggle() })` becomes a `Button(action: openOverlay)` with no visible chevron, plus an `.onHover` for the trailing `⌖` glyph reveal.
- `TranscriptCardLayout.expandedMaxHeight` / `collapsedMaxHeight` — unused after the rework. Delete with the rest.
- Per-card `@State private var expanded`, `containerExpanded`, `commandContainerExpanded` declarations.
- The two nested `ScrollView`s in `BashCard` (command + result) and the one in `WriteCard`. Body content is moved into the overlay's rendering.

## Edge cases and decisions

- **No bound terminal visible** → centered modal fallback. Same dismiss rules apply.
- **History pane** (session no longer live) → falls into the no-bound-terminal path; centered modal.
- **Window resized while overlay open** → overlay tracks the terminal pane's bounds because it's a SwiftUI `.overlay` on that pane; resizes correctly. Centered modal resizes with the window root.
- **Terminal closed while overlay open** → the `.overlay` on that terminal pane disappears with the pane; the coordinator state becomes orphaned. Next render cycle: window-root fallback picks it up and shows the centered modal until dismissed.
- **Click on the `⌖` glyph specifically** → same behavior as click on row; no separate handler needed.
- **Text selection in row headers** → unchanged from today (the header is already a `Button`; text inside is not user-selectable). Selecting the full content of a row is what the overlay is for.
- **Live transcript scroll auto-bottom** while overlay is open → unaffected; the overlay holds its own item reference and does not move when the transcript autoscrolls.
- **Click-outside that lands on another transcript row** → counts as a row click (swap), not as an outside click (close). Implementation note: the click-outside catcher should not extend over transcript rows themselves.

## Enforcement (separately tracked)

This redesign closes the current `BashCard` / `WriteCard` nested-`ScrollView` trap. To prevent its return, a `CLAUDE.md` is added at `Sources/TBDApp/Panes/Transcript/` documenting the rule: transcript row cards must not have a direct `ScrollView` child. A custom SwiftLint rule mirroring the existing `no_print_in_sources` pattern is proposed as a follow-up. Both are tracked alongside the implementation work for #129.

## Migration

A single PR. The change is breaking for every card using `ActivityRowChrome`, so all card edits happen in the same commit. Order:

1. Introduce `TranscriptOverlayCoordinator` and the overlay view, behind no flag (it's UI-only and replaces the existing expand path).
2. Remove `ActivityRowChrome.expanded` and the chevron; switch the header `Button` to invoke the overlay-open closure.
3. Update each affected card to drop its `expanded` state, drop its inline body, and (where applicable) hand its existing body-renderer to the overlay as the per-card overlay body.
4. Delete `TranscriptCardLayout.expandedMaxHeight` / `collapsedMaxHeight`.
5. Wire the two render sites: terminal-pane `.overlay` and window-root fallback `.overlay`.
6. Add `Sources/TBDApp/Panes/Transcript/CLAUDE.md` documenting the no-nested-`ScrollView` rule.

## Testing

- **Hang regression**: load a transcript of ≥100 items in a worktree, observe `MainThreadSampler` for ≥10 s with no captured hang at all. The structural fix removes the trap; this is a longitudinal observation, not a deterministic check.
- **Per-card snapshot**: each affected card type (one per: Bash, Write, Read, Edit, Skill, Grep, Glob, GenericTool, Agent, Thinking, SystemReminder) renders correctly in collapsed form and opens its overlay on click.
- **Overlay region**: with transcript right of terminal, overlay appears over the terminal; flip the layout (split-down or transcript-on-left) and re-verify; verify fallback in History pane and with a single-pane layout.
- **Dismiss**: Esc closes, click outside closes, click same row closes; click different row swaps.
- **Streaming**: open an overlay over a running Bash command; observe new output appended live.
- **AgentCard recursion**: click an agent row, click a nested tool row inside the overlay, verify back-button returns to the subagent view; clicking deeper does not lose the user.
- **Branch coverage** (per `CLAUDE.md`): every removed `expanded`-binding branch in `ActivityRowChrome` is gone — confirmed by no remaining call sites passing the binding.

## Files changed (anticipated)

- `Sources/TBDApp/Panes/Transcript/ActivityRowChrome.swift` — drop chevron + binding, add hover-`⌖` glyph, switch header `Button` to overlay-open closure.
- `Sources/TBDApp/Panes/Transcript/BashCard.swift` — drop nested scrollers, drop expand state, hand body renderer to overlay.
- `Sources/TBDApp/Panes/Transcript/WriteCard.swift` — same.
- `Sources/TBDApp/Panes/Transcript/ReadCard.swift`, `EditCard.swift`, `SkillBodyRow.swift`, `GrepCard.swift`, `GlobCard.swift`, `GenericToolCard.swift`, `AgentCard.swift`, `ThinkingRow.swift`, `SystemReminderRow.swift` — drop expand state, hand body renderer to overlay.
- `Sources/TBDApp/Panes/Transcript/TranscriptCardLayout.swift` — delete.
- New: `Sources/TBDApp/Panes/Transcript/TranscriptOverlayCoordinator.swift` and `TranscriptOverlayView.swift` (names indicative).
- `Sources/TBDApp/AppState.swift` (or sibling) — expose coordinator.
- `Sources/TBDApp/Terminal/PanePlaceholder.swift` — attach `.overlay` to terminal pane render.
- `Sources/TBDApp/ContentView.swift` — attach window-root fallback `.overlay`.
- New: `Sources/TBDApp/Panes/Transcript/CLAUDE.md` — the no-nested-`ScrollView` enforcement note.
