# TBDApp

SwiftUI app target. See the repo-root `CLAUDE.md` and the `tbd-project` skill for architecture.

## macOS 26 (Tahoe) Liquid Glass toolbars — grouping rules

macOS 26 redesigned toolbars: items render on **Liquid Glass capsules**, and **adjacent toolbar items are automatically fused onto one shared capsule**. Getting items onto *separate* capsules is non-obvious and cost a long trial-and-error loop — here is what actually works (verified against WWDC25 session 323 "Build a SwiftUI app with the new design" and confirmed live in this app). The working example is the PR split button in `ContentView.swift`.

### What separates vs. fuses

- **`ToolbarItemGroup` FUSES its children by design** — it is a shared-background cluster, NOT a separator. Wrapping each segment in its own single-child `ToolbarItemGroup` does **not** put them on separate capsules.
- **`ControlGroup` is the reliable capsule BOUNDARY.** It lowers to an `NSToolbarItemGroup` (a first-class grouped item with a hard glass boundary), so its content never fuses with outside neighbors. **To isolate one control into its own capsule, make it the *sole child* of a `ControlGroup`** — single child means no internal gap. (A `ControlGroup` with *two* children separates correctly too, but its inter-member spacing is system-controlled with no public API, so it looks too gappy.)
- **`ToolbarSpacer` separates two items _only_ when it carries the same `placement` as them** and sits directly between them in source order. `ToolbarSpacer(.fixed, placement: .primaryAction)` between two `.primaryAction` items splits the capsule; a placement-less `ToolbarSpacer(.fixed)` lands in a different bucket and silently does nothing. `.fixed` = snug gap, `.flexible` = pushes items to opposite edges. `ToolbarSpacer` is **macOS 26.0+** — guard with `if #available(macOS 26.0, *)`.
- A bare `Menu` / `Menu(primaryAction:)` toolbar item (an `NSMenuToolbarItem`) is greedy: it tends to fuse with an adjacent bordered item even with a spacer. Putting it inside a `ControlGroup` (boundary) is what reliably isolates it.
- Last-resort escape hatches if SwiftUI keeps fusing: `.sharedBackgroundVisibility(.hidden)` (removes an item's glass entirely — separate grouping but no background), or drop to a custom `NSToolbar` + `NSToolbarDelegate` with `NSMenuToolbarItem` and explicit space items.

### Split button (primary action + dropdown)

`Menu(content:label:primaryAction:)` is the toolbar **split button**: the label is the primary click; an attached **chevron** opens the menu. Per Apple's HIG this chevron is the correct affordance for a labeled action with options (an ellipsis "More" is discouraged for discoverability, and there is no native vertical-ellipsis SF Symbol).

### Colored icon inside a toolbar Menu / split-button label

A toolbar `Menu` label renders **template** images monochrome (AppKit tints them with the control color and ignores SwiftUI `.foregroundStyle`). To show a status-colored icon (see `PRButtonLabel` + `PRStatusPresentation.nsColor`):

1. Bake the color into a **non-template** `NSImage` (draw the template, then `NSColor.set()` + `rect.fill(using: .sourceAtop)`; set `isTemplate = false`).
2. Render it with `Image(nsImage:).renderingMode(.original)`.
3. Re-bake on light/dark changes by reading `@Environment(\.colorScheme)` in the view body.
4. Use `.tint(.primary)` on the `Menu` to keep adjacent label text neutral (the split button otherwise accent-tints it); `.renderingMode(.original)` images ignore the tint, so the baked color survives.
