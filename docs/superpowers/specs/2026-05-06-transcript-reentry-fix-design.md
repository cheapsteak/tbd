# Transcript re-entry: spurious autoscroll + missing realize-poke

## Problem

After commit `2d79df7` switched to `.scrollPosition(id: $visibleID, anchor: .bottom)`, two symptoms appear on tab navigation:

1. **Gray blank panel** on re-entry, until the user scrolls. The lazy stack hasn't realized rows around the bound `visibleID`.
2. **Scrolling up snaps back to the bottom** — the user's scroll position is overwritten on every re-entry, before they can read older messages.

## Root cause (single mechanism, two faces)

When the user navigates away from the transcript tab, the active terminal pointer changes briefly. Two computed properties fall out:

```swift
private var currentSessionID: String? {
    terminal?.claudeSessionID  // → nil briefly during nav
}

private var messages: [TranscriptItem] {
    guard let sid = currentSessionID else { return [] }  // → [] briefly
    return appState.sessionTranscripts[sid] ?? []
}
```

Concretely:

- During tab leave: `currentSessionID` → nil → `messages` → `[]` → `messages.last?.id` → `nil`.
- On return: `currentSessionID` becomes non-nil → `messages` repopulates → `messages.last?.id` → `"id720"` (or whatever the latest ID is).
- `.onChange(of: messages.last?.id)` fires for the `nil → "id720"` transition. The handler treats this as a new-message event and fires `withAnimation { visibleID = "id720" }`. **That's symptom 2** — the autoscroll forced by what's actually a navigation artifact, not a real new message.
- Separately, even if `visibleID` retained the user's previous (non-bottom) value across navigation, `.scrollPosition(id:)` does not always force `LazyVStack` to realize rows around the bound position when the view re-appears. **That's symptom 1** — blank panel until the user scrolls (which itself triggers realization).

The two symptoms compound: you get the blank gray, and the moment SwiftUI re-evaluates the body and the spurious `.onChange` fires, you also get yanked to the bottom.

## Fix

Two surgical changes — keep the `.scrollPosition(id:)` binding (it's sound for tracking and restoration), and harden both ends.

### A. Guard `.onChange` against nil → value transitions

A real new message always transitions `valueA → valueB`. The `nil → value` case is the navigation artifact. Skip it.

```swift
.onChange(of: messages.last?.id) { oldID, newID in
    guard let oldID, let id = newID, autoscrollEnabled else { return }
    withAnimation(.easeOut(duration: 0.15)) {
        visibleID = id
    }
}
```

The `guard let oldID` is the load-bearing change. With it, the handler ignores `nil → "id720"` (navigation return) but still fires for `"id719" → "id720"` (genuine new message during streaming) and `"id720" → "id721"` (Claude continuing to emit).

### B. Add a realize-poke on `.onAppear`

Reintroduce `ScrollViewReader { proxy in ... }`. On `.onAppear`, call `proxy.scrollTo(visibleID, anchor: .bottom)` — scrolling to the ID that's *already* anchored at the bottom. Position is unchanged; the call functions as a re-layout signal that prompts `LazyVStack` to realize rows around the bound position.

```swift
ScrollViewReader { proxy in
    ScrollView {
        TranscriptItemsView(items: messages, terminalID: terminalID)
    }
    .defaultScrollAnchor(.bottom)
    .scrollPosition(id: $visibleID, anchor: .bottom)
    .onAppear {
        Self.perfLog.debug("view.appear sid=\(short, privacy: .public) count=\(messages.count, privacy: .public)")
        if let id = visibleID {
            proxy.scrollTo(id, anchor: .bottom)
        }
    }
    .onChange(of: messages.last?.id) { oldID, newID in
        guard let oldID, let id = newID, autoscrollEnabled else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            visibleID = id
        }
    }
}
```

Guard with `if let id = visibleID` — on the very first appearance (before any poll), `visibleID` is nil and `.defaultScrollAnchor(.bottom)` handles initial position. Poking with a nil ID would be a no-op at best, undefined at worst.

### Same fix in HistoryPaneView

Apply the realize-poke (B) in the SessionDetailView's `.onAppear` — wrap the `ScrollView` in a `ScrollViewReader` and add the same guarded `proxy.scrollTo(visibleID, anchor: .bottom)`. No `.onChange` exists there (read-only), so the guard from (A) is not relevant.

## Why this is right and not another guess

- (A) is correct semantics. The autoscroll handler should fire on *content arriving*, not on the array temporarily emptying and refilling because of view-tree state churn during navigation. We exposed the latent bug by introducing the binding; the binding isn't broken — the handler always had this hole, it just hadn't mattered before.
- (B) is the documented fallback from `2026-05-06-transcript-scroll-position-design.md`'s risk section. We're not inventing it — we're confirming empirically that the binding alone doesn't poke realization on re-appear.

## Out of scope

- The deeper question of *why* `messages` briefly becomes empty during navigation. That's an `AppState` invariant problem (the session-transcript dictionary is preserved, but `currentSessionID` can transiently report nil while the worktree/terminal pointer churns). A real fix would be to make `currentSessionID` more stable across navigation, but that's a different kind of change and not load-bearing for the perf/UX problem we're solving here. Flagging as a follow-up if other symptoms appear.
- The "freeze autoscroll when user scrolls up" feature (still hardcoded `autoscrollEnabled = true`). Same TODO as before.

## Verification (visual; user-driven)

The `perf-transcript` log stream still tells us first-paint stays fast.

1. Open the maven-dashboard transcript: pins to bottom on first paint.
2. Scroll up to read older messages.
3. Switch to another tab.
4. Switch back: **scroll position preserved**, content visible immediately (no blank, no jump-to-bottom).
5. (If active session) New message arrives: snaps to bottom (existing autoscroll behavior).
6. History pane re-entry: select a session, scroll up, switch sessions, switch back — position preserved.

If the binding still misbehaves on re-entry, the next investigation point is `currentSessionID` stability (the deeper root cause noted above), not further SwiftUI scroll fiddling.

## Suggested commit shape

One commit:

```
fix: ignore nil→value last-id transitions and poke lazy stack on re-entry

Tab navigation briefly nils out currentSessionID, which made
messages.last?.id flip nil→value on return. .onChange treated that
as a new message and snapped the user back to the bottom. Guard the
handler against nil→value (real new messages always go value→value).

Re-introduce ScrollViewReader and call proxy.scrollTo(visibleID) on
.onAppear — scrolling to the already-anchored id is a position no-op
but a re-layout signal that prompts LazyVStack to realize the rows
around the bound position, fixing the blank gray panel on re-entry.

Same realize-poke applied in HistoryPaneView for symmetry.
```
