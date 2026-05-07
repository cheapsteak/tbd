# Research: SwiftUI ZStack event leakage to opacity-0 views on macOS

Date: 2026-05-06
Target: macOS 15 (Sequoia), SwiftUI keep-alive pattern using `ZStack` + `.opacity` + `.allowsHitTesting`.

## TL;DR

- **`.allowsHitTesting(false)` does NOT reliably block AppKit-level scroll-wheel events on macOS.** The modifier participates in SwiftUI's hit-test plumbing, but the underlying AppKit hit-test that `NSWindow.sendEvent(_:)` performs for scroll wheel routing is not fully driven by it. macOS 15 made this much worse: `_hitTestForEvent` is the single dominant cost in scroll handling and hit-tests the entire view tree thousands of times per scroll. This is consistent with our symptoms (slow scroll on the active view, scroll events delivered to the inactive worktree's terminal NSView).
- **Opacity 0 is fundamentally not the same as hidden in AppKit.** `NSView.alphaValue == 0` does NOT exclude a view from `hitTest(_:)`. Only `isHidden == true` (and a zero `frame` size, and `isUserInteractionEnabled == false` on iOS) reliably remove a view from hit-testing. SwiftUI's `.opacity(0)` lowers to `alphaValue` rather than `isHidden`.
- **The two known fixes for scroll-wheel leakage are: `.hidden()` (which DOES yield SwiftUI views that don't participate in events) or NSViewRepresentable wrappers that override `hitTest` / `scrollWheel`.** `.scrollDisabled(true)` is environmental and propagates to descendant `ScrollView`s, but it does NOT do anything for embedded `NSScrollView`/SwiftTerm views, and it does not stop AppKit hit-tests against the inactive subtree.
- **`TabView` on macOS appears to do this correctly for its own content** because internally it is backed by `NSTabView`, which keeps inactive tabs as live but hidden subviews (`isHidden = true`) — so they're skipped in `hitTest`. The hidden-tab trick is the closest "official" pattern for keep-alive without event leakage.
- **Recommendation for our situation:** drop `.opacity(0)` in favor of conditional `.hidden()` on inactive worktrees, OR wrap each `SingleWorktreeView` in an `NSViewRepresentable` that toggles `isHidden` on its underlying `NSView` when inactive. If we want to stay declarative, switching the `ZStack` to a hidden-styled `TabView` is the lowest-risk path. Pure `.opacity(0)` keep-alive is a dead end on macOS 15.

---

## Confirmed: does `.allowsHitTesting(false)` block scroll-wheel events?

### Short answer

**No, not reliably on macOS, especially not for scroll-wheel events delivered into an embedded `NSScrollView` or other `NSViewRepresentable`.**

### Evidence

1. **Public radar FB9022612 — "ScrollView overrides allowsHitTesting property of underlying views"** ([openradar entry][openradar-fb9022612], surfaced in search results for the SwiftUI hit-test override behavior). The radar documents that on macOS, putting hit-test-disabled content inside a `ScrollView` causes `allowsHitTesting(false)` to be ignored. The radar specifically notes the bug does not reproduce on iOS. This is a long-standing macOS-specific divergence between the SwiftUI modifier's documented behavior and the AppKit-layer reality.

2. **Apple Developer Forums — "SwiftUI HitTesting cannot be disabled" ([thread/670198][forum-670198])**. A `Rectangle().allowsHitTesting(false)` overlaid on a `ScrollView` blocks pan-to-scroll and Toggle interaction. The thread received no Apple acknowledgment and no clean workaround; the consensus is that `.allowsHitTesting` participates in SwiftUI's gesture layer but not necessarily in AppKit's responder/hit-test path.

3. **Apple Developer Forums — "SwiftUI ScrollView performance in macOS 15" ([thread/764264][forum-764264])**. Apple-acknowledged regression (FB15241636) in macOS 15.0–15.3 where `_hitTestForEvent` consumed 70–85% of scroll-event processing time, causing 300ms response delays and "thousands of hitTest calls per scroll event" on M3 Max. Confirmed by multiple developers, partially fixed in 15.4 beta. This means **macOS 15's scroll wheel pipeline drives extremely aggressive hit-testing through the entire SwiftUI subtree**, including inactive subtrees that are merely opacity-0. Combined with point 1, this explains exactly the perf symptom we're seeing on the active view: the framework is hit-testing the inactive `LazyVStack` for every scroll event too.

4. **AppKit Cocoa Event Handling Guide ([Event Architecture][cocoa-event-arch])**. NSWindow.sendEvent dispatches mouse-class events (which scroll wheel is) by calling `hitTest(_:)` on the content view and forwarding to **the lowest descendant under the cursor**, not to the first responder. So whichever `NSView` is geometrically under the cursor wins, regardless of SwiftUI's view-tree opinions. SwiftUI's `.allowsHitTesting(false)` does not change the underlying `NSView`'s response to AppKit-layer hit-tests.

5. **Apple Developer Forums — "NSViewRepresentable, NSScrollView and missing mouse events" ([Swift Forums][swift-nsview-rep])**. Consistent reports that mouse events are routed by AppKit hit-testing irrespective of SwiftUI modifier wrapping; the only fix is to manipulate the underlying `NSView` directly.

### Platform / version differences

- **iOS / iPadOS:** `.allowsHitTesting(false)` reliably blocks gestures, including pan-induced scrolls, because UIKit's `hitTest(_:with:)` returns nil for `isUserInteractionEnabled == false` and the SwiftUI bridge sets that. UIKit does not have a peer to AppKit's scroll-wheel-via-hitTest path.
- **macOS 14 (Sonoma):** Hit-test cost was much lower; the leakage was theoretically present but rarely observable for normal apps. `.allowsHitTesting` mostly "looked right" by accident.
- **macOS 15 (Sequoia):** The hit-test storm exposes the leakage as serious perf regressions, and the bug ([forum-764264][forum-764264]) is officially acknowledged. macOS 15.4 beta improved it but the architectural issue with opacity-0 keep-alive remains.

---

## What primitives actually block scroll-wheel and AppKit-delivered events?

### `.disabled(true)`
Sets a generic SwiftUI environment value `isEnabled = false`. SwiftUI controls (`Button`, `TextField`, `Toggle`, `ScrollView` after iOS 16/macOS 13 — see `scrollDisabled` below) respect it, but **`.disabled` is NOT propagated as `NSView.isHidden`** and does not block scroll-wheel events on a SwiftTerm-style `NSViewRepresentable`. It also does not remove the view from the AppKit hit-test path. Useful for keyboard/input but not a scroll-wheel solution.

### `.scrollDisabled(true)` (iOS 16 / macOS 13+)
Documented at [scrollDisabled(_:)][docs-scrolldisabled]. Sets the `isScrollEnabled` environment value, which all SwiftUI `ScrollView`/`List` descendants observe. **Two key limitations:**
- It only affects SwiftUI scrollable views. Our embedded SwiftTerm `NSView` (and any other `NSViewRepresentable` wrapping `NSScrollView`) **does not observe this environment** and will keep handling its own `scrollWheel(with:)`.
- Even on the SwiftUI `ScrollView` it disables scrolling but doesn't remove the view from AppKit hit-testing — the hit-test storm continues.

So `.scrollDisabled(true)` is necessary-but-not-sufficient: it stops the active SwiftUI ScrollView in the inactive subtree from responding, but does nothing for the SwiftTerm NSView leakage.

### `.hidden()`
This is the underrated answer. In SwiftUI, `.hidden()` is documented as removing the view from layout participation visually but **its lower-level effect on macOS is to set `NSView.isHidden = true` on the bridging host view**. Per AppKit docs and consistent across `hitTest(_:)` discussions ([CocoaDev ScrollWheelInNSView][cocoadev-scrollwheel], Eon's hit testing post, multiple sources):
- `hitTest(_:)` **skips views with `isHidden == true`**.
- `hitTest(_:)` **does NOT skip views with `alphaValue == 0`**.
- Therefore `.hidden()` does block AppKit-layer scroll wheel routing into that subtree.

**The catch**: `.hidden()` in SwiftUI is binary — there is no "hidden but keep-state" doc guarantee. In practice, SwiftUI does keep `.hidden()` views in its own state graph (the view's identity persists, `@StateObject` survives), so for keep-alive purposes it is largely equivalent to `.opacity(0)` — but with the crucial event-blocking behavior we want. The Swift Forums "Replicating TabView view hierarchy behavior" thread ([forum.swift.org/t/64872][forums-64872]) explicitly hypothesizes that `TabView` uses `.hidden()` plus PreferenceKey ferrying for exactly this reason.

**Empirical note**: there is some cargo-cult belief that `.hidden()` "removes the view from the hierarchy." That's not what it does. Going to `if isActive { content }` versus `content.hidden()` is the real difference; `.hidden()` keeps the SwiftUI view alive but maps to `NSView.isHidden = true` for the host.

### `.frame(width: 0, height: 0)`
Reduces the view to a zero-size rectangle. AppKit's `hitTest(_:)` short-circuits when the point is not in the view's bounds. **This works** for blocking scroll wheel, but it visibly collapses layout, breaks `LazyVStack` realization (children are no longer in any visible viewport), and destroys the keep-alive property we need (off-screen content unloads, ScrollView contentOffset resets in some cases). Not a viable approach for our use case.

### Summary table

| Primitive                        | Blocks SwiftUI gestures | Blocks AppKit scroll-wheel into NSViewRepresentable | Preserves view state | Notes |
|---------------------------------:|:-----------------------:|:---------------------------------------------------:|:--------------------:|:------|
| `.opacity(0)` only               | No                      | No                                                  | Yes                  | Current; the bug                       |
| `.allowsHitTesting(false)`       | Mostly, except in ScrollView | No                                            | Yes                  | rdar FB9022612 — known broken in ScrollViews |
| `.disabled(true)`                | Yes (SwiftUI controls)  | No                                                  | Yes                  | Not relevant for scroll-wheel          |
| `.scrollDisabled(true)`          | Stops scrolling in SwiftUI ScrollView | No (NSScrollView untouched)            | Yes                  | Necessary but not sufficient           |
| `.hidden()`                      | Yes                     | **Yes** (maps to `NSView.isHidden`)                  | Yes (in practice)    | The right answer                       |
| `.frame(width:0, height:0)`      | Yes                     | Yes                                                 | No (LazyVStack drops) | Breaks our keep-alive goal             |
| Conditional `if active { ... }`  | Yes                     | Yes                                                 | No (full unmount)    | Defeats keep-alive                     |
| NSViewRepresentable host that toggles `isHidden` | Yes      | Yes                                                 | Yes                  | Most explicit fix                      |

---

## How OSS macOS SwiftUI apps handle keep-alive without event leakage

### Pattern 1 — `TabView` with hidden tab UI (most common)

Apple's own `TabView` keeps non-active tabs alive as `NSTabViewItem`s, which on macOS are backed by `NSTabView` and use `isHidden = true` internally for inactive tabs. Apple lazily builds tab content on first selection (since iOS 18 / macOS 15) and then keeps each built tab indefinitely. The Apple Developer Forums thread on [TabView reload behavior][forum-tabview] describes this caching contract; the Kristaps Grinbergs "hidden secrets of TabView" article ([kristaps.me/blog/swiftui-tabview][kristaps-tabview]) confirms inactive tabs preserve `@State`.

Several OSS apps follow this pattern with the visible tab strip suppressed via `PageTabViewStyle` / `.toolbar(.hidden, for: .tabBar)` (iOS 16+) / custom NSTabView wrapping. On macOS the standard `.tabViewStyle(.automatic)` shows a segmented tab strip; getting it fully invisible reliably requires either:
- Using a custom `NSTabViewController`-based representable (preserves NSTabView's keep-alive + `isHidden` semantics), or
- Layering a custom strip over `TabView` and just using its content area.

The Apple Developer Forums [thread/784248][forum-784248] discusses the pain of hiding the macOS tab bar — it's not first-class supported with toolbar modifiers on macOS the way it is on iOS.

### Pattern 2 — `StatefulTabView` / community packages

[`StatefulTabView`][stateful-tabview] (Nicholas Bellucci) wraps `UITabBarController` for iOS to expose explicit "keep all tabs alive" semantics. There is no clean macOS analogue in the package ecosystem; macOS apps either accept TabView's defaults or roll their own.

### Pattern 3 — `ZStack` + `.hidden()` (the right manual pattern)

The Swift Forums thread [Replicating TabView view hierarchy behavior][forums-64872] explicitly arrives at the conclusion that the closest manual replication of TabView keep-alive is:

```swift
ZStack {
    ForEach(ids) { id in
        Content(id: id)
            .opacity(id == active ? 1 : 0)   // visual
            .allowsHitTesting(id == active)  // SwiftUI gestures
            // Plus the missing piece for macOS scroll wheel:
            // hidden when inactive
    }
}
```

…with the `hidden()` modifier applied via something like `.modifier(VisibilityModifier(isVisible: id == active))` so the inactive ones map to `isHidden = true` on their host `NSView`. That last piece is the specific upgrade the thread converges on, citing the `NSTabView` precedent.

### Pattern 4 — ManagedWindow / multi-window scenes

For Mac-native workflows, [`pd95/SwiftUI-macos-HandleWindow`][pd95-handlewindow], [`shufflingB/swiftui-macos-windowManagment`][shuffling-window], and Apple's [Bring multiple windows][apple-multiwindow] sample treat each "tab/document" as a separate `WindowGroup` window. Each window has its own NSWindow and event routing — there is no leakage because there's no shared parent. This is overkill for our case (we want a single window with switchable content) but worth noting as the architecturally cleanest solution if we ever pivot.

### What we did NOT find

- No mature OSS macOS SwiftUI app deliberately uses pure `ZStack` + `.opacity` + `.allowsHitTesting` for keep-alive of complex content with embedded `NSViewRepresentable`s. The closest patterns either rely on `TabView` (i.e., `NSTabView`'s `isHidden`) or per-window scenes.
- No evidence of a `.zIndex` / `.background` / `.overlay` workaround for the scroll-wheel leakage. zIndex affects SwiftUI's render order, not AppKit hit-testing.

---

## TabView as an alternative

### What it does right

- Keeps non-selected tabs alive (`@State`/`@StateObject` preserved across switches) — verified by Apple Developer Forums and by the lifecycle docs ([Apple TabView docs][docs-tabview]).
- Internally backed by `NSTabView` on macOS. `NSTabView`'s inactive tab views are `isHidden = true`, which **AppKit hit-tests skip**. So scroll-wheel events should not leak across tabs in a stock `TabView`.
- Programmatic switching with `selection: $binding` is fully supported and we can drive it from `selectedWorktreeIDs.first`.

### Caveats / sharp edges

- **Hiding the macOS tab bar is not first-class.** The SwiftUI `.toolbar(.hidden, for: .tabBar)` modifier does not work on macOS. To get a totally invisible tab strip on macOS you typically need to either accept a thin tab strip styled minimally, or build a custom `NSViewControllerRepresentable` over `NSTabViewController` with `tabPosition = .none`.
- **Lazy-by-first-visit, not eager-build.** As of iOS 18 / macOS 15, `TabView` builds each tab on first selection. If we want all worktrees realized up-front we'd need to programmatically select-then-deselect each in sequence at startup, OR live with first-switch latency.
- **`@SceneStorage` and tab identity.** TabView ties identity to `.tag(...)`, so `selectedWorktreeIDs` switching needs the tag to be the worktree UUID. This is fine for our model but worth flagging.
- **Custom view modifiers / environment values** sometimes don't propagate the same way through `TabView`'s internal tab containers as through a `ZStack`. Toolbars, focus, and key commands have all had reported issues.

### Could we drop in `TabView` here?

Probably yes, with two adjustments:
1. Use an explicit `NSViewControllerRepresentable` wrapper around `NSTabViewController` with `tabStyle = .unspecified` and `tabPosition = .none` so the tab strip is totally invisible. This bypasses SwiftUI's macOS tab bar UI entirely while keeping `NSTabView`'s correct event semantics.
2. Bind selection to `activeWorktreeID` and tag each worktree view with its UUID.

This gets us the event-handling correctness "for free" because `NSTabView` does the right thing with `isHidden`.

---

## AppKit responder chain fundamentals (relevant subset)

- `NSWindow.sendEvent(_:)` for mouse-class events (including `scrollWheel:`) calls `hitTest(_:)` on the content view to find the deepest descendant containing the cursor, and dispatches to that view. **It is not the first responder that gets the scroll-wheel event** — it is the view under the cursor.
- `hitTest(_:)` skips views where `isHidden == true`. It does not skip views where `alphaValue == 0`. (Apple's `NSView.hitTest` discussion + the alphaValue documentation make this explicit; multiple developer write-ups confirm.)
- Once `NSScrollView` has begun a tracking gesture, subsequent scroll wheel events for that gesture are NOT individually hit-tested — they're delivered to the same NSScrollView until the gesture ends. ([WWDC 2013 session 215, Optimizing Drawing and Scrolling on OS X][wwdc-2013-215].) This explains why "the wrong terminal scrolls": once a scroll gesture began over (or routed to) the inactive worktree's NSScrollView, the entire gesture stays there even though the cursor is over the active worktree.
- **Removing a subview from the responder chain without removing it from the view hierarchy**: set `isHidden = true` on the subview (and ideally `nextResponder` is left intact so other paths still work). Setting `alphaValue = 0` does NOT remove it. There is no public "skip me in event delivery but draw me" flag; `isHidden` is the canonical mechanism.

If we wrap each `SingleWorktreeView` in an `NSViewRepresentable` whose `updateNSView` toggles `nsView.isHidden = !isActive`, that achieves explicit responder-chain control while preserving SwiftUI keep-alive semantics for the wrapped subtree.

---

## Recommendations for our specific situation

Ordered by effort/risk; pick one.

### Option A — Replace `.opacity(0)` with `.hidden()` on inactive worktrees (Lowest effort, recommended first)

```swift
ZStack {
    ForEach(worktreeIDs, id: \.self) { id in
        SingleWorktreeView(worktreeID: id)
            .opacity(id == activeWorktreeID ? 1 : 0)         // keep for transition crossfades if any
            .allowsHitTesting(id == activeWorktreeID)
            .modifier(InactiveHiddenModifier(isActive: id == activeWorktreeID))
    }
}

private struct InactiveHiddenModifier: ViewModifier {
    let isActive: Bool
    func body(content: Content) -> some View {
        if isActive { content } else { content.hidden() }
    }
}
```

`.hidden()` keeps the SwiftUI view in the hierarchy (preserving `@StateObject` and `LazyVStack` realization state) but maps to `NSView.isHidden = true`, which AppKit's hit-test skips — blocking scroll wheel leakage into both SwiftUI ScrollViews and the SwiftTerm NSView.

**Risk**: I cannot 100% guarantee `.hidden()` always lowers to `isHidden` for every host view in the SwiftUI macOS bridge across all OS versions. There's some chance SwiftUI implements `.hidden()` as `alphaValue = 0` plus an internal flag, in which case this fix would not help. **Verify with Instruments** by checking whether `_hitTestForEvent` cost on the active worktree drops to baseline after this change, and by manually scrolling over the active worktree to confirm the SwiftTerm of the inactive worktree no longer scrolls.

### Option B — NSViewRepresentable wrapper that explicitly toggles `isHidden`

If Option A's `.hidden()` doesn't block scroll wheel reliably on macOS 15, wrap each `SingleWorktreeView`'s root in an explicit AppKit container:

```swift
struct ActivityGate<Content: View>: NSViewRepresentable {
    let isActive: Bool
    let content: () -> Content

    func makeNSView(context: Context) -> NSHostingView<Content> {
        NSHostingView(rootView: content())
    }

    func updateNSView(_ view: NSHostingView<Content>, context: Context) {
        view.rootView = content()
        view.isHidden = !isActive
    }
}
```

Then:
```swift
ZStack {
    ForEach(worktreeIDs, id: \.self) { id in
        ActivityGate(isActive: id == activeWorktreeID) {
            SingleWorktreeView(worktreeID: id)
        }
    }
}
```

`isHidden = true` is the canonical AppKit signal that `hitTest(_:)` must skip the subtree. Scroll wheel events cannot reach the SwiftTerm `NSView` inside a hidden `NSHostingView`. **Risk**: NSHostingView has its own quirks (sizing, autolayout participation, environment ferrying); some SwiftUI environment values won't cross the bridge cleanly. Test focus, key bindings, and environment objects.

### Option C — Replace `ZStack` with `TabView`

If Options A/B both miss subtle event paths (e.g., key event routing), use the OS-blessed mechanism. Wrap `NSTabViewController` directly to fully suppress the tab strip:

```swift
struct InvisibleTabContainer<Content: View>: NSViewControllerRepresentable {
    @Binding var selection: UUID
    let items: [(UUID, () -> Content)]

    func makeNSViewController(context: Context) -> NSTabViewController {
        let vc = NSTabViewController()
        vc.tabStyle = .unspecified           // hide segmented control
        vc.transitionOptions = []
        return vc
    }

    func updateNSViewController(_ vc: NSTabViewController, context: Context) {
        // sync vc.tabViewItems with items, then vc.selectedTabViewItemIndex = ...
    }
}
```

This is the "do what TabView does" path with full control over the chrome. **Risk**: ~150 lines of NSTabViewController bridging code, and SwiftUI environment/focus subtleties still need attention. Highest correctness, highest implementation cost.

### Option D — Revert keep-alive entirely

If the bug surface keeps growing, accept that SwiftUI macOS 15 is hostile to this pattern and rebuild scroll-position / `LazyVStack` realization preservation on top of explicit ViewModels (cache scroll offsets, eagerly load N transcripts). This is architecturally simpler but loses the "instant tab switch" feel.

### Side-recommendations regardless of option

- Add `.scrollDisabled(id != activeWorktreeID)` to inactive SwiftUI `ScrollView`s. Cheap insurance, costs nothing.
- File a feedback report with Apple referencing FB15241636 (macOS 15 scroll perf) and FB9022612 (allowsHitTesting + ScrollView), specifically calling out the keep-alive use case.
- Once a fix lands, verify with `log stream --level debug --predicate 'subsystem == "com.tbd.app"'` plus an Instruments scroll trace; the `_hitTestForEvent` percentage on the active worktree should drop substantially.

---

## Bottom line

We should not keep pursuing the pure `.opacity(0)` + `.allowsHitTesting(false)` keep-alive pattern. It is structurally incompatible with how AppKit routes scroll-wheel events on macOS 15: opacity is not a signal AppKit hit-testing respects, `.allowsHitTesting` is overridden inside ScrollViews and bypassed by NSViewRepresentable scroll handling, and macOS 15 made the underlying hit-test storm orders of magnitude worse. Try Option A first (a one-line `.hidden()` modifier swap) — it's the smallest possible change and on paper should fix both the SwiftUI ScrollView lag and the SwiftTerm scroll-leakage. If `.hidden()` does not in practice lower to `NSView.isHidden = true` on macOS 15 (verify with Instruments), escalate to Option B (explicit NSHostingView wrapper toggling `isHidden`) or Option C (NSTabViewController-backed container), in that order. Keep `TabView` (Option C) as the long-term destination because it's what Apple's own framework uses to solve this exact problem, and the few macOS-specific awkwardnesses (hiding the tab strip) are bounded.

---

[openradar-fb9022612]: https://openradar.appspot.com/FB9022612
[forum-670198]: https://developer.apple.com/forums/thread/670198
[forum-650433]: https://developer.apple.com/forums/thread/650433
[forum-742868]: https://developer.apple.com/forums/thread/742868
[forum-764264]: https://developer.apple.com/forums/thread/764264
[forum-728600]: https://developer.apple.com/forums/thread/728600
[forum-tabview]: https://developer.apple.com/forums/thread/124749
[forum-784248]: https://developer.apple.com/forums/thread/784248
[forums-64872]: https://forums.swift.org/t/replicating-tabview-view-hierarchy-behavior/64872
[swift-nsview-rep]: https://forums.swift.org/t/nsviewrepresentable-nsscrollview-and-missing-mouse-events/44157
[cocoa-event-arch]: https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/EventArchitecture/EventArchitecture.html
[cocoadev-scrollwheel]: https://cocoadev.github.io/ScrollWheelInNSView/
[docs-tabview]: https://developer.apple.com/documentation/SwiftUI/TabView
[docs-scrolldisabled]: https://developer.apple.com/documentation/swiftui/view/scrolldisabled(_:)
[docs-allowshittesting]: https://developer.apple.com/documentation/swiftui/view/allowshittesting(_:)
[docs-nsview-hidden]: https://developer.apple.com/documentation/appkit/nsview/1483369-ishidden
[docs-nsview-alpha]: https://developer.apple.com/documentation/appkit/nsview/1483560-alphavalue
[docs-nsview-hittest]: https://developer.apple.com/documentation/appkit/nsview/1483364-hittest
[docs-nsscrollview]: https://developer.apple.com/documentation/appkit/nsscrollview
[wwdc-2013-215]: https://asciiwwdc.com/2013/sessions/215
[kristaps-tabview]: https://kristaps.me/blog/swiftui-tabview/
[stateful-tabview]: https://swiftpackageindex.com/NicholasBellucci/StatefulTabView
[pd95-handlewindow]: https://github.com/pd95/SwiftUI-macos-HandleWindow
[shuffling-window]: https://github.com/shufflingB/swiftui-macos-windowManagment
[apple-multiwindow]: https://developer.apple.com/videos/play/wwdc2022/10061/
[hier-responder]: https://github.com/EmilioPelaez/HierarchyResponder
[swiftui-lab-combo]: https://swiftui-lab.com/a-powerful-combo/
