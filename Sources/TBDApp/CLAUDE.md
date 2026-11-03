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

## Toolbars

The main window's toolbar is an AppKit `NSToolbar` that `MainToolbarController` owns (`WindowChrome/`); the app declares no SwiftUI `.toolbar`. On macOS 26 and later, toolbar items render on **Liquid Glass capsules**, and **adjacent glass items fuse onto one shared capsule**. Why the window is AppKit rather than a SwiftUI `NavigationSplitView` with `.toolbar` items is in `docs/specs/2026-11-01-appkit-window-chrome-design.md`.

### `NSToolbarItem`: which items get glass

`NSToolbarItem` forwards most getters and setters, `isBordered` among them, to its view when the view answers them, so whether an item gets glass depends on its view:

- **An image item with `isBordered = false`:** no glass.
- **A view item whose view has its own `isBordered`** (an `NSButton`, an `NSPopUpButton`): the item reports the view's value, so a bordered button gets glass, and adjacent glass items fuse onto one capsule. Measured in this app: three adjacent view items whose views were bordered accessory-bar buttons sat on one shared capsule.
- **A view item whose view has no `isBordered`** (a plain `NSView`, an `NSHostingView`) **and `item.isBordered = false`:** no glass. The leading buttons (`LeadingToolbarButtonsHost` in `MainToolbarController+Items.swift`), the repo filter (`FilterToolbarButtonHost`) and the title stay off glass this way; their buttons sit one level down and draw their own hover square.
- So to keep a button off glass, never make a bordered control the item's view directly. Wrap it in a plain view and set the target and action on the button and the overflow row; an item with a custom view keeps no target or action its view does not answer, so the item reads nil (measured on CI). The wrapper forwards nothing, so the item's `isEnabled` never reaches its buttons either: enable each button and its overflow row directly.
- **AppKit gives each separate unbordered view item a fixed 44 pt slot**, centred on its view, whatever the view's width (measured on macOS 27: views 8, 20 and 32 pt wide all sat 44 pt apart). Buttons that must sit closer share one item whose view lays them out, as `LeadingToolbarButtonsHost` puts the toggle, back and forward 28 pt apart.
- **An accessory-bar button's hover highlight is smaller than its frame**: the bezel `showsBorderOnlyWhileMouseInside` reveals does not fill the button. For a hover square that fills the button and a hit area that matches it, as a macOS 27 toolbar's icon buttons show, draw the square in a borderless button: `ToolbarIconButton` in `WindowChrome/` does.
- **A toolbar draws its buttons at large control size, which scales up a symbol whose configuration names no scale** (measured: about 1.25 times). Name it: `NSImage.SymbolConfiguration(pointSize:weight:scale: .medium)`, as `iconGlyph` in `MainToolbarController+Items.swift` does.
- **A toolbar draws a template image monochrome, in the control colour**, so a status-coloured icon is baked into a non-template `NSImage`: draw the template, `NSColor.set()`, fill with `.sourceAtop`, set `isTemplate = false`. Resolve the colour inside the image's draw handler, so a dynamic colour follows the appearance, and key any cache of baked images on the appearance too. `ServersButtonLabel.bakedIcon` bakes the Servers item's icon this way.
