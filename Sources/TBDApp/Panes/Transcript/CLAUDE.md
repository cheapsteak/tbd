# Transcript cards

Transcript row cards must not have a direct `ScrollView` child.

SwiftUI measures a `ScrollView`'s ideal size as its full content size. When a row is also bounded by `.frame(maxHeight:)`, the modifier produces a `_FlexFrameLayout` (a range), so the layout engine must measure the child before clamping — triggering a full `ScrollViewLayoutComputer.Engine` pass on every layout invalidation. Inside a `LazyVStack` this compounds per-row: 71 items was enough to hang the main thread for 35+ seconds (issue [#129](https://github.com/cheapsteak/tbd/issues/129)).

The approved fix removes inline expand/collapse from all row cards entirely; long content moves to a click-triggered overlay rendered outside the `LazyVStack` where a real `ScrollView` is safe. See `docs/superpowers/specs/2026-05-23-transcript-card-rework-design.md`.

A custom SwiftLint rule (`no_scrollview_in_transcript_cards` in `.swiftlint.yml`) enforces this at `error` severity. Legitimate `ScrollView` usage in this directory (e.g. an overlay view that lives outside the `LazyVStack`) should add itself to the rule's `excluded:` list with a one-line comment explaining why it is safe.
