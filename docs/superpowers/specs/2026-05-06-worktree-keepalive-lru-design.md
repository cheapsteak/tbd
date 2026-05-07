# Worktree-level keep-alive with LRU

## Problem

Two recurring SwiftUI bugs we've spent days fighting both have the same root cause: `LiveTranscriptPaneView` is unmounted and re-mounted on worktree navigation, and SwiftUI's `LazyVStack` doesn't recover gracefully from the re-mount.

**Bug 1 — scroll position lost on navigate-back.** User scrolls up to read older messages, navigates to another worktree, navigates back, and lands at the bottom because the view's `@State` (including any scroll-position bookkeeping) died with the unmount.

**Bug 2 — blank pane on revisit, only fills when user scrolls.** Same mechanism: re-mount happens, `defaultScrollAnchor(.bottom)` positions the new viewport at the content bottom, but `LazyVStack` fails to realize rows for that viewport in the new instance. Active scrolling eventually wakes the realization machinery up; until then the user sees blank.

We've gone through five+ iterations trying to fix these bugs from inside `LiveTranscriptPaneView`: scroll-position bindings, sentinel anchors, deferred scrolls, opacity gates, position save/restore via per-row tracking. Each fix either fails or introduces a worse bug. The view-instance lifecycle is at the heart of every failure.

## Goal

Eliminate the unmount/re-mount entirely for the user's recently-visited worktrees. If the SwiftUI view instance survives, both bugs become impossible — `@State` (scroll position, atBottom) persists, `LazyVStack` keeps its realized rows, and switching worktrees is a pure visibility toggle.

## Non-goals

- Not changing how transcripts are loaded, parsed, or polled.
- Not introducing new state that would survive across full app restarts.
- Not fixing every SwiftUI re-mount issue in TBD; only the worktree-switching path.

## Approach

Replace the existing `Group { switch on selectedWorktreeIDs }` in `TerminalContainerView.mainContent` with a `ZStack` that holds the *N most recently visited* `SingleWorktreeView` instances simultaneously. Only the currently-selected worktree's view is opaque and accepts hit-testing; the rest are invisible but kept alive (with their child views, including `LiveTranscriptPaneView`, retained).

When a worktree is visited that isn't already in the keep-alive set, it gets prepended; when the set exceeds the cap, the oldest entry is evicted (which causes that worktree's view to unmount — same behavior as today, but only for worktrees the user hasn't touched in a while).

The codebase already uses this exact preservation pattern in two places. `TerminalContainerView.swift:76-80` has a comment explaining why the `DockSplitView` is always rendered ("destroys all terminal views, killing their tmux sessions"). `ContentView.swift:51-60` overlays `ConductorOverlayView` with `.opacity(...)` / `.allowsHitTesting(...)`. So this isn't novel architecture — it's idiomatic for TBD.

## Cap

**`keepAliveLimit = 8`.**

Reasoning:
- A typical TBD session has 3–8 active worktrees the user alternates between.
- Worst-case memory per kept-alive worktree is ~50–200MB (full tab bar + multi-pane split + scrolled-through long transcript). At 8 × 200MB = 1.6GB — high but bounded. On a 36GB Mac, fine. On 8GB, the OS will start paging the cold ones, which is acceptable for non-active worktrees.
- Realistic memory is much lower because most kept-alive worktrees only have the bottom screenful of their transcripts realized (the user opens the pane, sees the latest, navigates away — only ~10 rows realized).
- Easy to tune later if 8 is wrong. It's a constant, not a config.

## State changes

### `AppState`

```swift
/// Worktree IDs whose view trees we keep alive past their selection,
/// most-recent-first. Cap: keepAliveLimit. Older worktrees get evicted
/// (their SingleWorktreeView unmounts) when the cap is exceeded.
@Published private(set) var recentlyVisitedWorktreeIDs: [UUID] = []

private let keepAliveLimit = 8

/// Move `id` to the front of recentlyVisitedWorktreeIDs, evicting the
/// oldest entries if we exceed keepAliveLimit. Idempotent — calling
/// repeatedly with the same id only updates ordering.
func touchVisitedWorktree(_ id: UUID) {
    recentlyVisitedWorktreeIDs.removeAll { $0 == id }
    recentlyVisitedWorktreeIDs.insert(id, at: 0)
    if recentlyVisitedWorktreeIDs.count > keepAliveLimit {
        recentlyVisitedWorktreeIDs.removeLast(
            recentlyVisitedWorktreeIDs.count - keepAliveLimit
        )
    }
}
```

Place it near the other transcript-related properties in `AppState.swift` (the area that already had `sessionTranscripts`).

### Hook into selection changes

`ContentView.swift:183` already has `.onChange(of: appState.selectedWorktreeIDs)`. Add a call to `touchVisitedWorktree` for the single-selection case:

```swift
.onChange(of: appState.selectedWorktreeIDs) { _, newSelection in
    // ... existing logic ...
    if newSelection.count == 1, let id = newSelection.first {
        appState.touchVisitedWorktree(id)
    }
}
```

Multi-select case: do nothing; multi-select uses `MultiWorktreeView`, which is out of scope for this change.

### Initial population

When the app first launches and the saved worktree selection is restored, the `.onChange` may not fire (depends on whether the initial selection is set after the view is observing). Belt-and-suspenders: also add a `.onAppear` on `ContentView` (or a `.task`) that touches the currently-selected worktree if any. Verify by reading the existing `selectedWorktreeIDs.didSet` in `AppState.swift:30`.

## TerminalContainerView changes

Replace the existing `mainContent` `Group { if/else }` (`TerminalContainerView.swift:54-64`):

```swift
let mainContent = Group {
    if appState.selectedWorktreeIDs.count == 1,
       let worktreeID = appState.selectedWorktreeIDs.first {
        SingleWorktreeView(worktreeID: worktreeID)
    } else if appState.selectedWorktreeIDs.count > 1 {
        MultiWorktreeView(worktreeIDs: appState.selectionOrder)
    } else {
        Text("Select a worktree or click + to create one")
            .foregroundStyle(.secondary)
    }
}
```

Becomes:

```swift
let activeWorktreeID = appState.selectedWorktreeIDs.count == 1
    ? appState.selectedWorktreeIDs.first
    : nil

let mainContent = Group {
    if appState.selectedWorktreeIDs.count > 1 {
        // Multi-select bypasses keep-alive: existing behavior preserved.
        MultiWorktreeView(worktreeIDs: appState.selectionOrder)
    } else if appState.selectedWorktreeIDs.isEmpty {
        Text("Select a worktree or click + to create one")
            .foregroundStyle(.secondary)
    } else {
        // Single-select: render all kept-alive worktrees in a ZStack,
        // gated by opacity + hit-testing. Only the active one is visible
        // and interactive; the rest stay mounted to preserve LazyVStack
        // realization, scroll position, terminal state, etc.
        ZStack {
            ForEach(appState.recentlyVisitedWorktreeIDs, id: \.self) { id in
                SingleWorktreeView(worktreeID: id)
                    .opacity(id == activeWorktreeID ? 1 : 0)
                    .allowsHitTesting(id == activeWorktreeID)
            }
        }
    }
}
```

A subtle point: the active worktree must be in `recentlyVisitedWorktreeIDs` for the ZStack to render it. The `touchVisitedWorktree` call from the `.onChange` handler ensures this — but if the `ZStack` evaluates *before* the `.onChange` runs (e.g., on the very first selection at app launch), the active worktree might be missing for a frame. Mitigations:
- The `touchVisitedWorktree` call from `selectedWorktreeIDs.didSet` (in `AppState.swift`) is synchronous, so the array is updated before any view body re-evaluates that observes `recentlyVisitedWorktreeIDs`.
- Belt-and-suspenders: in the ZStack body, if `activeWorktreeID` exists but isn't in `recentlyVisitedWorktreeIDs`, fall back to rendering it directly:
  ```swift
  ZStack {
      ForEach(appState.recentlyVisitedWorktreeIDs, id: \.self) { id in ... }
      if let id = activeWorktreeID, !appState.recentlyVisitedWorktreeIDs.contains(id) {
          SingleWorktreeView(worktreeID: id)
      }
  }
  ```

The `.onPreferenceChange(MainAreaSizeKey.self)` modifier on `mainContent` stays as-is — it observes whichever child's GeometryReader is currently visible.

## What survives, what doesn't

Survives across worktree switches:
- `LiveTranscriptPaneView`'s `@State` (atBottom, perf-log dedup, etc.) and `@State` of every SwiftUI view inside the kept-alive subtree.
- `LazyVStack`'s realized row windows.
- Tab bar selection within each worktree.
- File panel state, code viewer state, terminal scrollback.
- Any `.task(id:)` polling continues to run on hidden worktrees (see "Polling cost" below).

Does NOT survive:
- Worktrees evicted past the LRU cap (revert to current mount-on-visit behavior).
- App restart (kept-alive set is in-memory only).

## Polling cost

`LiveTranscriptPaneView`'s `.task(id: TaskKey)` runs while the view is mounted. In keep-alive mode, that means polling continues for *all* kept-alive worktrees, not just the active one. For 8 worktrees with one transcript pane each, that's ~5.3 RPC calls/sec on the daemon.

For typical session sizes (200–500 items, 100–500KB JSONL), each parse is ~10–20ms. Total ongoing daemon CPU: ~5%. Tolerable.

For pathological sessions like maven-dashboard's 5MB / 720-item file, parse is ~200ms. Eight of those concurrent = 1.6s of CPU per 1.5s poll cycle, which would saturate the daemon. In practice, users don't have eight 5MB sessions concurrently — but it's a real failure mode worth knowing about.

If polling cost shows up as a problem, the fix is to gate polling on visibility:

```swift
@State private var isVisible = false

.task(id: TaskKey(...)) {
    while !Task.isCancelled {
        if isVisible { await pollOnce() }
        try? await Task.sleep(...)
    }
}
.onAppear { isVisible = true }
.onDisappear { isVisible = false }
```

But `.onAppear` / `.onDisappear` semantics on opacity-gated views are not well-defined in SwiftUI. They may not fire on opacity changes. Empirically determine: if it doesn't fire, we'd need a different visibility signal (e.g., a binding from the parent based on `id == activeWorktreeID`).

**This is a follow-up if needed, not part of the initial change.** Ship without polling-pause, observe daemon CPU under realistic load, then decide.

## Risks

1. **`MainAreaSizeKey` confusion.** With multiple `SingleWorktreeView`s in a ZStack, multiple `GeometryReader`s emit preferences. The current `.onPreferenceChange` reads the last-emitted value. Need to verify only the active worktree's geometry is broadcast, or add a check (`id == activeWorktreeID`) inside the geometry reader.
2. **One-shot UI elements that should re-trigger on visit** — e.g., a "new messages while you were away" badge that uses `.onAppear` to reset. With the view kept alive, `.onAppear` won't fire on revisit. Audit the existing subtree for such cases. Off the top of my head, none come to mind in `LiveTranscriptPaneView` or `PanePlaceholder`, but worth a grep for `.onAppear` inside the subtree.
3. **Memory creep on long sessions.** A user who runs TBD for hours and visits many worktrees deeply will eventually hit the keep-alive cap, but the cap is bounded so the worst case is bounded. Still, if a single kept-alive worktree's transcript balloons (e.g., a session that grows to 10k items over hours), each kept-alive entry's high-water mark increases too. LazyVStack doesn't evict, so this is monotonically increasing. Consider as future work: per-worktree teardown trigger when the worktree's session grows past some threshold.
4. **Conductor overlay interaction.** `ConductorOverlayView` (already an opacity-gated overlay on the worktree subtree) is layered above mainContent. With a kept-alive ZStack underneath, its layout proposals are still bounded by the active worktree's content. Should be fine. Verify visually.
5. **Multi-select still mounts/unmounts.** The bypass for `selectedWorktreeIDs.count > 1` keeps current behavior. Acceptable.

## Verification

1. `swift build` — clean.
2. `./scripts/restart.sh`.
3. **Bug 2 test (the canonical repro):**
   a. Visit the maven-dashboard worktree (with a 720-item transcript) — confirm it lands at the bottom, content visible.
   b. Switch to a different worktree.
   c. Switch back. Content should be visible immediately. **No blank-then-scroll-to-render.**
   d. The `perf-transcript` log should show only ONE `view.appear sid=6ae5` (from the original mount), not two. The remount has been eliminated.
4. **Bug 1 test:**
   a. Visit any transcript, scroll up to mid-content, note position.
   b. Switch worktrees, switch back.
   c. Scroll position is preserved.
5. **LRU eviction test:**
   a. Visit ≥10 distinct worktrees in some order, then return to the first one visited. It should mount fresh (was evicted), behaving like today's mount-on-visit (lands at bottom, no preserved state).
6. **Polling-cost sanity check:**
   a. With 8 kept-alive worktrees, watch `top` for daemon CPU. Should stay under ~10%. If it spikes higher, we've hit the polling-cost edge case and need to gate polling on visibility.

## Out of scope (deferred follow-ups)

- Visibility-gated polling for kept-alive worktrees (cf. "Polling cost" above).
- Per-worktree memory-pressure teardown (cf. risk #3).
- Multi-select keep-alive (`MultiWorktreeView` path).
- Generalizing the LRU pattern to other parts of TBD that may benefit from view preservation.
- Cleaning up `perf-transcript` instrumentation now that the bug it was diagnosing is gone (decide after this lands).

## Suggested commit shape

One commit:

```
fix: keep recently-visited worktree views alive to preserve transcript state

Both the scroll-position-loss bug and the blank-on-remount bug had
the same root cause: LiveTranscriptPaneView was unmounted on
worktree navigation, taking @State and LazyVStack realization with
it. Five+ iterations of fixes from inside the view kept failing
because the view-instance lifecycle was the actual problem.

Replace the worktree switch in TerminalContainerView with a ZStack
that holds the N most recently visited SingleWorktreeViews,
gated by opacity + allowsHitTesting. The active worktree is opaque
and interactive; the rest stay mounted to preserve their full state
(transcript scroll position, LazyVStack rows, terminal scrollback,
file panel, etc).

LRU cap of 8 worktrees in AppState.recentlyVisitedWorktreeIDs.
Touched on every selection change. Older entries evict back to
mount-on-visit, matching today's behavior for cold worktrees.

The opacity-gated keep-alive pattern is already idiomatic in TBD
(see DockSplitView and ConductorOverlayView).

Polling cost is not gated on visibility in this change. With 8
kept-alive worktrees that's ~5 RPC/sec sustained on the daemon —
fine for typical sessions; flagged for follow-up if pathological
sessions saturate it.
```
