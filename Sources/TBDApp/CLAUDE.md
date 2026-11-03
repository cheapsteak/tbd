# TBDApp

SwiftUI app target. See the repo-root `CLAUDE.md` and the `tbd-project` skill for architecture.

## Tuning a visual constant

While a purely visual value — a gap, inset, opacity, duration — is being eyeballed, iterate with `scripts/swift-safe build`, the one filtered suite that pins it, and `scripts/restart.sh`; the full `scripts/test.sh` costs ~110s, cannot tell you whether the number looks right, and belongs once on the final tree before pushing.

When the choice is between several looks rather than one number — a colour, an alpha, the shape of a line — a browser mock is faster than a rebuild per try. Draw the few rows in HTML with sliders and the options side by side, reproduce the app's compositing (each alpha over the same background the app draws on), and copy the chosen values back into the constants. Calibrate the mock from a screenshot, and read the screenshot's pixels as Display P3, not sRGB: a screenshot of a wide-gamut display (a MacBook's built-in one is tagged "Color LCD") holds wide-gamut values, and the same numbers read as sRGB look duller. Write them as `color(display-p3 …)` in CSS and `NSColor(displayP3Red:green:blue:alpha:)` in Swift.

## AppKit traps

Each of these looks right in review and fails only when it runs or builds.

- **SwiftUI's `dismiss` does nothing in an `NSHostingController` presented with `presentAsSheet`.** The sheet's Cancel, Done and Escape silently stop working. Present SwiftUI sheet content with `.sheet(item:)` from a SwiftUI view, as `NativeSidebarSheetPresenter` does.
- **An `NSBox` separator made at `.zero` is vertical.** A separator takes its orientation from its frame, and the vertical one's intrinsic width of 1 pt, hugged above the window's size priority, shrank a whole window to 1 pt wide. Make it wider than tall, and leave its width to the layout with low hugging and compression-resistance priorities.
- **Between `beginUpdates` and `endUpdates`, `NSOutlineView.child(_:ofItem:)` asks the data source**, which already serves the new tree. Never infer the old tree from outline lookups during an update; keep your own copy of it.
- **Don't capture a `Notification` or `NSEvent` into `MainActor.assumeIsolated` from a `nonisolated` delegate method.** Neither is `Sendable`, so Swift 6 rejects the capture as a data race. Extract what you need first, such as the sender's `ObjectIdentifier`.
- **An `NSTextField` label framed at its `intrinsicContentSize` truncates text that fits.** The intrinsic size is the alignment rect, which leaves out the 2 pt the cell keeps clear on each side, so the frame is about 4 pt short and the tail ellipsis eats the last two or three letters (measured: "main" in 13 pt regular is 29 pt intrinsic, but the cell needs 32.98 pt). Size a label by its cell's `cellSize`, as `SidebarCellKit.size(of:)` does, and test whether it is cut with the cell's `expansionFrame(withFrame:in:)`, AppKit's own truncation check.
- **A SwiftUI `Menu` with `.menuStyle(.borderlessButton)` is laid out by AppKit, which ignores the label's modifiers.**
  - A `.font` on the label has no effect: the text draws at the 13 pt control font.
  - A symbol named in the label is sized to that font. A `+` came out 10.5 pt across, as tall as the capitals.
  - A pre-sized `Image(nsImage:)` keeps its size, but AppKit still sets its gap and baseline (measured: a 10 pt plus sat 9 pt from the text and 1.5 pt below the middle of the capitals).

  To size or place an icon exactly, put it outside the menu, as its own view beside the menu's button. Measure the result on a window capture, because the code does not show where AppKit put it.

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
