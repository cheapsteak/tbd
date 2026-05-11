# Decision brief: transcript pane — fix LazyVStack in place, or migrate to List?

**Date:** 2026-05-11
**Author:** Claude (investigating issue cheapsteak/tbd#129)
**Audience:** Reviewers (other LLMs / humans) being asked to give a second opinion.

This brief is self-contained. Read it cold; you don't need any other repo context.

## TL;DR

We have a recurring class of main-thread UI hangs (sub-second to 17s) in the SwiftUI transcript pane on macOS 15. Five rounds of incremental fixes have each closed one specific stack signature; a new one then appears. We're now deciding between three paths:

- **A. Migrate `ScrollView { LazyVStack { ForEach } }` → `List { ForEach }`** (structural fix).
- **B. One more LazyVStack rescue experiment** (homogenize ForEach body + `@Observable` + `.equatable()`).
- **C. B as a timeboxed experiment, then A if it doesn't move the needle.**

Looking for an outside read on whether the rescue experiment (B) is worth a day or whether we should commit to the migration (A) now.

## The problem

`TranscriptItemsView` (`Sources/TBDApp/Panes/Transcript/TranscriptItemsView.swift`) renders an ordered list of transcript items inside a `ScrollView { LazyVStack { ForEach } }`. Items are heterogeneous — user prompts, assistant chat bubbles (MarkdownUI), and ~9 kinds of tool-call cards (Bash, Write, Read, Edit, Grep, Glob, Agent, AskUserQuestion, Generic). Some tool-call rows can also contain a nested `SubagentDisclosure` that, when expanded, recursively renders another `TranscriptItemsView` (depth-capped at 8).

Symptom: recurring 1–17s main-thread hangs during layout/scroll. Sometimes captured by the macOS hang reporter; sometimes only by our own `HangWatchdog`. The bug class persists across fixes — each fix removes one specific signature, a new signature appears.

## What's already been tried (do not re-suggest)

| PR / commit | Fix | Status |
|---|---|---|
| `a41f716` (#120) | Gated `.textSelection(.enabled)` on hover via env latch (was 17s storm). | Shipped. |
| `2da779c` | Hoisted ScrollView out of recursive TranscriptItemsView calls. | Shipped. |
| `5e10ba8` | `HangWatchdog` ships hang-detection telemetry. | Shipped. |
| `29348d3` | Deferred `onPreferenceChange` writes to avoid reentrant layout. | Shipped. |
| `3fa2cc6` | Persist NSHostingView in expanding row panel to break layout-update loop. | Shipped. |
| `dd6c1cf` | Capped daemon body to 20 lines initial. | Shipped. |
| `937c1c4` (#130) | Capped `BashCard` / `WriteCard` inner ScrollView heights at 600pt (was `.infinity`). | Shipped today (2026-05-11). |
| — | Tightened HangWatchdog threshold 1500ms → 1000ms. | Shipped. |
| — | Removed `.scrollTargetLayout()` from transcript code. | Already done. |

## Today's evidence (post-PR-#130 hang)

A 1.20s main-thread hang was sampled by macOS at 2026-05-11 12:18 (`/Users/chang/projects/tbd/freeze.2.log`, 18MB). 67% of the 1.097s main-thread CPU sits in this recursion:

```
NSHostingView.beginTransaction
  → GraphHost.flushTransactions
  → ScrollViewLayoutComputer.Engine.sizeThatFits   ← outer ScrollView measuring content
  → LazyVStackLayout.sizeThatFits
  → LazyStack.sizeThatFits
  → _ViewList_Node.estimatedCount
  → ForEachList.estimatedCount
  → ForEachState.estimatedCount ↔ _ViewList_Group.estimatedCount   (deep recursion)
```

This is a **different** signature than the 5/10 hang that motivated PR #130 (that one was in `StyledTextLayoutEngine` inside `BashCard`'s nested ScrollView). The new signature is dominated by `estimatedCount` walking the heterogeneous conditional view tree:

- `ForEach(items) { item in rowFor(item); if item.id == latestUsageItemID { ContextUsageBadge(...) } }`
- `rowFor` is `@ViewBuilder` returning `Group { switch over 5 TranscriptItem cases }`
- The `.toolCall` case calls `toolCardFor` which is another `@ViewBuilder` switch over 9 tool names
- The `.toolCall` case may also contain `SubagentDisclosure` whose expanded state contains a nested `TranscriptItemsView` (recursive ForEach)

The outer ScrollView (with `.defaultScrollAnchor(.bottom)` and `.scrollPosition(id:)`) calls into LazyVStack's `sizeThatFits`, which calls `estimatedCount`, which recurses through every conditional branch and every nested ForEach to estimate row count.

## Why "fix it locally" no longer feels right

Each prior fix peeled off one specific cost contributor (textSelection, nested ScrollView max height, etc.). The bug class persists. The structural problems with `ScrollView { LazyVStack }` for our shape of data are:

1. **No cell recycling.** LazyVStack realizes rows on enter but never deallocates them. Long sessions accumulate hundreds of realized rows; memory grows unbounded and tab-leave teardown is slow.
2. **Heterogeneous-body estimatedCount cost is intrinsic.** SwiftUI walks the conditional view tree to compute size hints for the outer ScrollView. Variable-height MarkdownUI rows make this worse — there's no caching.
3. **The combination `.scrollPosition(id:) + .defaultScrollAnchor(.bottom) + LazyVStack + variable-height markdown` is a documented perf footgun.** Fatbobman, Apple Developer Forums #685461, #657902, #741406, cmux #2327 — all cite the same shape of bug.

## The existing migration design doc

`docs/superpowers/specs/2026-05-06-transcript-list-migration-design.md` (in this repo) is a complete ready-to-execute plan that migrates the transcript pane from `LazyVStack` to `List`, mirroring [IceCubesApp `TimelineListView`](https://github.com/Dimillian/IceCubesApp/blob/main/Packages/Timeline/Sources/Timeline/View/TimelineListView.swift). The companion research doc `docs/superpowers/specs/research-2026-05-06-swiftui-long-list-perf.md` collects ~30 sources converging on "use List, not LazyVStack."

Phase 1 of the design doc (3 file edits + reinstating 4 `.fixedSize` calls, ~1 commit):

```swift
// TranscriptItemsView.swift (depth=0):
List {
    ForEach(items) { item in
        rowFor(item)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
    }
}
.listStyle(.plain)
.scrollContentBackground(.hidden)
.environment(\.defaultMinListRowHeight, 1)

// LiveTranscriptPaneView.swift: drop ScrollView, defaultScrollAnchor, scrollPosition.
// Keep ScrollViewReader; proxy.scrollTo(lastID, anchor: .bottom) in .onAppear and on messages.last?.id change.
```

## What we lose by migrating (the migration's UX cost)

1. **`.defaultScrollAnchor(.bottom)` doesn't work on `List`.** (Confirmed by research today — Apple DTS engineer on [forums #770682](https://developer.apple.com/forums/thread/770682) explicitly says `.scrollPosition` doesn't work with List; same architectural reason applies to `defaultScrollAnchor`. Fatbobman's WWDC24 writeup confirms the new scroll-control API family is ScrollView-only.) So we get a visible one-frame "top-of-list → jump to bottom" flash on every entry into the pane. Mitigable with `.opacity(0)`-until-scrolled (adds ~50ms latency, never perfect).
2. **Drag-select across rows is likely a regression** on macOS. NSTableView-backed List has cell boundaries; LazyVStack is one contiguous surface. The hover-driven text-selection latch (`hoveredItemID`) was specifically built around the LazyVStack contiguity. Needs manual test.
3. **Scroll-position preservation across worktree switches is lost in Phase 1.** Currently `.scrollPosition(id: $visibleID)` persists the user's scroll position. After migration, every tab leave/return resets to bottom. Phase 2 of the design doc plans to restore via `onScrollGeometryChange`-driven visibleID tracking + AppState storage.
4. **Streaming-follow needs explicit re-implementation.** Today, when an assistant message streams, the growing row's bottom stays glued to the viewport bottom (declarative via `.scrollPosition(id: $visibleID, anchor: .bottom)`). After migration, we have to detect "content grew while at bottom" via `onScrollGeometryChange` and call `proxy.scrollTo(lastID, anchor: .bottom)` explicitly. Implementable, not free.
5. **List has implicit insert/delete animations.** Could look polished, could look jittery during streaming. Disable with `.transaction { $0.animation = nil }` if needed.

## What we'd gain

1. **Real cell recycling.** Rows deallocate when far off-screen. Memory bounded by viewport size, not by session length.
2. **No `placeChildren → sizeThatFits → estimatedCount` cycle.** List isn't built on SwiftUI's StackLayout primitives that produced the recursion. Architectural fix to the bug class.
3. **Faster tab-leave teardown.** No huge accumulated view tree to tear down.
4. **Per IceCubesApp**, this is the battle-tested pattern for chat/timeline at scale on macOS 15.

## The underexplored LazyVStack rescue options (research from today)

Findings from researching "what haven't we tried yet for LazyVStack":

| Tactic | Viability | Evidence | Catch |
|---|---|---|---|
| **Homogenize `ForEach` body** (single concrete `TranscriptRow` view; internal switch wrapped in `VStack`, not `Group`) | Medium-high | Fatbobman: `if`/`switch` in `ForEach` compile to `_ConditionalContent` which "disrupts the lazy loading mechanism." Fix: wrap branches in layout container with identity (VStack works; Group doesn't). | Fatbobman explicitly says this fixes *List*'s lazy loading, not LazyVStack's sizing recursion. May not move our needle. |
| **Migrate row state to `@Observable`** | Medium-high | `MojtabaHs` on swift-markdown-ui #426 (Nov 2025) attributes the freeze to *"excessive nesting … related to how environment variables are set"* and says fix requires `@Observable`. | One library-maintainer comment. Unproven in our codebase. Our row views don't use `@ObservedObject` heavily — only `@EnvironmentObject var appState: AppState`. |
| **`.equatable()` on rows** | High | Hacking with Swift: "memcmp-style byte-level comparisons" let SwiftUI skip re-renders for unchanged inputs. Already on the migration's Phase 2 list. | Requires all row state to be primitive/Equatable. Worth doing regardless. |
| **WWDC25 LazyVStack improvements** | Free (if we build against macOS 26 SDK) | WWDC25 notes: "lazy stacks now benefit from prefetching, especially on macOS." | No new API for pre-declared row heights or manual virtualization. Runtime-only wins, modest. |
| **Manual virtualization via `onScrollGeometryChange`** | Low for our shape | No one ships this for variable-height heterogeneous rows. | Without pre-known heights, you can't compute the window without measuring → back to square one. |
| **Pre-measured heights via `SwiftUILazyContainer`** | Medium | `ciaranrobrien/SwiftUILazyContainer` lets you declare `contentHeight: .template` or closure. | Stale dependency (last release May 2024). Adopting means owning a fork. |
| **Custom `Layout` protocol** | Not viable | `Layout.sizeThatFits` receives all subviews already realized. | Dead end. |
| **`UICollectionView`/`NSCollectionView` w/ `NSHostingConfiguration`** | High but heavy | Apple-sanctioned, but ~weeks of work. | Last resort; design doc has this as Phase 3. |

Researcher's recommendation: **1–2 day timeboxed experiment** combining (a) homogenize `rowFor` + `toolCardFor` into a single `TranscriptRow` view with branches wrapped in `VStack`, (b) `.equatable()` row, (c) `@Observable` audit if relevant. If `estimatedCount` recursion still dominates after that, migrate to List. The `.equatable()` work is durable either way (Phase 2 of the migration anyway).

## My (Claude's) read

I lean **A (migrate to List)**, for two structural reasons:

1. **Row accumulation is structural to LazyVStack.** Even if we fix the sizing recursion, long sessions accumulate realized rows forever. Memory grows; tab-leave gets slow. The List migration is the only one of these options that addresses this.
2. **The fix-and-pray pattern has played out 5 times now.** Each fix removed one signature, a new one appeared. The structural argument for List (no `estimatedCount` cycle at all) is stronger than the "more nesting / environment depth" hypothesis from MojtabaHs — which is one library-maintainer comment, not a tested fix.

But option **C (1-day timebox on rescue tactics, then A if not enough)** is defensible. The `.equatable()` work survives either way. The risk is the timebox slipping; the upside is preserving the UX wins (flash-free first paint, drag-select, scroll-position persistence) if the rescue works.

## What I'd value a second opinion on

1. **Is the MojtabaHs `@Observable` finding stronger than I'm reading it as?** Specifically: in a codebase where row views consume `@EnvironmentObject var appState: AppState` (not `@Observable`-based), is migrating to `@Observable` plausibly the difference between "estimatedCount recursion takes 1.2s" and "estimatedCount recursion takes <50ms"? Or am I right that this is mostly a story about library-internal re-render fan-out, not our outer-tree sizing pass?
2. **Is the row-accumulation argument decisive?** Or are there practical reasons (e.g., MarkdownUI parse caching makes accumulated rows cheap to re-realize) that make accumulation less important than I'm weighing it?
3. **Is there an option I'm missing entirely?** Specifically: is there a clean way to keep LazyVStack but get cell recycling? Or to keep `.defaultScrollAnchor(.bottom)` on a List somehow? Anything beyond what's in the table above?
4. **First-paint flash with `.opacity(0)`-gate — how bad is this really?** A few hundred ms of "loading" feel before content fades in. For a chat-style transcript, is this acceptable, or is it the kind of thing that becomes a daily papercut?
5. **Anything about the IceCubes pattern that doesn't translate?** IceCubes is a Mastodon feed (rows append at top, you scroll down through history). TBD's transcript is a chat (rows append at bottom, you scroll up through history). Does the inverted append direction change the recommendation?

## Pointers to the actual code

If a reviewer wants to look:

- `Sources/TBDApp/Panes/Transcript/TranscriptItemsView.swift` — the `LazyVStack { ForEach }` (lines 91–107).
- `Sources/TBDApp/Panes/LiveTranscriptPaneView.swift` — the outer `ScrollView` + scroll-control modifiers (lines 127–187).
- `Sources/TBDApp/Panes/Transcript/SubagentDisclosure.swift` — recursive `TranscriptItemsView` at `depth+1`.
- `Sources/TBDApp/Panes/Transcript/{Bash,Write,Read,Edit,Grep,Glob,Agent,AskUserQuestion,Generic}Card.swift` — the tool-call row variants.
- `Sources/TBDApp/Panes/Transcript/ChatBubbleView.swift` — MarkdownUI chat bubble.
- `Sources/TBDApp/Diagnostics/HangWatchdog.swift` — hang telemetry (threshold 1000ms).
- `docs/superpowers/specs/2026-05-06-transcript-list-migration-design.md` — the existing ready-to-execute migration plan.
- `docs/superpowers/specs/research-2026-05-06-swiftui-long-list-perf.md` — collected prior art.
- GitHub issue: <https://github.com/cheapsteak/tbd/issues/129>
- Today's hang sample: `/Users/chang/projects/tbd/freeze.2.log` (18MB, plain text spindump).

## Coordination

If you're reviewing this and want to leave a structured opinion: append to `docs/superpowers/specs/2026-05-11-transcript-hang-decision-discussion.md` (sibling file). Template inside.
