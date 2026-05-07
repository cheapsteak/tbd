# Transcript pane: migrate from LazyVStack to List

## Why

After two weeks of incremental fixes against `LazyVStack` perf issues, the research at
`docs/superpowers/specs/research-2026-05-06-swiftui-long-list-perf.md` makes the case decisively: the bugs we keep hitting are intrinsic to `LazyVStack` for our shape of data (thousands of variable-height MarkdownUI rows), and the convergent OSS pattern is to use `List` instead. IceCubesApp — the canonical large-scale SwiftUI Mastodon client — uses `List` + `ScrollViewReader.proxy.scrollTo`, with no `scrollTargetLayout`, no `scrollPosition(id:)`, no `defaultScrollAnchor`. `List` on macOS 15 has real cell recycling backed by AppKit's collection-view machinery: rows realize when they enter the viewport AND **deallocate when they leave**. `LazyVStack` only does the former; it accumulates realized rows forever, which is why our session teardown/freeze-on-leave was bad.

The specific symptoms we've been chasing all map to known issues:

- **44s `StackLayout → _PaddingLayout` recursion hang**: cmux #2327, same shape. `scrollTargetLayout + scrollPosition(id:) + LazyVStack + variable-height rich rows` is a documented perf footgun (Fatbobman, Apple Developer Forums).
- **Blank-on-re-entry**: Apple Developer Forums thread #741406, specifically `LazyVStack + defaultScrollAnchor(.bottom)`.
- **MarkdownUI in LazyVStack**: multiple unfixed open issues (#310, #426, #445); maintainer put MarkdownUI in maintenance mode in early 2026 and started [Textual](https://github.com/gonzalezreal/textual) — citing this exact class of layout/perf problem as "architecturally unfixable" in MarkdownUI.

`List` doesn't have any of these issues, because it's not built on top of SwiftUI's StackLayout primitives that produced the recursion.

## Goal

A transcript pane that:
- Renders thousands of items without freezing on first paint, on scroll, or on tab leave/teardown.
- Lands at the bottom on first appearance, autoscrolls on new messages.
- Is robust under repeated tab navigation.

Out of scope (Phase 2):
- Preserving the user's scroll position across worktree switches. IceCubes doesn't do this; their feed model is different. Chat is different from a feed and we want this — but it's a non-trivial follow-up that depends on Phase 1's foundation. Doing it in the same change would couple the migration to a feature; we keep them separate.
- Caching MarkdownUI parses on the message model and using `.equatable()` row views. The research mentioned these as paired optimizations. They become straightforward once Phase 1 lands; defer.
- Migrating off MarkdownUI to Textual. Even though MarkdownUI is in maintenance mode, it works for our needs — the maintenance status doesn't break us, only freezes the library. A migration is a separate, larger project.

## Approach

Three coordinated edits, all in app-side SwiftUI code. Daemon untouched. Strategy: kill all four LazyVStack-ecosystem modifiers (`scrollTargetLayout`, `scrollPosition(id:)`, `defaultScrollAnchor`, the LazyVStack itself), replace with `List`, drive autoscroll via `ScrollViewReader.proxy.scrollTo`.

### `Sources/TBDApp/Panes/Transcript/TranscriptItemsView.swift`

The view is used at two depths: **depth == 0** is the top-level transcript stream (potentially thousands of items, the perf-critical path); **depth > 0** is a recursive call from `SubagentDisclosure` for nested subagent timelines (typically tens of items, inside a `DisclosureGroup`).

Only the depth-0 path uses `List`. Nested `Lists` don't compose well in SwiftUI; depth > 0 stays on a plain `VStack` (which is fine — those lists are short, and live inside an outer `List` row).

Final shape:

```swift
struct TranscriptItemsView: View {
    let items: [TranscriptItem]
    let terminalID: UUID?
    var depth: Int = 0

    var body: some View {
        if depth >= 8 {
            Text("… nested too deep")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
        } else if depth == 0 {
            // Top-level chat: List provides cell recycling, avoiding the LazyVStack
            // layout-cycle and accumulation issues for sessions with thousands of items.
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
        } else {
            // Nested subagent timeline (typically short, inside a DisclosureGroup).
            // VStack here so we don't nest Lists, which composes badly in SwiftUI.
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items) { item in
                    rowFor(item)
                }
            }
            .padding(.vertical, 8)
        }
    }

    // ... rowFor and toolCardFor unchanged
}
```

Per-row modifiers:
- `.listRowSeparator(.hidden)` — chat rows shouldn't have system separators between them.
- `.listRowInsets(EdgeInsets())` — kill the default leading/trailing/vertical padding `List` applies to rows. Each row's internal padding is set by `ChatBubbleView` / the tool-card views themselves.
- `.listRowBackground(Color.clear)` — let the parent's background show through (the worktree pane's background, not List's default `groupedBackground`).

List-level modifiers:
- `.listStyle(.plain)` — flat chat-style, not grouped.
- `.scrollContentBackground(.hidden)` — hide List's default scrollable background.
- `.environment(\.defaultMinListRowHeight, 1)` — without this, `List` applies a default min row height (~44pt typical) that would visibly pad short rows like `SystemReminderRow`.

### `Sources/TBDApp/Panes/LiveTranscriptPaneView.swift`

`transcriptWithAutoscroll` is currently:

```swift
ScrollViewReader { proxy in
    ScrollView {
        TranscriptItemsView(items: messages, terminalID: terminalID)
    }
    .defaultScrollAnchor(.bottom)
    .scrollPosition(id: $visibleID, anchor: .bottom)
    .onChange(of: messages.last?.id) { oldID, newID in
        guard let oldID, let id = newID, autoscrollEnabled else { return }
        _ = oldID
        withAnimation(.easeOut(duration: 0.15)) {
            visibleID = id
        }
    }
    .onAppear {
        Self.perfLog.debug("view.appear sid=\(short) count=\(count)")
        if let id = visibleID {
            proxy.scrollTo(id, anchor: .bottom)
        }
    }
}
```

Becomes:

```swift
ScrollViewReader { proxy in
    TranscriptItemsView(items: messages, terminalID: terminalID)
        .onAppear {
            Self.perfLog.debug("view.appear sid=\(short) count=\(count)")
            if let id = messages.last?.id {
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
        .onChange(of: messages.last?.id) { oldID, newID in
            guard let oldID, let id = newID, autoscrollEnabled else { return }
            _ = oldID
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
}
```

Concrete changes:

- **Remove the outer `ScrollView { ... }` wrapper.** `List` provides its own scrolling.
- **Remove `.defaultScrollAnchor(.bottom)`** — `List` doesn't honor this, and `proxy.scrollTo` on `.onAppear` provides equivalent behavior.
- **Remove `.scrollPosition(id: $visibleID, anchor: .bottom)`** — the documented perf footgun.
- **Remove the `@State private var visibleID: String?`** declaration. Keep nothing in its place; Phase 2 will reintroduce position tracking via `AppState`-backed storage.
- **Keep `ScrollViewReader { proxy in ... }`.** `proxy.scrollTo(_:anchor:)` works on `List` — IceCubes uses the same pattern.
- **`.onAppear` scrolls to `messages.last?.id`** instead of to `visibleID`. This is the regression the user already flagged ("starts at the bottom on navigate-back"); we accept it as Phase 1 behavior, ship Phase 2 to restore position preservation.
- **`.onChange(of: messages.last?.id)`** keeps the `nil → value` guard (still relevant — navigation transiently nils the messages array). Replace `visibleID = id` with `proxy.scrollTo(id, anchor: .bottom)`.
- **Keep the perf-transcript log.** Same diagnostic value going forward.

### `Sources/TBDApp/Panes/HistoryPaneView.swift`

The session-detail view currently has:

```swift
ScrollView {
    TranscriptItemsView(items: messages, terminalID: nil)
}
.defaultScrollAnchor(.bottom)
.scrollPosition(id: $visibleID, anchor: .bottom)
.onAppear {
    if let id = visibleID {
        proxy.scrollTo(id, anchor: .bottom)
    }
}
```

(Wrapped in `ScrollViewReader`.)

Becomes:

```swift
ScrollViewReader { proxy in
    TranscriptItemsView(items: messages, terminalID: nil)
        .onAppear {
            if let id = messages.last?.id {
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
}
```

Same shape. No `.onChange` (read-only), no `visibleID`.

### `Sources/TBDApp/Panes/Transcript/ChatBubbleView.swift`

Re-add the four `.fixedSize(horizontal: false, vertical: true)` calls in `Theme.chatBubble` that we removed in `2b890ef` (paragraph, blockquote HStack, table, tableCell). Outside of the `scrollTargetLayout + LazyVStack` combo that was the cycle trigger, these regain their original purpose: ensuring vertical sizing is correct for paragraphs, table cells, and blockquotes within their flexible parent contexts.

The `2b890ef` commit message even said "will re-add selectively if the user reports specific elements look wrong." This restoration is preemptive — the user already reported some markdown rendering looked off after `2b890ef`, and outside the `scrollTargetLayout` interaction there's no reason to keep them off.

## Risks

- **List styling drift.** `List` brings its own visual conventions (selection highlighting on hover, focus rings, etc.). `.listStyle(.plain) + .listRowSeparator(.hidden) + .listRowInsets(EdgeInsets()) + .listRowBackground(.clear)` should suppress all of these. If something visual looks off (e.g., faint hover highlights on rows), one or two more modifiers will likely fix it (`.selectionDisabled()`, `.contentMargins(.zero)`).
- **Row-internal alignment.** `List` rows wrap content in their own container; alignment may differ subtly from a plain `VStack`. Most likely-affected: `ChatBubbleView`'s leading/trailing alignment for user vs. assistant bubbles. The bubble view already uses `HStack { ... Spacer() ... }` for that, so it should still work, but verify.
- **`SubagentDisclosure` recursive rendering.** The recursive `TranscriptItemsView` at depth > 0 stays on `VStack`. Disclosure expand/collapse should still work — disclosure group internals don't care that the inner content is a `VStack`.
- **`textSelection(.enabled)` per row.** Selection still works inside `List` rows (verified in IceCubes).
- **Scroll-to-bottom on first paint.** `proxy.scrollTo(messages.last?.id, anchor: .bottom)` on `.onAppear` is the IceCubes pattern. With `List`'s cell recycling, this is cheap (only realizes the last screenful). No more 7-second freeze.
- **No more scroll-position preservation across worktree switches.** Explicit Phase-1 trade-off; the user already knows. Phase 2 will restore it.

## Verification

The `perf-transcript` instrumentation stays in place. Now the relevant timings should look like:

- `items.body → view.appear`: under ~100ms regardless of session size (List cell recycling, only screenful of rows realized).
- Tab leave: no perf regression because `List` deallocates rows as they leave the viewport — there's no large view tree to tear down.
- Scroll up: smooth. No layout-cycle hangs, no 44s freezes.

Visual checks (user-driven):

1. Open the maven-dashboard transcript: lands at the bottom. Smooth.
2. Scroll up through the entire transcript. No hangs. (This is the regression repro target.)
3. Switch worktrees and back. Re-entry shows content immediately (no blank gray panel). Position is at bottom (Phase 2 is when we preserve user position).
4. Send a new message in an active session. Snaps to bottom (existing autoscroll behavior, now via `proxy.scrollTo`).
5. Markdown content (tables in chat bubbles especially) renders correctly — no stretched cells, no missing borders, etc. If something looks off, that's the `.fixedSize` re-add to investigate.

## Suggested commit shape

One commit:

```
fix: migrate transcript pane from LazyVStack to List

LazyVStack on macOS 15 with thousands of variable-height MarkdownUI
rows is a documented perf footgun: 44s layout-cycle hangs on scroll
(StackLayout → _PaddingLayout → … recursion), blank-on-re-entry with
defaultScrollAnchor, and accumulation-without-eviction that makes
tab-leave teardowns multi-second. Research collected in
research-2026-05-06-swiftui-long-list-perf.md cites cmux #2327, Apple
Developer Forums #741406, and IceCubesApp's TimelineListView as the
convergent prior-art reference: use List, not LazyVStack.

List on macOS 15 has real cell recycling — rows realize on enter and
deallocate on exit — and is not built on the StackLayout primitives
that produced the layout cycle. Migrate the transcript pane:
LazyVStack → List, drop scrollTargetLayout / scrollPosition(id:) /
defaultScrollAnchor, restore proxy.scrollTo for autoscroll. Match
IceCubes' chat-list styling (.listStyle(.plain), hidden separators,
zero row insets, clear backgrounds, defaultMinListRowHeight 1).

The recursive nested-transcript path (SubagentDisclosure) stays on
VStack — nested Lists compose badly in SwiftUI, and those inner
timelines are short.

Re-add the four .fixedSize(horizontal: false, vertical: true) calls
in MarkdownUI's chat-bubble theme that were removed in 2b890ef.
Outside the scrollTargetLayout+LazyVStack combo, they regain their
original layout-fidelity purpose without triggering the cycle.

Trade-off (Phase 1): scroll position no longer preserves across
worktree switches; transcript opens at the bottom every time. Phase 2
will reintroduce position preservation via AppState-backed storage,
once this foundation is shipped and verified.
```
