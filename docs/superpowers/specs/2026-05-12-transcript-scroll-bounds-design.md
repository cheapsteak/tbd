# Transcript pane: drop declarative scroll-bounds + animation-wrapping

**Date:** 2026-05-12
**Status:** Approved for implementation.
**Goal:** Eliminate the second `StackLayout ↔ _FlexFrameLayout ↔ _PaddingLayout` recursion signature characterized in the 2026-05-11 16:37 freeze, by removing the declarative scroll-bounds maintenance machinery (`.scrollPosition(id:)` + non-role-scoped `.defaultScrollAnchor(.bottom)`) and the ScrollView-wide `.animation(..., value: atBottom)` that wraps layout passes in animated transactions.

## Why

PR #134 successfully eliminated the `_ViewList_Group.estimatedCount` recursion (the prior dominant signature). A different signature now dominates the 16:37 hang: `LazyHVStack.lengthAndSpacing → StackLayout.placeChildren1 ↔ _FlexFrameLayout.sizeThatFits ↔ _PaddingLayout.sizeThatFits` ~4 deep × 12/12 samples. Reviewer convergence (Codex + Gemini, see [`2026-05-11-transcript-flex-frame-research-discussion.md`](2026-05-11-transcript-flex-frame-research-discussion.md)) points at three contributors in the same theme — **declarative scroll-bounds machinery + animated transactions wrapping the layout pass** — that we should address as one batch since the bug is not reliably reproducible locally and longitudinal observation is the validator.

Specific contributors this spec targets:

1. **`.animation(.easeInOut(duration: 0.2), value: atBottom)`** at `LiveTranscriptPaneView.swift:137` wraps the entire `ScrollView`. The 1pt sentinel added in PR #134 toggles `atBottom` *during lazy realization*, so `atBottom` mutations land inside the layout pass that's actively running. The `.animation` modifier wraps that mutation in a `withAnimation` transaction on the container being sized. Flagged by both Codex and Gemini.

2. **`.scrollPosition(id: $visibleID, anchor: .bottom)`** at `LiveTranscriptPaneView.swift:133` requires SwiftUI to maintain the identified row's visible position across reorder / size-change / initial-layout mismatches. Apple documents `.scrollPosition(id:)` as designed to be used alongside `.scrollTargetLayout()` — which we removed long ago — so we're already in a documented-degraded configuration.

3. **Non-role-scoped `.defaultScrollAnchor(.bottom)`** at `LiveTranscriptPaneView.swift:132` handles both initial position *and* content-size-change maintenance. Role-scoping to `.initialOffset` (macOS 15+ API) keeps the no-flash first paint while opting out of ongoing size-change accounting.

## Out of scope (deliberately deferred)

- **Drop the `TranscriptRow` outer `VStack` wrapper** (replace with `.overlay(alignment: .bottomLeading)` for the badge). Different theme; visual-regression risk on badge layering. Next batch if this one doesn't move the needle.
- **Remove `.frame(maxWidth: .infinity)` from `ActivityRowChrome:60` and `ChatBubbleView:35`** (shared wrappers only, per Codex). Different theme; visual-regression risk on right-aligned user bubbles. Next batch.
- **Remove all 21 `.frame(maxWidth: .infinity)` callsites.** Too risky without measurement.
- **`List` migration** — structural fallback, deserves its own PR per [`2026-05-06-transcript-list-migration-design.md`](2026-05-06-transcript-list-migration-design.md).
- **`@Observable` migration of `AppState`** — separate concern.
- **`.equatable()` on `TranscriptRow`** — Codex notes this skips `body` re-eval but not `sizeThatFits`; doesn't address the cycle.

## Scope

Four coordinated changes, **landed as one commit**. All target the same mechanism (declarative scroll-bounds + animated-transaction wrapping) and share the same UX trade-off; bundling them keeps the PR thematically tight and avoids attribution ambiguity if a longitudinal observation comes back positive.

### Change A — scope `.animation(..., value: atBottom)` to just the jump-button overlay

**Files:** `Sources/TBDApp/Panes/LiveTranscriptPaneView.swift` (line ~137), `Sources/TBDApp/Panes/HistoryPaneView.swift` (parallel location).

Current shape:

```swift
ScrollView { ... }
    .defaultScrollAnchor(.bottom)
    .scrollPosition(id: $visibleID, anchor: .bottom)
    .overlay(alignment: .bottomTrailing) {
        jumpToBottomButton(proxy: proxy)
    }
    .animation(.easeInOut(duration: 0.2), value: atBottom)   // ← wraps everything
```

Target shape:

```swift
ScrollView { ... }
    // .defaultScrollAnchor(.bottom, for: .initialOffset)  — change C
    // scrollPosition removed                              — change B
    .overlay(alignment: .bottomTrailing) {
        jumpToBottomButton(proxy: proxy)
            .animation(.easeInOut(duration: 0.2), value: atBottom)  // ← scoped to overlay only
    }
```

Rationale: the animation should affect *only* the jump-button's appear/disappear transition. Wrapping the entire ScrollView in a `value: atBottom`-keyed animation means every `atBottom` toggle (which fires from the lazy sentinel mid-realization) wraps the layout pass in a `withAnimation` transaction. Bad pattern. Scoping to the button preserves the visual intent.

### Change B — drop `.scrollPosition(id: $visibleID, anchor: .bottom)`

**Files:** same as A.

Delete:
- The `.scrollPosition(id: $visibleID, anchor: .bottom)` modifier line.
- `@State private var visibleID: String? = nil` declaration.
- The `.onAppear { if let id = visibleID { proxy.scrollTo(id, anchor: .bottom) } }` restore block — `visibleID` is now nil, this is a no-op anyway, and `defaultScrollAnchor(.bottom, for: .initialOffset)` handles initial position.
- The `.onChange(of: messages.last?.id)` writer that assigns `visibleID = targetID` — replaced by direct `proxy.scrollTo` (change D).

Keep:
- The `transcript.scrollTo` signposter regions; they wrap the new `proxy.scrollTo` calls instead.

### Change C — role-scope `.defaultScrollAnchor`

**Files:** same.

```swift
// Before:
.defaultScrollAnchor(.bottom)

// After:
.defaultScrollAnchor(.bottom, for: .initialOffset)
```

Available on macOS 15+ (we target macOS 14+; this is fine for actively-running macOS 15 sessions). Role-scoping to `.initialOffset` says "use this as the initial scroll position only; don't continuously maintain it against content-size changes." Preserves the flash-free first paint that Phase-1 of the List migration would have lost.

### Change D — rewire autoscroll-on-new-message to use `proxy.scrollTo`

**Files:** same.

Current `.onChange` block (after PR #134 fixup `558a8d8`):

```swift
.onChange(of: messages.last?.id) { oldID, newID in
    guard let _ = oldID, let _ = newID, atBottom else { return }
    guard let targetID = lastRenderedNodeID(for: messages) else { return }
    withAnimation(.easeOut(duration: 0.15)) {
        visibleID = targetID
    }
}
```

New shape:

```swift
.onChange(of: messages.last?.id) { oldID, newID in
    guard let _ = oldID, let _ = newID, atBottom else { return }
    guard let targetID = lastRenderedNodeID(for: messages) else { return }
    let scrollInterval = TranscriptSignposts.signposter.beginInterval("transcript.scrollTo")
    withAnimation(.easeOut(duration: 0.15)) {
        proxy.scrollTo(targetID, anchor: .bottom)
    }
    TranscriptSignposts.signposter.endInterval("transcript.scrollTo", scrollInterval)
}
```

`ScrollViewProxy.scrollTo(_:anchor:)` is the IceCubes pattern (research doc has citations). `withAnimation` is what gives it the easing — `proxy.scrollTo` doesn't natively animate.

## Files touched

| File | Change |
|---|---|
| `Sources/TBDApp/Panes/LiveTranscriptPaneView.swift` | A + B + C + D. Drop `visibleID` state, `.scrollPosition`, ScrollView-wide `.animation`, restore-on-appear; rewire `.onChange`. |
| `Sources/TBDApp/Panes/HistoryPaneView.swift` | Same changes applied in parallel. HistoryPaneView is read-only so no `.onChange` rewire needed (no streaming) — just the modifier set + jump button. Verify the equivalent structure exists and apply. |
| `Sources/TBDShared/...` | None. |
| `Sources/TBDApp/Panes/Transcript/...` | None. The flex-frame mechanism survives; this PR doesn't touch row chrome. |

## UX trade-off (explicit; accepted)

- **Lose scroll-position-preservation across pane close/reopen.** Every re-entry to the live or history transcript pane will land at the bottom regardless of where the user was scrolled when they left. The `.scrollPosition(id:)` binding was the only mechanism preserving this; without it, `defaultScrollAnchor(.bottom, for: .initialOffset)` always wins on entry.
- **Jump-to-bottom button appearance/disappearance only animates on transition** — same as today, just scoped to the overlay subtree instead of riding on the ScrollView's keyed animation. No visible difference.
- **Autoscroll on new-message arrival** continues to animate smoothly via `withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(...) }`.

This trade-off was already on the Phase-2 deferral list of the List migration design and is acceptable as a foundation here too.

## Success criteria

The bug is not reliably reproducible locally; longitudinal observation is the validator.

**Required:**
- `swift build` clean.
- `swift test` clean (no UI tests cover this, but ensure nothing else regresses).
- Manual sanity in a fresh restart:
  - Live transcript pane lands at the bottom on first paint (no flash, no top-of-list briefly visible).
  - Sending a new message smoothly autoscrolls to the new content.
  - Scrolling up: jump-to-bottom button appears (with easing). Tapping it scrolls smoothly to the bottom.
  - Closing and reopening the pane: lands at bottom (intended trade-off; no preservation).
  - History pane: equivalent behavior.

**Longitudinal (over the next ~24 hours of normal use):**
- `log show --last 24h --predicate 'subsystem == "com.tbd.app" AND category == "hang-watchdog"' --info --style compact` — should show zero `hang detected stallMs=>1000` lines.
- If a freeze does occur, the stack signature should no longer match the `StackLayout.placeChildren1 ↔ _FlexFrameLayout.sizeThatFits` 12/12 dominance characterized in the 16:37 freeze. (Different signature still alive → next batch tackles row chrome.)

## Implementation phasing

**One commit.** The four changes share code paths and a single UX trade-off; splitting them up makes review harder without enabling per-step measurement (which we can't do anyway due to the no-repro constraint).

Conventional commit message:

```
perf(transcript): drop declarative scroll-bounds + animation wrapping (#129)

Removes three contributors to the StackLayout ↔ _FlexFrameLayout
recursion characterized in the 2026-05-11 16:37 freeze, all in the
same theme of "declarative scroll-bounds maintenance + animated
transactions wrapping the layout pass":

1. Scope the .animation(.easeInOut, value: atBottom) modifier to the
   jump-button overlay only. Was wrapping the entire ScrollView, so
   every atBottom toggle (fired by the lazy sentinel mid-realization)
   wrapped the layout pass in a withAnimation transaction.
2. Drop .scrollPosition(id: $visibleID, anchor: .bottom). Apple docs
   require pairing with .scrollTargetLayout() (which we don't use),
   and .scrollPosition is documented to maintain visible identity
   across content-size changes — forcing continuous bottom-anchor
   accounting on the LazyVStack. Drop the corresponding visibleID
   state and onAppear restore.
3. Role-scope .defaultScrollAnchor(.bottom) to .defaultScrollAnchor(
   .bottom, for: .initialOffset). The unrole-scoped form continues to
   maintain bottom alignment against content-size changes; the
   .initialOffset role makes it a one-shot initial-position hint.
4. Rewire .onChange autoscroll on new messages to use
   proxy.scrollTo(lastRenderedNodeID, anchor: .bottom) instead of
   writing visibleID (which is now removed).

Trade-off: scroll-position-preservation across pane close/reopen is
lost. Re-entry always lands at bottom. This was already on the
List-migration Phase-2 deferral list; acceptable here too.

Reviewer convergence (Codex + Gemini) recorded in
docs/superpowers/specs/2026-05-11-transcript-flex-frame-research-discussion.md.
Bug is not reliably reproducible locally; validation is longitudinal
HangWatchdog observation.
```

## Verification plan

1. `swift build` from worktree cwd — must succeed cleanly. No new warnings.
2. `swift test` — must remain at 681 passing.
3. **Do not run `scripts/restart.sh` in the subagent** — that's the user's verification step. Subagent reports back without restarting.
4. After user's restart + manual sanity check, push branch and open PR (or merge directly if user prefers, given no reliable repro and the PR-#134 pattern).
5. Watch HangWatchdog telemetry over the next ~24h.

## Risks

- **macOS 15.x version skew on `.defaultScrollAnchor(_:for:)`.** Verify availability annotation. If we target macOS 14+, this needs an `if #available(macOS 15.0, *)` guard. (Project actually runs on macOS 15+ in practice; CLAUDE.md mentions Sequoia. But check `Package.swift` `.platforms` declaration.)
- **First-paint position behavior change.** `.defaultScrollAnchor(.bottom, for: .initialOffset)` *should* preserve the flash-free first paint, but if SwiftUI's role-scoped variant behaves differently than the unrole-scoped form here, we may see a brief top-of-list flash on first appear. Worth a manual sanity check.
- **`proxy.scrollTo` race with `withAnimation` on macOS 15.** Documented pattern, but verify the autoscroll feels right; if not, drop the `withAnimation` wrapper (loses easing, instant snap — minor degradation).
- **HistoryPaneView parity.** The history pane has a different structure (no streaming, no `.onChange(of: messages.last?.id)`). Just remove the modifiers + state; don't add rewires that don't apply.

## References

- Discussion: [`2026-05-11-transcript-flex-frame-research-discussion.md`](2026-05-11-transcript-flex-frame-research-discussion.md) — Codex + Gemini findings.
- Research brief: [`2026-05-11-transcript-flex-frame-research-brief.md`](2026-05-11-transcript-flex-frame-research-brief.md).
- Issue: [#129](https://github.com/cheapsteak/tbd/issues/129).
- Prior PR (still on main): [#134](https://github.com/cheapsteak/tbd/pull/134) — eliminated the `_ViewList_Group.estimatedCount` signature.
- Apple docs cited:
  - [`scrollPosition(id:anchor:)`](https://developer.apple.com/documentation/swiftui/view/scrollposition%28id%3Aanchor%3A%29)
  - [`defaultScrollAnchor(_:for:)`](https://developer.apple.com/documentation/swiftui/view/defaultscrollanchor%28_%3Afor%3A%29) + [`ScrollAnchorRole`](https://developer.apple.com/documentation/swiftui/scrollanchorrole)
  - [Apple Forums #770682](https://developer.apple.com/forums/thread/770682) — Apple DTS reply on `.scrollPosition` not working on `List`.
- Reference implementation: [IceCubesApp `TimelineListView.swift`](https://github.com/Dimillian/IceCubesApp/blob/main/Packages/Timeline/Sources/Timeline/View/TimelineListView.swift) — `ScrollViewReader.proxy.scrollTo` pattern, no `.scrollPosition`, no `.defaultScrollAnchor`.
