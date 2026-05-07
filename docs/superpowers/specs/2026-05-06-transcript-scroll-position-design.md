# Preserve transcript scroll position across navigation

## Problem

After the LazyVStack render fix (`04dedf9`), re-entering a transcript tab left the panel blank until the user scrolled — LazyVStack didn't re-realize visible rows because `.defaultScrollAnchor(.bottom)` only fires on initial appearance. The follow-up (`ef377d4`) added `proxy.scrollTo(messages.last?.id, anchor: .bottom)` inside `.onAppear` to poke the lazy stack on re-entry. That fixed the blank panel, but it stomps the user's scroll position: every re-entry snaps to the bottom, even when the user was reading older messages.

The two issues are coupled: poking LazyVStack to realize rows requires *something* to act on the scroll system, but `proxy.scrollTo` always changes position. We need a primitive that re-realizes without moving.

## Three behaviors that must coexist

1. **First entry to a transcript** → position at the bottom (latest content).
2. **Re-entry after navigating away** → preserve the user's scroll position; rows realize immediately without a manual scroll gesture.
3. **New message arrives during a poll** → if user was at the bottom, follow; if scrolled up, stay put. (Today the code is hardcoded to always follow — preserved as-is in this fix; see "Out of scope" below.)

## Approach: `.scrollPosition(id:)` binding

macOS 14 introduced `.scrollPosition(id: $binding, anchor: .bottom)`. It does three things at once:

- **Tracks** which scroll-target row sits at the anchor edge of the viewport. As the user scrolls, SwiftUI updates the binding for free.
- **Restores** position when the view re-appears, because `@State` for the binding survives across navigations. SwiftUI uses the binding's current value to re-anchor on re-mount/re-appear, and the lazy stack realizes the rows around it.
- **Drives** programmatic scrolling: setting the binding moves the viewport (animated when wrapped in `withAnimation`).

This subsumes both `proxy.scrollTo` and the manual `.onAppear` poke. We get position preservation, re-entry rendering, and autoscroll through a single mechanism.

## Concrete edits

### `Sources/TBDApp/Panes/LiveTranscriptPaneView.swift`

Within the view's stored state (top of the struct), add:

```swift
/// Tracks the row at the bottom edge of the visible viewport. Drives both
/// re-entry restoration (SwiftUI re-anchors here when the view re-appears)
/// and autoscroll (set this to messages.last?.id to follow new messages).
@State private var visibleID: String?
```

In `transcriptWithAutoscroll`:

- Apply `.scrollPosition(id: $visibleID, anchor: .bottom)` to the `ScrollView`. Place it after `.defaultScrollAnchor(.bottom)` and before `.onAppear` (modifier order: `.defaultScrollAnchor` provides the first-paint default when `visibleID` is nil; `.scrollPosition(id:)` takes over once the binding is set).
- Remove the `if let id = messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }` line inside `.onAppear` (added in `ef377d4`). Keep the `Self.perfLog.debug("view.appear ...")` line — that instrumentation stays.
- Replace the body of `.onChange(of: messages.last?.id) { _, newID in ... proxy.scrollTo(id, anchor: .bottom) ... }` with:

  ```swift
  .onChange(of: messages.last?.id) { _, newID in
      guard autoscrollEnabled, let id = newID else { return }
      withAnimation(.easeOut(duration: 0.15)) {
          visibleID = id
      }
  }
  ```

  Same animation, same gating, same effect — driven by the binding instead of the proxy.

- After both `proxy.scrollTo` callers are gone, the `ScrollViewReader { proxy in ... }` wrapper is dead weight. Drop it. The `ScrollView` becomes the outer container directly.

  Verify before removing: search this file for any remaining reference to `proxy`. There should be none after the two removals above. If there are, leave the wrapper.

### `Sources/TBDApp/Panes/HistoryPaneView.swift`

Same pattern, simpler, in the SessionDetailView (around line 341):

- Add `@State private var visibleID: String?` to that view's state.
- Apply `.scrollPosition(id: $visibleID, anchor: .bottom)` after `.defaultScrollAnchor(.bottom)` on the `ScrollView`.

No `.onChange` needed — HistoryPaneView is read-only for closed sessions, no autoscroll on new messages.

This applies the same fix proactively. Without it, navigating between session entries in the history list and returning would have the same scroll-position-stomp + blank-panel issues on a session that's been previously viewed.

## Why `defaultScrollAnchor(.bottom)` stays

When `visibleID` is still `nil` (e.g., view first appears before any poll has populated `messages`, or messages are empty), `.scrollPosition(id:)` has nothing to anchor to. Apple's documented behavior: an unmatched ID is a no-op. `.defaultScrollAnchor(.bottom)` provides the fallback initial position. Once messages populate and the user scrolls (or autoscroll fires), the binding takes over.

## Why removing the proxy doesn't break autoscroll

`.scrollPosition(id:)` is a two-way binding. Setting it programmatically (in the `.onChange` block above) scrolls the viewport to that ID with the requested animation. SwiftUI handles the layout and lazy realization. The semantics are identical to `proxy.scrollTo(id:anchor:)` for our purposes.

## Edge cases

- **Empty messages on first entry**: `visibleID` is nil. `.defaultScrollAnchor(.bottom)` positions at bottom of empty content (no-op visually). When poll completes and `messages` populates, `messages.last?.id` is non-nil and `.onChange` fires once: `visibleID` becomes the last ID, snap-to-bottom animation runs (visually equivalent to landing at the bottom from a fresh state).
- **User scrolls to top, leaves, returns**: `visibleID` is the first message's ID. SwiftUI re-anchors there on re-entry. Lazy stack realizes the top rows. Position preserved.
- **Poll updates messages without changing the last ID** (e.g., daemon re-emitted same data, or only sidechain content changed): `.onChange(of: messages.last?.id)` doesn't fire, no autoscroll. Position stays.
- **Tab is closed and reopened from scratch** (e.g., user closed the transcript sidebar entirely and reopened): the view is fully re-mounted, `@State` resets, `visibleID` is nil → `.defaultScrollAnchor(.bottom)` positions at bottom. First-entry behavior, as expected.

## Out of scope

- The "freeze autoscroll when user scrolls up" feature — the `autoscrollEnabled` state is still hardcoded `true` per the existing TODO comment at `LiveTranscriptPaneView.swift:24-27`. With `.scrollPosition(id:)` now in place, this becomes a clean follow-up: gate `autoscrollEnabled` based on whether `visibleID == messages.last?.id`. Not doing it here — keep the patch focused on the position-preservation regression.
- HistoryPaneView's parent state machine (which session is selected, etc.). We're only touching the `ScrollView` chain inside the detail view.
- Performance instrumentation. The `perf-transcript` logs from `b13befa`/`0780b3c` stay as-is; they continue to verify first-paint stays fast through this change.

## Risks

- **`.scrollPosition(id:)` interaction with `.defaultScrollAnchor`**: a brief tussle on the very first poll-completion (where `messages` becomes non-empty and `.onChange` first sets `visibleID`). Should resolve cleanly to "at bottom" via the animated set. If a flicker is observable, we can dispatch the initial set without animation — but try the clean version first.
- **Binding re-fires on rapid poll updates**: if `messages.last?.id` flips quickly (unlikely but possible during streaming), `withAnimation` might queue redundant scrolls. Acceptable — same risk existed with `proxy.scrollTo` and didn't manifest in practice.
- **Worst-case fallback**: if the binding misbehaves on re-entry (e.g., SwiftUI doesn't actually realize rows around the bound ID without an explicit scrollTo), keep the `ScrollViewReader` and add `proxy.scrollTo(visibleID, anchor: .bottom)` as a guarded poke inside `.onAppear` — only when `visibleID != nil`. This poke would scroll-to-self, which is a no-op for position but still triggers re-layout. We try the clean version first.

## Verification (visual; user-driven)

The `perf-transcript` log stream provides the perf regression test (`items.body → view.appear` should remain < 200ms). Visual checks the user must run:

1. Open the maven-dashboard transcript: pins to bottom on first paint.
2. Scroll up to read older messages.
3. Switch to another tab.
4. Switch back: scroll position preserved; content visible immediately (no blank, no jump-to-bottom).
5. (Active session only) Send a new message in the terminal: snaps to bottom (existing autoscroll behavior).
6. Open the History pane on a worktree, select a session, scroll up. Select a different session, then back. The previously-viewed session should preserve its scroll position too.

## Suggested commit shape

One commit:

```
fix: preserve transcript scroll position across navigation

The LazyVStack render fix and its re-entry follow-up forced an
unconditional snap-to-bottom on every .onAppear, which fixed the
blank-panel-on-return issue but stomped the user's scroll position.
Switch to .scrollPosition(id: $visibleID, anchor: .bottom) — a
two-way binding that tracks the visible row, restores it on re-entry
(realizing the lazy rows around it as a side effect), and drives
programmatic autoscroll on new messages. The proxy.scrollTo callers
go away; ScrollViewReader becomes dead weight and is removed.

Apply the same scroll-position binding in HistoryPaneView so
session-detail re-entry preserves position consistently.
```
