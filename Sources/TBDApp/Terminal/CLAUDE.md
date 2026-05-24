# Terminal

## Event routing isn't just SwiftUI

`TerminalPanelView` installs **app-wide `NSEvent.addLocalMonitorForEvents`** for `.scrollWheel` and `.leftMouseDown` (see [`TerminalPanelView.swift`](TerminalPanelView.swift) around the `scrollMonitor` / `clickMonitor` setup). The monitors fire *before* SwiftUI's responder chain, so any SwiftUI view rendered visually on top of a terminal — overlay, popover, modal, palette — does **not** receive scroll-wheel or left-click events the monitors claim. The bounds check inside each monitor (`tv.bounds.contains(point)`) is geometric; it doesn't know whether a sibling SwiftUI view is currently covering that area.

**When adding any view on top of a `TerminalPanelView`,** pass a `shouldSuppressEvents: @MainActor () -> Bool` into its init that returns `true` while your view is covering the terminal. Both monitors check it and short-circuit, leaving the event for SwiftUI. Skipping this ships an invisible-feeling bug: clicks "miss" the overlay and trackpad scrolling scrolls the terminal underneath.

Same root cause has surfaced twice — see [issue #129](https://github.com/cheapsteak/tbd/issues/129) (transcript overlay) and the `tv.window != nil` keep-alive filter already in `TerminalPanelView.swift` (background-worktree terminals).
