# TBDApp

SwiftUI app target. See the repo-root `CLAUDE.md` and the `tbd-project` skill for architecture.

## Tuning a visual constant

While a purely visual value — a gap, inset, opacity, duration — is being eyeballed, iterate with `scripts/swift-safe build`, the one filtered suite that pins it, and `scripts/restart.sh`; the full `scripts/test.sh` costs ~110s, cannot tell you whether the number looks right, and belongs once on the final tree before pushing.

## AppKit traps

Each of these looks right in review and fails only when it runs or builds.

- **SwiftUI's `dismiss` does nothing in an `NSHostingController` presented with `presentAsSheet`.** The sheet's Cancel, Done and Escape silently stop working. Present SwiftUI sheet content with `.sheet(item:)` from a SwiftUI view, as `NativeSidebarSheetPresenter` does.
- **An `NSBox` separator made at `.zero` is vertical.** A separator takes its orientation from its frame, and the vertical one's intrinsic width of 1 pt, hugged above the window's size priority, shrank a whole window to 1 pt wide. Make it wider than tall, as `SidebarContainerController` does.
- **Between `beginUpdates` and `endUpdates`, `NSOutlineView.child(_:ofItem:)` asks the data source**, which already serves the new tree. Never infer the old tree from outline lookups during an update; keep your own copy of it.
- **Don't capture a `Notification` or `NSEvent` into `MainActor.assumeIsolated` from a `nonisolated` delegate method.** Neither is `Sendable`, so Swift 6 rejects the capture as a data race. Extract what you need first, such as the sender's `ObjectIdentifier`.

## macOS 26 (Tahoe) Liquid Glass toolbars — grouping rules

macOS 26 redesigned toolbars: items render on **Liquid Glass capsules**, and **adjacent toolbar items are automatically fused onto one shared capsule**. Getting items onto *separate* capsules is non-obvious and cost a long trial-and-error loop — here is what actually works (verified against WWDC25 session 323 "Build a SwiftUI app with the new design" and confirmed live in this app). The working example is the PR split button in `ContentView.swift`.

### What separates vs. fuses

- **`ToolbarItemGroup` FUSES its children by design** — it is a shared-background cluster, NOT a separator. Wrapping each segment in its own single-child `ToolbarItemGroup` does **not** put them on separate capsules.
- **`ControlGroup` is the reliable capsule BOUNDARY.** It lowers to an `NSToolbarItemGroup` (a first-class grouped item with a hard glass boundary), so its content never fuses with outside neighbors. **To isolate one control into its own capsule, make it the *sole child* of a `ControlGroup`** — single child means no internal gap. (A `ControlGroup` with *two* children separates correctly too, but its inter-member spacing is system-controlled with no public API, so it looks too gappy.)
- **`ToolbarSpacer` separates two items _only_ when it carries the same `placement` as them** and sits directly between them in source order. `ToolbarSpacer(.fixed, placement: .primaryAction)` between two `.primaryAction` items splits the capsule; a placement-less `ToolbarSpacer(.fixed)` lands in a different bucket and silently does nothing. `.fixed` = snug gap, `.flexible` = pushes items to opposite edges. `ToolbarSpacer` is **macOS 26.0+** — guard with `if #available(macOS 26.0, *)`.
- A bare `Menu` / `Menu(primaryAction:)` toolbar item (an `NSMenuToolbarItem`) is greedy: it tends to fuse with an adjacent bordered item even with a spacer. Putting it inside a `ControlGroup` (boundary) is what reliably isolates it.
- Last-resort escape hatches if SwiftUI keeps fusing: `.sharedBackgroundVisibility(.hidden)` (removes an item's glass entirely — separate grouping but no background), or drop to a custom `NSToolbar` + `NSToolbarDelegate` with `NSMenuToolbarItem` and explicit space items.

### AppKit `NSToolbarItem`: which items get glass

`NSToolbarItem` forwards most getters and setters, `isBordered` among them, to its view when the view answers them, so whether an item gets glass depends on its view:

- **An image item with `isBordered = false`:** no glass.
- **A view item whose view has its own `isBordered`** (an `NSButton`, an `NSPopUpButton`): the item reports the view's value, so a bordered button gets glass, and adjacent glass items fuse onto one capsule. Measured in this app: three adjacent view items whose views were bordered accessory-bar buttons sat on one shared capsule.
- **A view item whose view has no `isBordered`** (a plain `NSView`, an `NSHostingView`) **and `item.isBordered = false`:** no glass. The leading buttons (`ToolbarIconButtonHost` in `MainToolbarController+Items.swift`) and the title stay off glass this way; the leading buttons' bordered button sits one level down and keeps its own hover highlight.
- So to keep a button off glass, never make a bordered control the item's view directly. Wrap it in a plain view and set the target and action on the button itself, since the wrapper forwards none of them. The wrapper's item is a `ToolbarIconButtonItem`, whose `isEnabled` reads its button and, when set, brings the overflow row along, so set the item's `isEnabled`, never the button's.

### Split button (primary action + dropdown)

`Menu(content:label:primaryAction:)` is the toolbar **split button**: the label is the primary click; an attached **chevron** opens the menu. Per Apple's HIG this chevron is the correct affordance for a labeled action with options (an ellipsis "More" is discouraged for discoverability, and there is no native vertical-ellipsis SF Symbol).

### Colored icon inside a toolbar Menu / split-button label

A toolbar `Menu` label renders **template** images monochrome (AppKit tints them with the control color and ignores SwiftUI `.foregroundStyle`). To show a status-colored icon (see `PRButtonLabel` + `PRStatusPresentation.nsColor`):

1. Bake the color into a **non-template** `NSImage` (draw the template, then `NSColor.set()` + `rect.fill(using: .sourceAtop)`; set `isTemplate = false`).
2. Render it with `Image(nsImage:).renderingMode(.original)`.
3. Re-bake on light/dark changes by reading `@Environment(\.colorScheme)` in the view body. **Re-baking alone is not enough**: AppKit materializes the toolbar item's label ONCE (see "Split-button label flattening & stale menu state" below), so the fresh image only reaches AppKit when the toolbar item is recreated — appearance must also be part of the item's `.id(...)` key (as the PR split button's `PRButtonLabel.prSplitButtonID` does).
4. Use `.tint(.primary)` on the `Menu` to keep adjacent label text neutral (the split button otherwise accent-tints it); `.renderingMode(.original)` images ignore the tint, so the baked color survives.

### macOS 27: toolbar menus default to icon-only

Verified on macOS 27.0.1 with a standalone toolbar harness: a toolbar `Menu` **without** `primaryAction:` (and a `.menu`-style `Picker`) draws only its label's image — the title is dropped, and a text-only label becomes an empty capsule. Split buttons (`Menu` with `primaryAction:`) still draw both. Two rules follow:

- **Apply `.labelStyle(.titleAndIcon)` to the `Menu` / `Picker` itself** — on the label view inside the closure it has no effect — and build the label as a `Label { Text } icon: { Image }`, not an `HStack`.
- **Never make a baked label image `.resizable()`.** AppKit flattens the label to the `NSImage` and ignores the SwiftUI `.frame`, so a resizable image is stretched to fill the toolbar's icon slot. Give the `NSImage` its exact point size when baking and render it unmodified.

### Split-button label flattening & stale menu state

Two more empirically verified constraints (verified live in this app, July 2026, macOS 26):

- **AppKit flattens the split-button label to exactly ONE image + ONE plain text string.** A second/conditional `Image` in the label `HStack` is silently dropped (its only visible effect is width truncation of the text), and inline `Text(Image(...))` attachments are stripped entirely. Any badge or indicator must be **composited into the single baked `NSImage`** — see `PRButtonLabel.coloredIcon` in `ContentView.swift`, which draws the `archivebox` badge into the same bitmap as the status icon.
- **AppKit materializes the split button's NSMenu and label ONCE.** Later SwiftUI state changes — a `Toggle` checkmark inside the menu, or structural changes to the label — do NOT propagate to the already-materialized item, even though SwiftUI re-evaluates the `content`/`label` closures with the correct values. The fix is to force recreation with `.id(...)` keyed on that state — and the key must include EVERYTHING the label/menu render (worktree + whether its row has loaded, menu toggle state, the full `PRStatus`, colorScheme) — see `PRButtonLabel.prSplitButtonID`.
