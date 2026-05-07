# Transcript-pane render fix: LazyVStack + bottom anchor

## Problem (measured)

Switching to a Claude transcript with hundreds of items freezes the app for multiple seconds; switching away freezes it again as the heavy view tree tears down. Instrumentation captured under `perf-transcript` (commits `b13befa` + `0780b3c`) gave a clean timeline for a 720-item maven-dashboard session:

```
parse.end       elapsed_ms=243  items=720  bytes=4_784_928
pollOnce.end    elapsed_ms=611  changed=true count=720
items.body      count=720                     ← ForEach starts dispatching
view.appear     count=720                     ← first paint, ≈7000ms later
```

Daemon parse, RPC, decode, and main-actor swap together cost < 700ms. The remaining ~7 seconds is **SwiftUI eagerly realizing every child view of `TranscriptItemsView`** because its container is `VStack`, not `LazyVStack`. Each row is a non-trivial composition: `ChatBubbleView` instantiates MarkdownUI, tool cards decode JSON and run syntax highlighting. 720 of those built synchronously on the main actor blocks the UI.

The same view tree also costs ~7 seconds to tear down on tab leave (observed as a `pollOnce` that took 10920ms because its `MainActor.run` continuation couldn't run while teardown was in flight).

For a 205-item session the equivalent gap is ~530ms — annoying but tolerable. The behavior is super-linear in item count, so longer sessions (the unfiltered `511161cd-…jsonl` has 2372 raw lines) would be much worse.

## Goal

Cut `items.body → view.appear` from seconds to under 100ms regardless of session length, and cut tab-leave teardown to a similarly small fixed cost.

Out of scope:

- Daemon parse caching, incremental fetch, or RPC pagination (T2/T3/T4 from the earlier brainstorm). The data path is already fast enough; the bottleneck is render.
- Per-card decoder caching (T6) and deferred markdown parse (T7). With lazy realization, only visible rows render — these tail wins are no longer load-bearing.
- Any change to the polling cadence or RPC protocol.

## Why an earlier "just use LazyVStack" attempt would have failed

`ScrollViewReader.proxy.scrollTo(lastID, anchor: .bottom)` inside `.onAppear` defeats `LazyVStack`. To resolve the layout offset of the target row, the lazy stack must realize every row from the current scroll position to the target. On initial appearance the current position is 0; the target is the last item; result: the lazy stack realizes everything anyway. Same cost as a non-lazy `VStack`.

The fix needs both halves: `LazyVStack` *and* an initial-position mechanism that doesn't force realization.

## Approach

Three coordinated changes, all in app-side SwiftUI code. Daemon untouched.

1. **`Sources/TBDApp/Panes/Transcript/TranscriptItemsView.swift`** — replace the outer `VStack(alignment: .leading, spacing: 4)` (line 40) with `LazyVStack(alignment: .leading, spacing: 4)`, and add `.scrollTargetLayout()` immediately after the closing brace. `.scrollTargetLayout()` is what tells SwiftUI's scroll machinery that each lazy child is an individually addressable scroll target — without it `proxy.scrollTo(id:)` becomes flaky against lazy content.

   The inner `VStack` (line 77) inside the `.toolCall` branch stays as-is. That's a tiny per-row grouping wrapper, not the long list.

   The recursive `TranscriptItemsView` invocation inside `SubagentDisclosure` becomes lazy too. Subagent timelines live inside a `DisclosureGroup` that's collapsed by default, so the lazy realization is fine — the disclosure controls visibility, the lazy stack controls realization.

2. **`Sources/TBDApp/Panes/LiveTranscriptPaneView.swift`** — add `.defaultScrollAnchor(.bottom)` to the outer `ScrollView` (after line 105). Remove the `.onAppear { if let id = messages.last?.id { proxy.scrollTo(id, anchor: .bottom) } }` block (lines 112–114) — `defaultScrollAnchor(.bottom)` provides the same initial-bottom behavior without forcing whole-stack realization. Keep the `.onChange(of: messages.last?.id) { ... proxy.scrollTo(id, anchor: .bottom) ... }` block — autoscroll on new messages still uses `proxy.scrollTo`, and that's fine because by the time a new message arrives the bottom of the stack is already realized (we're parked there).

3. **`Sources/TBDApp/Panes/HistoryPaneView.swift`** — add `.defaultScrollAnchor(.bottom)` to the `ScrollView` at line 341 (the one wrapping `TranscriptItemsView`). No `proxy.scrollTo` to remove there; HistoryPaneView's transcript view is read-only and never had autoscroll.

That's the entire fix — three file edits, ~5 line-of-code net. Targets macOS 15 (already the project's `.macOS(.v15)` minimum); both `LazyVStack` (macOS 12+) and `defaultScrollAnchor(.bottom)` (macOS 14+) are well within scope.

## Why `.defaultScrollAnchor(.bottom)` works for chat semantics

The modifier was introduced in WWDC 2024 specifically with chat-style views in mind. It positions the initial viewport at the bottom of the content and *also* keeps the bottom in view as content grows from the bottom — which is exactly Claude transcripts streaming in. When the user scrolls up manually, the effective anchor releases until the user returns to the bottom. The existing `autoscrollEnabled` state machine in `LiveTranscriptPaneView` becomes mostly redundant, but we leave it in place — it's small, gated by a TODO comment for the deferred "freeze autoscroll on manual scroll-up" feature, and removing it would be unrelated cleanup.

## Behavioral preserves

- Initial appearance: bottom of the transcript visible immediately, regardless of session length.
- Streaming new messages: still snaps to bottom (existing `.onChange(of: messages.last?.id)` autoscroll).
- Manual scroll up: stays where the user put it (default scroll-anchor releases on user gesture).
- `textSelection(.enabled)` per row: untouched.
- `SubagentDisclosure` expand/collapse: untouched.
- The 1.5s polling cadence and RPC protocol: untouched.

## Risks

- **Row-height jumping during scroll-up.** Lazy stacks compute row heights as rows realize, so the scroll-bar thumb may jump as the user scrolls into previously-unrealized regions. Tool cards (especially `EditCard` with diffs) have wildly variable heights. Acceptable visual cost for the perf win; mitigation if it's egregious is to add a `.frame(minHeight: 60)` on each row dispatch (a coarse stable estimate). Not doing this preemptively.
- **`defaultScrollAnchor(.bottom)` interaction with empty initial state.** When `messages.isEmpty`, we render `emptyState`, not `transcriptWithAutoscroll`. So the modifier only applies once content exists. No empty-state regression.
- **Recursive `TranscriptItemsView` lazy stack inside a disclosure.** Should be fine — when collapsed the outer disclosure clips visibility, when expanded the inner lazy stack realizes only what's visible inside the disclosure's clip rect. Will verify visually after build.

## Verification

Same `perf-transcript` instrumentation used to diagnose stays in place — it's the regression detector.

1. `swift build` — clean.
2. `./scripts/restart.sh` — worktree-relative.
3. With `log config` already activated, stream `category == "perf-transcript"`.
4. Repro the maven-dashboard tab open (terminal `AD7D`, sid `6ae5`, count=720).
5. **Success criterion**: timestamp delta between `items.body terminalID=AD7D count=720` and `view.appear sid=6ae5 count=720` is < 200ms (10× safety margin over the 100ms target).
6. **Tab-leave success criterion**: the next `pollOnce.end` for the leaving sid has `elapsed_ms < 300` (down from 10920).
7. Visual: scroll up in the long transcript and confirm rows realize without jank; scroll back down and confirm autoscroll still snaps when a new message arrives (test in an active session, or by sending a poke to Claude).
8. Visual on small session (sid=808F or similar, ~200 items): regression check — first paint should be even faster, no behavior change.

## Cleanup of the perf instrumentation

Decision: **keep** the `perf-transcript` logs in place at `.debug` level. Rationale:

- They're silent by default (`debug` level requires explicit `log config` activation per `docs/diagnostics-strategy.md`). Zero cost in normal runs.
- They were the reason this fix landed correctly. Future render regressions in the transcript pane will show up in the same timeline.
- Demoting to `.trace` would also work but `.debug` aligns better with the project's existing convention for per-feature diagnostics.

If the project later wants to be more aggressive about pruning unused diagnostics, that's a separate cleanup pass.

## Suggested commit shape

One commit:

```
fix: lazy realize transcript rows so long sessions don't freeze the UI

Swap the eager VStack in TranscriptItemsView for LazyVStack + a
scroll-target layout, and let defaultScrollAnchor(.bottom) handle
initial bottom-positioning instead of proxy.scrollTo(lastID), which
would have forced full realization anyway. Result: items.body →
view.appear drops from ~7s to under 100ms on a 720-item session;
tab-leave teardown drops similarly because there's no longer a giant
view tree to deallocate.

The perf-transcript instrumentation introduced for this diagnosis
stays in place at .debug level so the same timeline catches future
regressions.
```
