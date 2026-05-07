# Research: prior art on SwiftUI long-list / chat-transcript performance

Date: 2026-05-06
Scope: macOS 15 (Sonoma+), SwiftUI, swift-markdown-ui rows in a transcript pane.
Method: WebSearch + WebFetch + `gh` against issue trackers and primary OSS repos.

## TL;DR

- **The convergent recommendation from mature OSS chat/timeline apps and Apple-aligned blog posts is: don't render thousands of variable-height markdown rows in a `LazyVStack` — use `List`.** IceCubes (the canonical large-scale SwiftUI Mastodon client, multi-platform incl. macOS) renders its timeline with `List { ... }.listStyle(.plain).environment(\.defaultMinListRowHeight, 1)` driven by `ScrollViewReader`+`proxy.scrollTo`, *not* `LazyVStack` and *not* `scrollTargetLayout`/`scrollPosition(id:)`. List uses `UICollectionView`/`NSTableView` under the hood with real cell recycling; `LazyVStack` does not free rows once realized.
- **`scrollTargetLayout` + `scrollPosition(id:)` on a long, dynamically-sized `LazyVStack` is a known performance footgun.** Fatbobman explicitly calls out "serious performance issues when the dataset is large" with these APIs (Jun 2023, updated Dec 2025). This matches the symptoms in the user's `StackLayout.placeChildren → sizeChildren → resize → sizeThatFits → placeChildren → ...` 44s spindump.
- **MarkdownUI itself amplifies this.** Multiple open issues in `gonzalezreal/swift-markdown-ui` document hangs and re-layout jumps when MarkdownUI is used inside `LazyVStack` (#186, #209, #310, #426, #445). The maintainer has put the library in **maintenance mode** in 2026 and is moving to a new library, **Textual**, citing exactly these layout/perf limits as the reason MarkdownUI's architecture cannot be incrementally fixed.
- **The community-tested mitigations, in descending order of maturity:** (1) move to `List` ; (2) keep `LazyVStack` but make rows fixed/known-height by hoisting variable content out and providing height hints; (3) drop down to `NSCollectionView`/`NSTableView` via `NSViewRepresentable` (Kean, AdvancedCollectionTableView, Apple's own WWDC22 "Use SwiftUI with AppKit" guidance for `NSHostingConfiguration` cells); (4) custom windowed renderer with `onScrollGeometryChange` + a hand-rolled `Layout` (nilcoalescing, March 2025).
- **Removing `.scrollTargetLayout()` (the in-flight experiment) is supported by the evidence**, but is unlikely to be sufficient on its own — the deeper problem is `LazyVStack` with MarkdownUI rows of unknown height. Plan for migrating the transcript pane to `List`.

## OSS projects worth studying

### 1. **Dimillian/IceCubesApp** — SwiftUI Mastodon client (iOS/macOS/iPadOS/visionOS)
- Repo: <https://github.com/Dimillian/IceCubesApp>
- Why relevant: A Mastodon home timeline is functionally equivalent to a chat transcript: thousands of rows, each containing markdown-ish rich text (HTML, custom emoji), images, and interactive cards. Multi-platform incl. macOS. Active and mature.
- **What they do:** `List`, not `LazyVStack`.
  - `Packages/Timeline/Sources/Timeline/View/TimelineListView.swift` (verified):
    ```swift
    ScrollViewReader { proxy in
      List {
        ScrollToView()...
        TimelineTagGroupheaderView(...)
        TimelineTagHeaderView(...)
        StatusesListView(...)
      }
      .id(client.id)
      .environment(\.defaultMinListRowHeight, 1)
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .onChange(of: viewModel.scrollToId) { _, newValue in
        if let newValue {
          proxy.scrollTo(newValue, anchor: .top)
          ...
        }
      }
      ...
    }
    ```
  - `Packages/StatusKit/Sources/StatusKit/List/StatusesListView.swift` is just a `ForEach` of `StatusRowView`s — no `LazyVStack`, no `ScrollView` wrapper. The outer `List` provides recycling.
  - **No usage of `scrollTargetLayout`, no `scrollPosition(id:)`, no `defaultScrollAnchor`** anywhere in the Timeline package. They use the older `ScrollViewReader` + `proxy.scrollTo(id, anchor: .top)`.
  - The only `LazyVStack` in the repo is in `Packages/StatusKit/.../AutoComplete/ExpandedView.swift` — a small autocomplete popover, not a timeline. Confirmed via `gh` API code search.
  - StatusKit rows use HTMLString and EmojiText (custom) rather than swift-markdown-ui directly for the body, but the principle holds: variable-height rich-text rows in a `List`.
- Lessons: this is the strongest single piece of prior art for our problem. They already faced the user's exact axis (big transcripts of variable-height rich-content rows, on macOS, in modern SwiftUI) and chose `List` + `ScrollViewReader`.

### 2. **gonzalezreal/swift-markdown-ui** — our actual dependency
- Repo: <https://github.com/gonzalezreal/swift-markdown-ui>
- README now says: *"Maintenance mode — new development in Textual: <https://github.com/gonzalezreal/textual>"*.
- The maintainer's announcement post (Discussion #437, Jan 2026) frames Textual as a response to "rendering rich text in SwiftUI — layout, selection, attachments, performance, and extensibility" limits *that cannot be incrementally fixed in MarkdownUI's existing architecture*. This is corroboration that MarkdownUI's perf characteristics under SwiftUI's layout system are a known-bad problem the author has now stopped trying to fix in the existing codebase.
- The maintainer's earlier explicit advice for `LazyVStack` use (#186, Feb 2023): provide an `ImageProvider` that produces fixed-height placeholders so row height does not change after image load — this prevents re-layout jumps. See [`Examples/Demo/Demo/LazyLoadingView.swift`](https://github.com/gonzalezreal/swift-markdown-ui/blob/main/Examples/Demo/Demo/LazyLoadingView.swift). (But this only addresses image-driven jumps, not the more fundamental cycle.)
- Relevant issues (also see "MarkdownUI inside LazyVStack" section below):
  - #426 (Oct 2025, OPEN) "swift-markdown-ui struggles with long Markdown text" — entire app freezes, reproduced in vanilla SwiftUI. Contributor MojtabaHs attributes it to "excessive nesting" and SwiftUI's `Environment` propagation; fix would require iOS 17+ `@Observable`.
  - #445 (Apr 2026, OPEN) — performance issue with deeply nested ordered/unordered lists. Comment from another user notes it's similar/duplicate of #426, still unresolved.
  - #310 (Apr 2024, OPEN) — "Severe hang when rendering a short markdown string with 6-level nested bullet points," 1–2 s hang on a small markdown string. Reduces to no-hang at 4 levels of nesting. Maintainer acknowledged but never fixed.
  - #209, #186 (closed but instructive): jumps and "shaking up and down" inside `LazyVStack` with MarkdownUI; resolved as "use a fixed-height image placeholder" or "you have nested vertical scrollers."

### 3. **GetStream/stream-chat-swift-ai** — commercial chat SDK with AI streaming UI
- Repo: <https://github.com/GetStream/stream-chat-swift-ai>
- Relevant because they specifically targeted the "stream Claude/ChatGPT-style markdown" use case, and ship a `StreamingMessageView`.
- They depend on `swift-markdown-ui` (so they hit the same library limits) and on John Sundell's `Splash` for code highlighting.
- Their "letter by letter animation, with a character queue" approach is interesting for streaming, but tangential to the static rendering perf question.
- Did not return clear evidence that they wrap rows in NSCollectionView/UITableView — appears to be standard SwiftUI containers. (Limited public source detail.)

### 4. **Dimillian/IceCubesApp** Discord/Slack/Telegram OSS macOS-SwiftUI clients — mostly absent
- Slack/Discord/Telegram do not have OSS SwiftUI macOS clients of any consequence as of 2026. Telegram-iOS exists but is UIKit and iOS-only. Most "SwiftUI Telegram clients" on GitHub are toy projects; not useful prior art.
- The closest pure-SwiftUI macOS chat OSS apps found (`alfianlosari/ChatGPTSwiftUI`, `Panl/AICat`, `zahidkhawaja/swiftchat`, `halavins/SwiftUI-Chat`) are smaller-scale and don't push the thousands-of-rows scenario; they won't have battle-tested patterns relevant here.

### 5. **flocked/AdvancedCollectionTableView** — `NSCollectionView`/`NSTableView` modernization
- Repo: <https://github.com/flocked/AdvancedCollectionTableView>; Swift Forums announcement: <https://forums.swift.org/t/introducing-advancedcollectiontableview-a-framework-for-nscollectionview-nstableview-ports-many-newer-uikit-apis/69305>
- Relevant because if/when we drop down to AppKit for the transcript pane, this library backports modern UICollectionView APIs (cell registration, content configurations including `NSHostingConfiguration` for SwiftUI cells) to AppKit.
- Combined with Apple's [WWDC22 "Use SwiftUI with AppKit"](https://developer.apple.com/videos/play/wwdc2022/10075/) (which introduced `NSHostingConfiguration` precisely so you can keep SwiftUI row views inside an `NSCollectionView`), this is the supported escape hatch on macOS.

### 6. **kean.blog: "...But Not NSTableView"** (Mar 2021, Alex Grebenyuk)
- URL: <https://kean.blog/post/not-list>
- Direct prior art for exactly the path "I had SwiftUI `List`; perf was unacceptable; I rewrote with `NSTableView`." Cites: List's automatic diffing breaks `fetchBatchSize`, no obvious cell reuse, navigation delays. Old (2021) but the underlying concern that List can't always hit native AppKit perf still appears in 2025 commentary.

### 7. **nilcoalescing.com — "Designing a custom lazy list in SwiftUI with better performance"** (Mar 2025)
- URL: <https://nilcoalescing.com/blog/CustomLazyListInSwiftUI/>
- Custom `Layout` + `onScrollGeometryChange` + view-identity recycling (fragment ID = index % maxVisibleRows). Notable as a recent macOS-flavored windowed-rendering pattern from a well-trafficked SwiftUI blog. Worth knowing as the most "modern" custom approach short of `NSCollectionView`.

### 8. **manaflow-ai/cmux issue #2327** — exact symptom prior art
- URL: <https://github.com/manaflow-ai/cmux/issues/2327> (2025)
- A SwiftUI sidebar (LazyVStack / ScrollView) entered an infinite layout recalculation loop, pegged 100% CPU, did not recover even after scrolling stopped. Captured stack: `__CFRunLoopDoObservers → NSRunLoop.flushObservers → NSHostingView.beginTransaction → ViewGraphRootUpdater.updateGraph → GraphHost.flushTransactions → AG::Subgraph::update → LazySubviewPlacements.placeSubviews → LazyStack.place`. **Causes identified**: (a) `ForEach(Array(tabManager.tabs.enumerated()))` allocates new array each layout pass → identity instability → full re-layout; (b) O(n²) work in the `ForEach` body; (c) fan-out of `@AppStorage` subscriptions across all visible items.
- Direct match for the user's "44 s SwiftUI layout hang while scrolling up" with a deep `StackLayout.placeChildren` cycle.

### 9. **chrysb/LazyVStackStutter**
- URL: <https://github.com/chrysb/LazyVStackStutter>
- Minimal repro of LazyVStack stuttering when "scrolling down then flicking back to top." Author's note (still in README) says this perf bug "is the only thing that's preventing SwiftUI from being used in more complex applications." Apple developer forums thread says this was *largely* fixed in iOS 17.4 — but reports persist on macOS / for variable-height content.

## Known SwiftUI pitfalls (with evidence)

### A. `LazyVStack` with variable-height rows: jumps and infinite-resize cycles
- Apple Developer Forums, [thread/685461](https://developer.apple.com/forums/thread/685461) — "[Critical Issue] Content with variable height in a LazyVStack" (Jul 2021, updated Feb 2024). OP confirms partial fix in iOS 17.4. Workarounds: hoist variable-height content out of the lazy stack, use `List`, stabilize ForEach.
- **Severity for our hang: HIGH.** Our rows include MarkdownUI bodies, code blocks, images, and tool-call cards — all variable height.

### B. `ScrollView { LazyVStack }` re-initializes all child views on a state change
- Apple Developer Forums, [thread/657902](https://developer.apple.com/forums/thread/657902) (filed FB8401910). OP found that toggling expanded state on one row called `init` on every row in a 500-row list. Author concluded `LazyVStack` is unsuitable; recommended `UICollectionView` via `UIViewRepresentable`.
- **Severity: HIGH** — even ignoring our hang, this argues against `LazyVStack` for our scale.

### C. `LazyVStack` + `defaultScrollAnchor(.bottom)` is fragile
- Apple Developer Forums, [thread/741406](https://developer.apple.com/forums/thread/741406) (Nov 2023 → Jan 2025) — for chat apps, `LazyVStack + defaultScrollAnchor(.bottom)` shows blank on re-entry until the user scrolls up. Workarounds: `ScrollPosition` API with `scrollTo(edge: .bottom)` in `.onAppear`; or 180° flip the entire list.
- **Severity for us: HIGH.** This is exactly TBD's *issue #2* (blank-on-re-entry) — independent confirmation it is a framework-level fragility, not user error.

### D. `scrollTargetLayout` + `scrollPosition(id:)` on large datasets has "serious performance issues"
- Fatbobman, [Deep Dive into the New Features of ScrollView in SwiftUI](https://fatbobman.com/en/posts/new-features-of-scrollview-in-swiftui5/) (Jun 2023, updated Dec 2025) — explicitly: *"there are still serious performance issues when the dataset is large"* with `scrollPosition(initialAnchor:)` and `scrollPosition(id:)`.
- **Severity: HIGH** for our particular `.scrollTargetLayout()` experiment. Fatbobman is one of the most authoritative SwiftUI bloggers and updated this specifically through 2025.

### E. Unstable `ForEach` data identity → full re-layout
- cmux #2327 (above): `ForEach(Array(...enumerated()))` allocates a fresh array each pass; LazyVStack thinks it's all-new and rebuilds.
- WWDC23 "Demystify SwiftUI Performance" — cites identity stability and avoiding work in `body` as primary perf levers.
- **Severity: MEDIUM-HIGH** — easy to get wrong; check our transcript code's ForEach signature.

### F. List on macOS specifically: AsyncImage re-fetching, slow updates
- "How to fix slow List updates in SwiftUI" (Hacking with Swift), and List-vs-LazyVStack benchmarks (Fatbobman, STRV) — agree that **as of iOS 18 / macOS 15, List has caught up and generally outperforms LazyVStack on memory and on long lists** (cell recycling). On older macOS (≤ 13) List was problematic; on Sonoma/Sequoia it's the safer default.
- **Severity for us: LOW now**; we target macOS 15+. List is a viable target.

## Workarounds the community uses

Ranked by maturity + adoption.

### 1. (Most adopted) Use `List` instead of `ScrollView { LazyVStack }`
- OSS evidence: IceCubesApp `TimelineListView.swift`. Apple Developer Forums consensus across multiple threads (685461, 657902, 690711). Donny Wals (May 2025), Fatbobman, jacobstechtavern (May 2025), STRV all converge on this.
- Behavior: List on macOS 15 wraps `NSTableView`/`UICollectionView`-style infrastructure with real cell recycling; rows leave memory when far off-screen.
- Caveats: less layout flexibility (List separators, insets, row backgrounds via `listRow*` modifiers, no easy "pinned bottom" anchor). Programmatic scrolling uses `ScrollViewReader` + `proxy.scrollTo(id, anchor: ...)` or `.scrollPosition(id:)` (latter exists on List too in iOS 18 / macOS 15, but proxy-based is the IceCubes-tested path).
- For chat-style "stick to bottom" UX, IceCubes-style + a programmatic `proxy.scrollTo(lastID, anchor: .bottom)` on append is the safest pattern.

### 2. Stabilize identity, hoist variable-height content out of `LazyVStack`, give rows fixed/predictable height
- Apple Developer Forums consensus. Maintainer of swift-markdown-ui specifically (#186) — fixed-height image placeholders.
- For our case: would require knowing or estimating each row's height before it's rendered, which is hard for arbitrary markdown + tables + code blocks.
- This buys us a partial fix for jump/jitter but **does not address the deep `placeChildren → sizeThatFits` cycle** if the cycle is rooted in MarkdownUI's internal layout.

### 3. Drop into `NSCollectionView` (or `NSTableView`) via `NSViewRepresentable`
- `NSHostingConfiguration` (WWDC22 "Use SwiftUI with AppKit") lets you keep SwiftUI cell views.
- `flocked/AdvancedCollectionTableView` modernizes cell registration on AppKit.
- Kean.blog "Not List" (2021) is the historical blueprint.
- This is the heaviest lift but is the sanctioned escape hatch for "I need real cell recycling, full control of layout, and known cell heights."
- Mastodon clients didn't go this far — `List` was enough for them. So this should be a last resort.

### 4. Custom windowed-rendering layout
- nilcoalescing (Mar 2025): `onScrollGeometryChange` + a custom `Layout` that places only visible rows; row identity recycling via `index % maxVisibleRows`.
- Pure-SwiftUI, no AppKit bridging. Newer; less battle-tested. Useful template if `List` constraints become a problem.

### 5. PreferenceKey-based "current visible row" + manual virtualization
- Older (2020-era) pattern. Largely superseded by `onScrollGeometryChange` + `scrollPosition`. Mentioned only because it appears in older blog posts; not recommended in 2026.

## Specific findings on MarkdownUI inside LazyVStack

Direct evidence from the swift-markdown-ui repo:

| Issue | Title | Status | Notes |
|---|---|---|---|
| [#186](https://github.com/gonzalezreal/swift-markdown-ui/issues/186) (Feb 2023) | "MarkdownUI is not usable inside LazyVStack" | CLOSED with workaround | Maintainer: only repros with images; provide a fixed-height ImageProvider placeholder. Workaround in [`LazyLoadingView.swift`](https://github.com/gonzalezreal/swift-markdown-ui/blob/main/Examples/Demo/Demo/LazyLoadingView.swift). Doesn't address text-driven re-layouts. |
| [#209](https://github.com/gonzalezreal/swift-markdown-ui/issues/209) (Apr 2023) | "MarkdownUI in LazyVStack inside ScrollView, page cannot scroll, layout shaking up and down" | CLOSED | Some cases caused by nested vertical scrollers, but multiple users (incl. djmango Mar 2024, gluonfield Apr 2024) say they hit it without nested scrollers. |
| [#310](https://github.com/gonzalezreal/swift-markdown-ui/issues/310) (Apr 2024) | "Severe hang ... 6-level nested bullet points" | OPEN | Hundreds of chars, 1–2 s hang. 5 levels still hangs; 4 levels does not. Maintainer acknowledged, never fixed. |
| [#426](https://github.com/gonzalezreal/swift-markdown-ui/issues/426) (Oct 2025) | "Performance issue: swift-markdown-ui struggles with long Markdown text" | OPEN | App freezes on a single moderate-length markdown blob. Contributor MojtabaHs (Nov 2025): cause is "excessive nesting" interacting with SwiftUI `Environment` propagation; fix requires `@Observable` and iOS 17+. |
| [#445](https://github.com/gonzalezreal/swift-markdown-ui/issues/445) (Apr 2026) | "Performance issue when rendering deeply nested ordered/unordered lists" | OPEN | Cross-references #426. |
| [Discussion #261](https://github.com/gonzalezreal/swift-markdown-ui/discussions/261) (Sep 2023) | "How to optimize performance for repeated rendering on live chat messages?" | UNANSWERED | OP describes streaming chat re-render storm; no answer from maintainer in 2.5 years. |
| [Discussion #437](https://github.com/gonzalezreal/swift-markdown-ui/discussions/437) (Jan 2026) | "Introducing Textual and future direction" | Maintainer announces MarkdownUI is in maintenance mode; cites "layout, selection, attachments, performance, and extensibility" limits as architectural and motivating Textual. |

**Implication:** MarkdownUI's per-row internal layout cost is non-trivial and the maintainer treats it as architectural. Even in a perfectly recycling `List`, each MarkdownUI row will still be expensive to size. Mitigations:
- Avoid deeply-nested lists in the rendered markdown (we don't fully control this — Claude transcripts can have nested lists).
- Cache the parsed `MarkdownContent` per row (parse once, in the row view-model, not in `body`).
- Consider migrating to **Textual** when it's stable enough — same author, designed to fix exactly these limits.
- Or consider a simpler "AttributedString from Markdown" path for messages without code blocks/tables, falling back to MarkdownUI only when needed.

## Recommendations for our specific problem

Given:
- LazyVStack + `.scrollTargetLayout()` + `.scrollPosition(id:)` + `.defaultScrollAnchor(.bottom)`
- Rows = MarkdownUI + code blocks + tool-call cards, variable height
- Long transcripts (1000s of items)
- macOS 15 (Sonoma)
- Symptom: 44 s `StackLayout.placeChildren → … → _PaddingLayout.sizeThatFits` cycle on scroll-up

**The evidence converges on a clear primary path: replace the `LazyVStack`/`scrollTargetLayout` with `List`.**

Concretely, in the order I'd attempt them:

1. **Phase 0 (already in flight): remove `.scrollTargetLayout()`.** Fatbobman explicitly flags its perf cost on large datasets, and we lose nothing by dropping it if we're not using `.scrollTargetBehavior(.viewAligned)`. Independent reasonable bet — but unlikely to be sufficient by itself.

2. **Phase 1: migrate the transcript pane to `List`.** This is the IceCubes-pattern, the Apple-Forum-consensus, and the Apple-blog-consensus path. Specifics:
   - `List { ForEach(messages, id: \.stableID) { row(for: $0) } }`
   - `.listStyle(.plain)`
   - `.environment(\.defaultMinListRowHeight, 1)` to suppress List's 44 pt minimum row height (IceCubes does this).
   - `.scrollContentBackground(.hidden)` so we keep our chat background.
   - `.listRowSeparator(.hidden)`, `.listRowBackground(...)`, `.listRowInsets(...)` to recover the visual chat-bubble look.
   - Replace `.defaultScrollAnchor(.bottom)` with `ScrollViewReader { proxy in List { ... } }` and call `proxy.scrollTo(lastID, anchor: .bottom)` in `.onAppear` and on `messages` append. This is what IceCubes does and fixes both the "blank on re-entry" issue and the layout cycle.
   - Verify: `ForEach`'s collection is the message array directly (not `Array(messages.enumerated())`) and the id is stable across recomputations. (cmux #2327 lesson.)

3. **Phase 2 (if Phase 1 isn't enough): row-level mitigations.**
   - Parse markdown once per message and cache the `MarkdownContent` on the message model — never call `Markdown(rawString)` from `body`.
   - Make each row's `View` `Equatable` and apply `.equatable()` (recommended by Hacking-with-Swift "How to fix slow List updates") so List can short-circuit re-renders.
   - For images, ensure fixed-height placeholders (MarkdownUI #186 maintainer guidance).
   - Audit deeply-nested bullet rendering — if Claude transcripts produce >5 levels, flatten or cap nesting (MarkdownUI #310, #426).

4. **Phase 3 (only if `List` + row mitigations still hangs): NSCollectionView via `NSViewRepresentable`.** With `NSHostingConfiguration` to keep SwiftUI row views. Use `flocked/AdvancedCollectionTableView` to avoid hand-rolling cell registration. This is the heaviest lift; reserve for last.

5. **Track Textual** (the swift-markdown-ui successor). If it ships a real public API and supports macOS by the time we're choosing a long-term direction, plan a migration. The maintainer specifically cited the layout/perf issues we're hitting as the reason for the rewrite.

**Things to deliberately avoid:**
- Don't try to "fix" `LazyVStack` perf with `.fixedSize()` / `.frame(minHeight:)` band-aids on rows. The community has tried and the consensus is it doesn't reliably break the cycle when rows truly need variable height.
- Don't write a custom `Layout` (nilcoalescing-style) until `List` has been ruled out; it's a much larger maintenance commitment than `List`.
- Don't keep both `.scrollPosition(id:)` *and* `.defaultScrollAnchor(.bottom)` — they fight for control of the scroll position and the combination is part of how we ended up with the blank-on-re-entry bug.

## Strongest single recommendation

Migrate the transcript pane from `LazyVStack` + `scrollTargetLayout` + `scrollPosition(id:)` + `defaultScrollAnchor(.bottom)` to `List` driven by `ScrollViewReader.proxy.scrollTo`, mirroring the IceCubesApp `TimelineListView` pattern (`List { … }.listStyle(.plain).environment(\.defaultMinListRowHeight, 1)` plus `.listRowSeparator(.hidden)` / `.listRowInsets(...)` for chat styling). This is the single most evidence-supported change: it directly addresses the `_PaddingLayout.sizeThatFits → StackLayout.placeChildren → …` recursion (because `List` doesn't compute total content height in SwiftUI's layout system the way `LazyVStack` does), it fixes the blank-on-re-entry behavior (no anchor fight; programmatic `scrollTo(lastID, anchor: .bottom)` is reliable), and it recovers real cell recycling (rows leave memory when scrolled far away, instead of accumulating in `LazyVStack`'s realized set). Pair it with a one-time parse of MarkdownUI content per message and `.equatable()` row views, and consider planning a follow-up migration to Textual once it stabilizes — the same swift-markdown-ui maintainer has explicitly retired MarkdownUI in maintenance mode citing the exact layout/performance limits we are hitting.

## Sources

- IceCubesApp Timeline (List): <https://github.com/Dimillian/IceCubesApp/blob/main/Packages/Timeline/Sources/Timeline/View/TimelineListView.swift>
- IceCubesApp StatusesListView: <https://github.com/Dimillian/IceCubesApp/blob/main/Packages/StatusKit/Sources/StatusKit/List/StatusesListView.swift>
- swift-markdown-ui repo / maintenance-mode README: <https://github.com/gonzalezreal/swift-markdown-ui>
- swift-markdown-ui issues: [#186](https://github.com/gonzalezreal/swift-markdown-ui/issues/186), [#209](https://github.com/gonzalezreal/swift-markdown-ui/issues/209), [#310](https://github.com/gonzalezreal/swift-markdown-ui/issues/310), [#426](https://github.com/gonzalezreal/swift-markdown-ui/issues/426), [#445](https://github.com/gonzalezreal/swift-markdown-ui/issues/445)
- swift-markdown-ui discussions: [#261 streaming chat perf](https://github.com/gonzalezreal/swift-markdown-ui/discussions/261), [#437 Textual announcement](https://github.com/gonzalezreal/swift-markdown-ui/discussions/437)
- Apple Developer Forums:
  - [thread/685461 — Variable height in LazyVStack (critical)](https://developer.apple.com/forums/thread/685461)
  - [thread/657902 — ScrollView+LazyVStack perf (FB8401910)](https://developer.apple.com/forums/thread/657902)
  - [thread/690711 — LazyVStack flickers when scrolling](https://developer.apple.com/forums/thread/690711)
  - [thread/741406 — LazyVStack + defaultScrollAnchor(.bottom) blank-on-reentry](https://developer.apple.com/forums/thread/741406)
- Apple WWDC23 [Demystify SwiftUI performance](https://developer.apple.com/videos/play/wwdc2023/10160/)
- Apple WWDC22 [Use SwiftUI with AppKit (NSHostingConfiguration)](https://developer.apple.com/videos/play/wwdc2022/10075/)
- Apple [Creating performant scrollable stacks](https://developer.apple.com/documentation/swiftui/creating-performant-scrollable-stacks)
- Fatbobman, [Deep Dive into the New Features of ScrollView in SwiftUI](https://fatbobman.com/en/posts/new-features-of-scrollview-in-swiftui5/) (Jun 2023, upd Dec 2025) — `scrollTargetLayout`/`scrollPosition` perf warning
- Fatbobman, [List or LazyVStack — Choosing the Right Lazy Container](https://fatbobman.com/en/posts/list-or-lazyvstack/) — benchmarks
- jacobstechtavern, [SwiftUI Scroll Performance: The 120FPS Challenge](https://blog.jacobstechtavern.com/p/swiftui-scroll-performance-the-120fps) (May 2025) — List wins for infinite feeds
- Donny Wals, [Choosing between LazyVStack, List, and VStack in SwiftUI](https://www.donnywals.com/choosing-between-lazyvstack-list-and-vstack-in-swiftui/) (May 2025)
- Kean (Alex Grebenyuk), [...But Not NSTableView](https://kean.blog/post/not-list) (Mar 2021) — historical NSTableView replacement story
- nilcoalescing, [Designing a custom lazy list in SwiftUI with better performance](https://nilcoalescing.com/blog/CustomLazyListInSwiftUI/) (Mar 2025) — windowed renderer pattern
- manaflow-ai/cmux issue [#2327 — Sidebar scroll triggers infinite SwiftUI layout loop](https://github.com/manaflow-ai/cmux/issues/2327) — direct symptom match
- chrysb [LazyVStackStutter repro repo](https://github.com/chrysb/LazyVStackStutter)
- process-one, [Writing a Custom Scroll View with SwiftUI in a chat application](https://www.process-one.net/blog/writing-a-custom-scroll-view-with-swiftui-in-a-chat-application/) (Oct 2019, historical)
- flocked, [AdvancedCollectionTableView](https://github.com/flocked/AdvancedCollectionTableView) and [Swift Forums announcement](https://forums.swift.org/t/introducing-advancedcollectiontableview-a-framework-for-nscollectionview-nstableview-ports-many-newer-uikit-apis/69305)
- GetStream, [stream-chat-swift-ai](https://github.com/GetStream/stream-chat-swift-ai) — depends on swift-markdown-ui
- Hacking with Swift, [How to fix slow List updates in SwiftUI](https://www.hackingwithswift.com/articles/210/how-to-fix-slow-list-updates-in-swiftui) — `Equatable` + `.equatable()` modifier
