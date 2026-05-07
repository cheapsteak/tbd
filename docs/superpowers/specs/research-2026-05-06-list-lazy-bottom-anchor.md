# Research: SwiftUI List laziness + bottom anchor on macOS 15

Date: 2026-05-06
Scope: macOS 15 (Sequoia), SwiftUI `List` post-migration from `LazyVStack`. Follow-up to `research-2026-05-06-swiftui-long-list-perf.md`.

## TL;DR

- **`List` on macOS 15 is *less lazy than the prior research implied* in two specific ways that match our symptoms.** (1) `List { ForEach(messages) { ... } }` (the IceCubes shape we copied) calls each row's `View.init` for *all* rows at first display — a long-standing SwiftUI bug (FB11280425, filed Aug 2022, never fixed) that was confirmed *worsened* in Xcode 16 / iOS 18 / macOS 15 (FB15356563, Sep 2024, unresolved as of late 2025). The opt-out — `List(messages) { ... }` (no inner `ForEach`) — preserves laziness but loses `listRowInsets` / `swipeActions` / per-row modifiers. (2) Putting `.id(...)` on row views, which we likely do for `proxy.scrollTo(sentinel)`, *also* defeats List's lazy realization on its own (Fatbobman, multiple sources). Net: with our current code shape, every row's `init` runs at view appear, which is enough by itself to cause the freeze — the cell-recycling we adopted `List` for is likely not actually engaging.
- **What underlies `List` on macOS 15 is no longer `NSTableView` for non-outline content.** That's a 2024 architectural change called out in Apple's WWDC and corroborated by Tsai. The replacement appears to be a SwiftUI-native lazy stack (the "improved scheduling and lazy loading" Apple cited at WWDC25 — 6× load / 16× update gains, per Tsai). **It is *not* `NSCollectionView` either.** This matters because the prior research's "cell recycling that we know and love" framing assumed a UIKit/AppKit-backed implementation. The macOS 15 reality is closer to a smarter `LazyVStack` than to a recycled-cell collection view. There is no `noteHeightOfRowsWithIndexesChanged`-style precomputed height path; row heights are still measured as rows are realized.
- **`proxy.scrollTo` does not animate by default.** `List`-against-`proxy.scrollTo` only animates when explicitly wrapped in `withAnimation { ... }`; an iOS-17-era regression that broke this for projects with deployment target below 17 was fixed in iOS 17 dev beta 7. **The visible "sink to bottom" the user is seeing is almost certainly our explicit `withAnimation(.easeOut(duration: 0.15))` on `.onChange(messages.last?.id)` firing once after the first poll populates the list — combined with the fact that the *initial* `scrollTo` in `.onAppear` is racing layout for ~700 rows that haven't been measured yet.** Drop the `withAnimation` and you should stop seeing the visible motion.
- **Production OSS chat apps land at the bottom either by (a) `defaultScrollAnchor(.bottom)` on `ScrollView { LazyVStack }` (still — `List` does not honor `defaultScrollAnchor` reliably, the new scroll-control APIs explicitly don't support `List`); (b) a deferred `proxy.scrollTo` gated on content-readiness (macai's pattern, waits for code blocks to render before initial scroll); or (c) the rotation-180 inverted-scroll trick.** None of these are perfect. There is no native, no-flicker, pure-SwiftUI primitive for "open a `List` already at the bottom of 700 variable-height rows." We are in known-fragile territory.
- **Recommendations:** (i) Drop the `withAnimation` from the `.onChange` initial-scroll — that alone removes the visible motion for the user. (ii) Switch our `List { ForEach(messages, id: …) { row.id(...) } }` shape to `List(messages, id: …) { row }` *without* per-row `.id()`, and use the closure parameter as the scroll target — this restores actual lazy realization. (iii) Hide the list with `.opacity(isReady ? 1 : 0)` until the deferred-scroll completes, à la macai's "isInitialLoad" gate, to suppress the remaining one-frame flash. (iv) If those don't fix the tab-switch freeze, the deeper issue is per-row MarkdownUI parse cost (every row's `init` runs at appear, regardless of `List`'s recycling claims) — cache parsed `MarkdownContent` on the message model, not in `body`. (v) If freezes *still* persist, the right fallback is an `NSScrollView`/`NSCollectionView` `NSViewRepresentable` with `NSHostingConfiguration`, **not** going back to `LazyVStack`.

## Is List actually lazy for scroll-to-far-row?

Short answer: **it depends, and in our specific configuration probably not.**

### Evidence

1. **`List { ForEach(data) { ... } }` calls `init` on every row at first display.** This is the most important finding. Filed as Apple feedback FB11280425 (Aug 2022) and discussed in [thread/716063](https://developer.apple.com/forums/thread/716063):

   > "When using `ForEach` inside a `Section` within a SwiftUI `List`, all rows are initialized and loaded at once instead of lazily loading visible rows. This defeats the performance benefits of lazy loading in Lists."

   Fatbobman's "[Discussing List and ForEach in SwiftUI](https://fatbobman.com/en/posts/swiftui-list-foreach/)" corroborates and gives the workaround:

   > "In List, if you use ForEach to handle the data source, all Views of the data source need to be initialized at the creation of the List. … ForEach has to preprocess all data and prepare Views in advance. And after initialization, it does not automatically release these Views (even if they are not visible)!"

   The workaround is to use **`List(data) { item in ... }`** (the convenience initializer, no inner `ForEach`). That form *does* lazily realize. But it loses per-row layout flexibility — you can't apply `listRowInsets`, `swipeActions`, `listRowSeparator`, etc. per row. (You can apply them per-section if you wrap in `Section`.)

   IceCubes uses `List { ForEach(...) }`. So either IceCubes is also paying this init cost (and is masking it because Mastodon `Status` rows are cheap, while ours run MarkdownUI in `body`), or some specific shape they use avoids it. Either way, the symptom for *us* is consistent with paying the init cost.

2. **Xcode 16 / iOS 18 / macOS 15 made the same problem worse for `List(data)` too.** [thread/765203](https://developer.apple.com/forums/thread/765203), filed Sep 2024 as FB15356563:

   > "Xcode 15.2 (working): List lazy-loads child views on demand (~13 views initialized on first display for a 1000-item list). Xcode 16+ (broken): List initializes all 1000 child views at once when the view is first displayed."

   Confirmed by 6+ developers; runtime issue, both Debug and Release; partial workaround `SWIFT_ENABLE_OPAQUE_TYPE_ERASURE=NO` doesn't always work. **Status as of Nov 2024: unresolved.** No public evidence of a fix in 18.2 / 15.2.

3. **Putting `.id(...)` on row views inside `ForEach` defeats `List`'s lazy optimization.** From Fatbobman ([Demystifying SwiftUI List](https://fatbobman.com/en/posts/optimize_the_response_efficiency_of_list/)):

   > "Adding `.id(item.objectID)` to each row caused List to instantiate views for all data itemRows, totaling 40,000. Using the id modifier is equivalent to splitting these views out of ForEach, thus losing the optimization conditions."

   We almost certainly do this — we need `.id(message.stableID)` on each row for `proxy.scrollTo(message.stableID)` to find the target. So even if (1) and (2) didn't apply, the explicit `.id` modifier would *separately* defeat laziness.

4. **What `List` *does* still do well — when not defeated.** Fatbobman's [List or LazyVStack](https://fatbobman.com/en/posts/list-or-lazyvstack/):

   > "List does not maintain a concept of complete content height at the SwiftUI level. During fast scrolling or extensive jumps, it intelligently selects the necessary subviews for instantiation and height calculation, significantly improving scrolling and jumping efficiency."

   And from [Demystifying SwiftUI List](https://fatbobman.com/en/posts/optimize_the_response_efficiency_of_list/):

   > "Only about 100 child views were instantiated and drawn throughout the entire scrolling process [during scrollTo]."

   This is the laziness we hoped for: `proxy.scrollTo(targetID, anchor: .bottom)` should *not* require realizing every row from top to target — `List` can compute the offset without doing that, *if* the lazy-loading machinery is intact. Our problem is that we're likely defeating that machinery via `ForEach` + per-row `.id()`.

5. **`List` does not "iterate the whole collection upfront" the way `LazyVStack` does for distance calculations.** Gwendal Roué (quoted by Tsai, Jun 2025):

   > "List was requiring a Swift Collection, which means all elements must pre-exist…List was iterating all elements in the collection, upfront, even those which are far off-screen."

   The first half is a constraint (collection pre-existence). The second half describes how the *previous* implementation worked. WWDC25 announcements suggest 6× / 16× improvements via "improved scheduling and lazy loading" — not an architectural change, but enough that the older "iterates all elements upfront" claim is now partially mitigated. Still: rows can be iterated/initialized cheaply (just `View.init`) without being "realized" in the layout sense — and that's what FB11280425 / FB15356563 are complaining about: the cheap iteration is no longer cheap when each row's `init` does substantial work.

### Bottom line for our `proxy.scrollTo(sentinel, anchor: .bottom)` against ~700 rows

- If our `List` were configured the way Fatbobman recommends — `List(messages) { ... }` *without* per-row `.id`, no inner `ForEach` — `proxy.scrollTo(sentinel, anchor: .bottom)` would realize ~100 views (the visible window at the target), not 700. That's the laziness we adopted `List` for.
- With our actual configuration — `List { ForEach(messages, id: \.stableID) { row.id(.stableID) } }` — every row's `View.init` runs at `.onAppear`, plus `.id` defeats subsequent lazy optimizations. With MarkdownUI rows whose `init` parses markdown, this is functionally close to "realize all rows from top to target." That matches the freeze symptom.

## What underlies List on macOS — NSCollectionView or NSTableView?

**Neither, as of macOS 15.**

The historical answer (macOS 12-14) was `NSTableView`. Multiple sources confirm: "List in SwiftUI for macOS has default background color because of the enclosing NSScrollView via NSTableView that List uses under the hood" (cited in multiple 2023 blog posts).

The macOS 15 change is documented in Tsai's [Apr 2024 NSTableView post](https://mjtsai.com/blog/2024/04/15/nstableview-with-swiftui/) and [Jun 2025 WWDC25 post](https://mjtsai.com/blog/2025/06/18/swiftui-at-wwdc-2025/):

> "On macOS 15, List does not use NSTableView for showing non-outline content anymore."

Tsai then characterizes the new implementation:

> "The improvements came from improved scheduling and lazy loading rather than an architectural change. … 6x (loading) and 16x (updating) improvements were cited [at WWDC25], but don't seem like enough to match NSTableView."

And Gwendal Roué's correction (quoted in the same Tsai post):

> "List was requiring a Swift Collection, which means all elements must pre-exist…List was iterating all elements in the collection, upfront, even those which are far off-screen."

That phrasing — and the "non-architectural" framing — strongly suggests the new implementation is a SwiftUI-native lazy stack with smarter scheduling, *not* a swap from `NSTableView` to `NSCollectionView`. This is consistent with the laziness semantics being *similar to* `LazyVStack` but with better hand-off to the scroll machinery (so `proxy.scrollTo` can compute offsets without realizing every intermediate row, *when its laziness isn't defeated by `ForEach`/`.id`*).

**Practical consequences for our debugging:**

- There is no `NSTableView`-level `usesAutomaticRowHeights` / `noteHeightOfRowsWithIndexesChanged` / `scrollRowToVisible` to fall back on. `List` on macOS 15 is closer to a SwiftUI-native primitive than to an AppKit shim.
- "Cell recycling" is the wrong mental model for macOS 15 `List`. There is laziness in *realization*, but not classic UIKit/AppKit-style cell reuse with bounded memory. Once a row is realized, it likely stays realized (this is what Fatbobman observes for `ForEach`-driven lists at least).
- If we need true bounded-memory cell reuse with self-sizing, the only sanctioned escape hatch on macOS is `NSCollectionView` + `NSHostingConfiguration` via `NSViewRepresentable` (WWDC22 "Use SwiftUI with AppKit"). `flocked/AdvancedCollectionTableView` is the modernization path.
- `NSCollectionView`'s self-sizing path uses `estimatedItemSize` on `NSCollectionViewFlowLayout` and grows actual sizes via `preferredLayoutAttributesFittingAttributes` as items realize. It *does* support "scroll to end of long list" without realizing every item — but you have to provide reasonable estimates, and you have to use the modern compositional layout APIs to get good behavior. This is non-trivial but well-worn.

## How OSS chat apps handle initial bottom-anchor without visible transition

Mixed evidence. **No one has nailed this perfectly in pure SwiftUI on macOS.**

### IceCubes (canonical large-scale SwiftUI Mastodon, multi-platform)

Confirmed via `gh search`: their `TimelineListView.swift` is `ScrollViewReader { proxy in List { ScrollToView(); ForEach(...) { StatusRowView(...) } } }`, no `.id(...)` on rows except for explicit anchor markers. Their use case is **scroll to top of timeline**, not "land at bottom of chat" — they don't face our exact problem. But the shape `List { ForEach(statuses) { ... } }` is the same shape we copied, and it would suffer FB11280425 except that `Status` rows are cheap. Their initial-positioning path is `proxy.scrollTo(scrollToIDValue, anchor: .top)` in `.onChange(of: viewModel.scrollToId)` — animated implicitly by `withAnimation` in some places but not others. **They don't model bottom-anchor open.** Limited applicability for our problem.

### macai (Renset/macai, a multi-provider macOS AI chat)

Source verified via `gh api`. `macai/UI/Chat/ChatMessagesView.swift` does *not* use `List` — it uses **`ScrollView { ScrollViewReader { VStack { ... } } }.defaultScrollAnchor(.bottom)`**. Note: `VStack`, not `LazyVStack`. They explicitly don't use either `List` or `LazyVStack` for the message column.

Their open-without-flicker pattern is:

```swift
.onAppear {
    pendingCodeBlocks = chatViewModel.sortedMessages.reduce(0) { count, message in
        count + (message.body.components(separatedBy: "```").count - 1) / 2
    }
    isInitialLoad = true
    if pendingCodeBlocks == 0 {
        codeBlocksRendered = true
        isInitialLoad = false
    }
}
.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CodeBlockRendered"))) { _ in
    if pendingCodeBlocks > 0 {
        pendingCodeBlocks -= 1
        if pendingCodeBlocks == 0 {
            codeBlocksRendered = true
            if isInitialLoad {
                isInitialLoad = false
                if let lastMessage = chatViewModel.sortedMessages.last {
                    DispatchQueue.main.async {
                        scrollView.scrollTo(lastMessage.objectID, anchor: .bottom)
                    }
                }
            }
        }
    }
}
```

Two key takeaways:

1. **They use `defaultScrollAnchor(.bottom)` on the outer `ScrollView`** — the anchor that prior research and Apple Forums [thread/741406](https://developer.apple.com/forums/thread/741406) flag as *fragile* with `LazyVStack`. macai gets away with it because they use `VStack`, not `LazyVStack`, paying the upfront cost of realizing all rows so that the bottom anchor "just works" without scroll motion. **This is fundamentally trading freeze-on-open for visible-motion-on-open.** macai chose freeze-on-open. We chose `List` to avoid that, and now have a different version of both problems.
2. **They gate the *programmatic* `scrollTo` on a content-readiness signal (`CodeBlockRendered` notifications, count-based).** No `withAnimation`. This is the cleanest version of our `.onAppear` deferred-scroll, made deterministic instead of timer-based. Note also: `DispatchQueue.main.async` rather than `asyncAfter(deadline: .now() + 0.05)` — because they have a real signal, they don't need a heuristic delay.

For *our* case on `List`, we don't have a content-readiness signal (markdown rendering happens inside MarkdownUI, no notifications emitted). We could either (a) wait until a stable size is reported via `onScrollGeometryChange`, or (b) hide-until-positioned with opacity.

### Other macOS SwiftUI AI chat clients

- **AICat (Panl/AICat)**, **ChatGPTSwiftUI (alfianlosari)**, **iChatGPT (37iOS)** — all small-scale, none demonstrate large-transcript bottom-anchor patterns. No useful prior art.
- **stream-chat-swiftui** (commercial SDK) — has [issue #78](https://github.com/GetStream/stream-chat-swiftui/issues/78) "Long boring messages break scroll to bottom functionality," indicating they hit similar problems. Not OSS source for `List` patterns.

### Inverted-scroll trick (rotate 180°)

Documented at [Swift with Vincent](https://www.swiftwithvincent.com/blog/building-the-inverted-scroll-of-a-messaging-app) and [Apple Forums thread/681833](https://developer.apple.com/forums/thread/681833):

> "Apply `.rotationEffect(.radians(.pi))` and `.scaleEffect(x: -1, y: 1, anchor: .center)` to both the scroll view and each child view. The scroll view starts at what's visually the bottom (because top is now bottom). Append-from-top maps to the user's natural append-at-bottom."

Pros: the chat literally cannot have a "scroll from top to bottom" transition — it's already at the user-visible "bottom" because that's the data top. Append doesn't trigger a scroll-position fight. Forum [thread/741406](https://developer.apple.com/forums/thread/741406) (Jan 2025) calls this out as a working workaround for `defaultScrollAnchor(.bottom)`-on-`LazyVStack` fragility too.

Cons: known issues with navbar jumping, pull-to-refresh, scroll-indicator direction, and accessibility (VoiceOver order is wrong unless you also flip the accessibility). The rotation can also confuse hit-testing for things like text selection and link clicks if not carefully scoped. **And critically: the inverted trick is documented for `LazyVStack`, not `List`.** It can in principle be applied to `List`, but examples are scarce — and `List`'s default behaviors (separators, selection chrome, focus rings) get visually inverted in ways you have to manually unflip per row. Not zero cost.

### Hide-until-positioned

A deliberate pattern: `.opacity(isReady ? 1 : 0)`, set `isReady = true` from the deferred-`scrollTo`'s completion or after a debounced settle. Used in commercial chat apps (no OSS macOS examples found, but it's a frequently-mentioned pattern in WWDC sample-code discussion). Avoids the visible motion entirely at the cost of a brief blank/dimmed view.

This is a near-perfect fit for our situation. The user explicitly says they want to *avoid* needing this — but given the framework constraints we're working with, this may be the lowest-cost path that actually works.

### `defaultScrollAnchor(.bottom)` outside `LazyVStack`

[Apple's doc](https://developer.apple.com/documentation/swiftui/view/defaultscrollanchor(_:)) lists it as a `View` modifier on `ScrollView`. Per Fatbobman's [evolution of SwiftUI scroll APIs](https://fatbobman.com/en/posts/the-evolution-of-swiftui-scroll-control-apis/), the new scroll-control APIs explicitly **do not support `List`**:

> "The new scroll control APIs no longer support List, which to some extent limits their application range."

That includes `defaultScrollAnchor`, `scrollPosition(id:)`, `scrollPosition($pos)`, etc. — they're documented as `ScrollView`-only. Some posts show `.defaultScrollAnchor(.bottom, for: .alignment)` syntax applied to `List`, but the behavior is unreliable / undocumented.

**So `defaultScrollAnchor(.bottom)` on `List` is *not* a usable primitive for us.** We have to programmatic-scroll.

## Does `proxy.scrollTo` always animate against `List`, or only when wrapped in withAnimation?

**Only when wrapped in `withAnimation`.** No animation by default.

Confirmed by:

- [Apple Forums thread/735479](https://developer.apple.com/forums/thread/735479) — "If you call scrollTo() inside withAnimation() the movement will be animated. … This issue has been fixed in iOS 17 developer beta 7." (Sep 2023, the regression where it didn't animate even with `withAnimation` on iOS 17 with deployment target < 17.)
- [Hacking with Swift's reference](https://www.hackingwithswift.com/quick-start/swiftui/how-to-scroll-to-a-specific-row-in-a-list) — explicitly contrasts the wrapped-in-`withAnimation` form vs the bare form.
- [Use Your Loaf "Scrolling With ScrollViewReader"](https://useyourloaf.com/blog/scrolling-with-scrollviewreader/) — same contract.

There's a known iOS 17.0-only regression that's not relevant to macOS 15. There is **no** evidence that `List`'s `proxy.scrollTo` has special "always animates" behavior that ignores `withAnimation`.

**Implication for our code:** the `withAnimation(.easeOut(duration: 0.15))` we wrap around our `.onChange` `proxy.scrollTo` is the only animation source. The `.onAppear` deferred `proxy.scrollTo` *should* be jumping instantly. If the user is seeing a slide/sink on `.onAppear` *too*, that motion is List's own first-layout settling — not a programmatic animation.

Two distinct visible motions to disentangle:

1. The `.easeOut(duration: 0.15)`-wrapped `.onChange` scroll, fired when messages populate after the first poll. This is *intentional animation* and the user is definitely seeing it.
2. Any layout settling between the `.onAppear` `scrollTo` and the moment List finishes its first measurement pass. This is *not* a `proxy.scrollTo` animation; it's `List` itself working through its initial layout. With our `List { ForEach { row.id(...) } }` shape, every row's `init` runs eagerly, which makes this settling slow.

Almost certainly what the user is seeing is some combination of (1) and (2), with (1) being the dominant visible motion.

## Recommendations for our specific situation

Given:
- We use `List` (post-migration)
- We have a sentinel row at the bottom
- We use `proxy.scrollTo(sentinel, anchor: .bottom)` deferred 50ms in `.onAppear`
- We use `proxy.scrollTo(sentinel, anchor: .bottom)` wrapped in `withAnimation` on `.onChange(messages.last?.id)`
- We see the user landing at top and visibly sinking to bottom
- We see a freeze on tab leave/enter for long sessions

### Step 1 (smallest, highest-leverage): drop the `withAnimation` on the initial `.onChange` scroll

`withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(sentinel, anchor: .bottom) }` on the very first `.onChange` after `messages` populates is creating the bulk of the visible motion. Replace with a plain `proxy.scrollTo(sentinel, anchor: .bottom)` for the *first* settle, and only re-enable `withAnimation` for *subsequent* updates (new messages arriving while the chat is open). A simple `@State private var didFirstScroll = false` gate works:

```swift
.onChange(of: messages.last?.id) { _, _ in
    guard let sentinel else { return }
    if didFirstScroll {
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(sentinel, anchor: .bottom)
        }
    } else {
        proxy.scrollTo(sentinel, anchor: .bottom)
        didFirstScroll = true
    }
}
```

This alone should remove the visible "sink to bottom" the user is reporting. Do this first; it's a one-line change and we can re-evaluate before doing anything else.

### Step 2: restore actual lazy realization in `List`

Audit the transcript pane for the two known laziness-defeating patterns:

- **`List { ForEach(messages) { ... } }`** → consider switching to **`List(messages, id: \.stableID) { message in ... }`** (no inner `ForEach`). You lose `swipeActions`-on-row and per-row `.listRowInsets` flexibility — verify which we actually need. If we need per-row insets, wrap rows in `Section(...)` and apply `.listSectionInsets` (macOS 15+), or accept eager `init` and mitigate at the `init` cost level (Step 3 below).
- **`.id(message.stableID)`** on each row → only put `.id` on the sentinel and on rows we genuinely need to programmatically scroll to. For the bottom-anchor use case, we only need `.id` on the sentinel — rows themselves don't need `.id` because we're scrolling to the sentinel. This is a real win regardless of which `List` shape we settle on.

After this change, the laziness Fatbobman observed (~100 views realized for a `scrollTo` to a far-off row) should kick back in. That directly addresses the tab-switch freeze.

### Step 3: mitigate per-row `init` cost

If FB11280425 / FB15356563 are biting us regardless of our `List` shape (Xcode 16+ regression), we still pay `View.init` for every row at first display. Make `init` cheap:

- **Pre-parse markdown.** Compute `MarkdownContent` once, in the row's view-model or a Codable cache on the message, never inside the row's `body` or `init`. MarkdownUI's `Markdown(content:)` initializer is cheap when given already-parsed content.
- **`.equatable()` on the row view** — multiple sources (Hacking with Swift, troz.net) report this as the single biggest knob for `List` perf on macOS, including unblocking lazy realization in some configurations:

  > "Applying the `equatable` modifier to row views prevented rendering all 10,000 rows simultaneously and enabled lazy loading. The row views were not drawn until they were scrolled into view." — troz.net, 2024

- **Avoid heavyweight environment subscriptions** in row `init` (cmux #2327 lesson). If we read `@AppStorage`/`@Environment` per row, fan-out is O(n). Hoist to the parent.

### Step 4: hide-until-positioned to absorb residual flash

After Steps 1-3, a frame or two of "rows visible at top before scroll lands" may still be visible. Apply opacity gating, macai-style:

```swift
List(messages, id: \.stableID) { message in
    row(for: message).equatable()
}
.opacity(didFirstScroll ? 1 : 0)
.onAppear {
    DispatchQueue.main.async {
        proxy.scrollTo(sentinel, anchor: .bottom)
        // Two-frame settle to be safe; List measures asynchronously.
        DispatchQueue.main.async {
            proxy.scrollTo(sentinel, anchor: .bottom)
            didFirstScroll = true
        }
    }
}
```

Two `DispatchQueue.main.async` hops (no `asyncAfter`) is more reliable than a 50 ms timer because it's relative to the actual layout cycle, not wall clock. The user's prior research notes a desire to avoid this — but given that no SwiftUI primitive does "open `List` already at bottom of long list" cleanly, this is the lowest-fragility fallback.

### Step 5: if the freeze still persists, escape to AppKit

If after Steps 1-3 we still get tab-switch freezes on long transcripts:

- The deeper cause is that even cheap per-row `init` × 700 + MarkdownUI's per-row layout cost exceeds an acceptable budget. `List` on macOS 15 cannot save us at that point.
- The sanctioned path is `NSScrollView` + `NSCollectionView` (compositional layout, `estimatedItemSize`) hosted via `NSViewRepresentable`, with each item using `NSHostingConfiguration` to keep the SwiftUI row content. `flocked/AdvancedCollectionTableView` is the modernization helper.
- **Do not go back to `LazyVStack`.** The prior research's freeze-causing path was `LazyVStack` + `MarkdownUI` rows; that hasn't changed. macai gets away with `VStack` (not `LazyVStack`) only because they accept the eager-render cost; their sessions are typically tens-of-messages, not 700+.
- Alternatively, evaluate the maintainer's successor library **Textual** when it stabilizes — same gonzalezreal author, designed to fix exactly the per-row layout/perf issues that motivated MarkdownUI's retirement (Discussion #437, Jan 2026).

### Specifically for the two visible-motion sources

| Symptom | Cause | Fix |
|---|---|---|
| Visible "sink from top to bottom" on first paint | `withAnimation(.easeOut(duration: 0.15))` around `proxy.scrollTo` in `.onChange(messages.last?.id)`, fired once when messages populate after first poll | Step 1: gate first scroll with `didFirstScroll` and skip `withAnimation` for it. |
| Lands at top first, then jumps | `.onAppear` `proxy.scrollTo` racing `List`'s first layout (because `ForEach` + `.id()` defeats laziness, so `List`'s first layout takes a long time) | Step 2 (restore laziness) reduces the race window; Step 4 (opacity gate) absorbs the remainder. |
| Tab-switch freeze on long transcripts | Eager `View.init` per row × 700 + MarkdownUI per-row parse cost + `.id` defeating lazy realization on subsequent passes | Step 2 (restore laziness) + Step 3 (cheap `init`, `.equatable()`); Step 5 if not enough. |

---

## One-paragraph synthesis: is `List` the right primitive?

**Probably yes — but only if we use it correctly, which our current code may not.** `List` on macOS 15 is *not* the cell-recycling AppKit shim the prior research implied (it stopped being `NSTableView`-backed in macOS 15), and it has *real* laziness limits exposed by FB11280425/FB15356563 and worsened by per-row `.id()` modifiers. With our current `List { ForEach(messages, id: \.stableID) { row.id(...) } }` shape, we're paying eager `View.init` for all 700 rows on first display and likely defeating List's lazy realization on subsequent scrolls — which would explain both the visible-sink (the layout's still working through measurements when `proxy.scrollTo` fires) and the tab-switch freeze (no real bounded-memory recycling). The fix path is to restore laziness (Steps 1-3) before considering more drastic options, because there is no better pure-SwiftUI primitive for our use case (`defaultScrollAnchor` doesn't support `List`; `LazyVStack` is what the prior research moved us off of; the inverted-scroll trick has too many edge cases). If after fixing the configuration we *still* freeze, the next step is `NSCollectionView` + `NSHostingConfiguration` via `NSViewRepresentable`, **not** retreating to `LazyVStack`. Going back to `LazyVStack` would re-introduce the original freeze without fixing anything.

---

## Sources

### Primary — laziness semantics
- Fatbobman, [Demystifying SwiftUI List Responsiveness — Best Practices for Large Datasets](https://fatbobman.com/en/posts/optimize_the_response_efficiency_of_list/) — `.id` modifier defeats laziness; ~100 views realized during scrollTo
- Fatbobman, [Discussing List and ForEach in SwiftUI](https://fatbobman.com/en/posts/swiftui-list-foreach/) — `List { ForEach }` initializes every row up-front; `List(data)` form is lazy
- Fatbobman, [List or LazyVStack — Choosing the Right Lazy Container](https://fatbobman.com/en/posts/list-or-lazyvstack/) — List doesn't maintain content height at SwiftUI level; intelligent realization during jumps
- Apple Developer Forums [thread/716063](https://developer.apple.com/forums/thread/716063) — FB11280425 (Aug 2022): `List { Section { ForEach } }` loads all rows at once
- Apple Developer Forums [thread/765203](https://developer.apple.com/forums/thread/765203) — FB15356563 (Sep 2024): Xcode 16+ regression broke `List(data)` laziness; unresolved as of Nov 2024
- Apple Developer Forums [thread/651256](https://developer.apple.com/forums/thread/651256) — "List contents are always loaded lazily" (WWDC20-10031), platform-dependent (less lazy on macOS historically)

### Primary — what underlies List on macOS 15
- Michael Tsai, [SwiftUI at WWDC 2025](https://mjtsai.com/blog/2025/06/18/swiftui-at-wwdc-2025/) — "On macOS 15, List does not use NSTableView for showing non-outline content anymore"; 6×/16× improvements via "improved scheduling and lazy loading rather than architectural change"; Gwendal Roué quote on Collection iteration
- Michael Tsai, [NSTableView With SwiftUI](https://mjtsai.com/blog/2024/04/15/nstableview-with-swiftui/) — historical context on NSTableView usage
- troz.net, [SwiftUI Lists](https://troz.net/post/2024/swiftui_lists/) — macOS Sequoia improvements still incremental; `.equatable()` row modifier as performance unlock; debug-vs-release distinction

### Primary — animation contract
- Apple Developer Forums [thread/735479](https://developer.apple.com/forums/thread/735479) — `proxy.scrollTo` only animates inside `withAnimation`; iOS 17 regression fixed in dev beta 7
- Hacking with Swift, [How to scroll to a specific row in a list](https://www.hackingwithswift.com/quick-start/swiftui/how-to-scroll-to-a-specific-row-in-a-list)
- Use Your Loaf, [Scrolling With ScrollViewReader](https://useyourloaf.com/blog/scrolling-with-scrollviewreader/)

### Primary — bottom-anchor patterns in OSS
- macai source: `macai/UI/Chat/ChatMessagesView.swift` (verified via `gh api` 2026-05-06) — `ScrollView { VStack }.defaultScrollAnchor(.bottom)`, content-readiness-gated initial scroll via `pendingCodeBlocks` count + `CodeBlockRendered` notifications
- IceCubes source: `Packages/Timeline/Sources/Timeline/View/TimelineListView.swift` — `ScrollViewReader { List { ScrollToView; ForEach } }`; uses scroll-to-top, not scroll-to-bottom; no `.id` per row
- Apple Developer Forums [thread/741406](https://developer.apple.com/forums/thread/741406) — `LazyVStack + defaultScrollAnchor(.bottom)` blank-on-reentry; rotation workaround (Jan 2025)
- Apple Developer Forums [thread/681833](https://developer.apple.com/forums/thread/681833) — bottom-first List request (Jun 2021, FB9148104), still unaddressed
- Swift with Vincent, [Building the inverted scroll of a messaging app](https://www.swiftwithvincent.com/blog/building-the-inverted-scroll-of-a-messaging-app) — rotation 180° + scaleEffect technique
- Fatbobman, [Evolution of SwiftUI Scroll Control APIs](https://fatbobman.com/en/posts/the-evolution-of-swiftui-scroll-control-apis/) — new scroll APIs explicitly don't support `List`

### Primary — AppKit escape hatch
- Apple [WWDC22 Use SwiftUI with AppKit](https://developer.apple.com/videos/play/wwdc2022/10075/) — `NSHostingConfiguration` for collection items
- Apple [NSCollectionViewFlowLayout estimatedItemSize](https://developer.apple.com/documentation/appkit/nscollectionviewflowlayout/estimateditemsize) — auto-sizing primitive
- flocked, [AdvancedCollectionTableView](https://github.com/flocked/AdvancedCollectionTableView) — modern cell-registration helper
- Brian Webster, [How NSHostingView Determines Its Sizing](https://www.tumblr.com/brian-webster/723846294121152512/how-nshostingview-determines-its-sizing) (cited via [Tsai](https://mjtsai.com/blog/2023/08/03/how-nshostingview-determines-its-sizing/))

### Supporting — community OSS chat clients
- Renset/macai — [GitHub](https://github.com/Renset/macai); source verified for `ChatMessagesView.swift` pattern
- Dimillian/IceCubesApp — [GitHub](https://github.com/Dimillian/IceCubesApp); `gh search` confirmed `List { ForEach }` shape across packages, no per-row `.id`
- jacobstechtavern, [SwiftUI Scroll Performance: The 120FPS Challenge](https://blog.jacobstechtavern.com/p/swiftui-scroll-performance-the-120fps) (May 2025) — List wins for infinite feeds on iOS, not macOS-tested

### Supporting — `Equatable` row optimization
- Hacking with Swift, [How to fix slow List updates in SwiftUI](https://www.hackingwithswift.com/articles/210/how-to-fix-slow-list-updates-in-swiftui) — `.equatable()` modifier
- troz.net, [SwiftUI Lists](https://troz.net/post/2024/swiftui_lists/) — `.equatable()` unblocks lazy realization in observed configurations
