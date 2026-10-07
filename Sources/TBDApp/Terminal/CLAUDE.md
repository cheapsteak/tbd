# Terminal

## Event routing isn't just SwiftUI

`TerminalPanelView` installs an **app-wide `NSEvent.addLocalMonitorForEvents`** for `.scrollWheel` (see [`TerminalPanelView.swift`](TerminalPanelView.swift) around the `scrollMonitor` setup), because SwiftTerm's `scrollWheel` is not `open`. The monitor fires *before* SwiftUI's responder chain, so any SwiftUI view rendered visually on top of a terminal — overlay, popover, modal, palette — does **not** receive scroll-wheel events the monitor claims. The bounds check inside it (`tv.bounds.contains(point)`) is geometric; it doesn't know whether a sibling SwiftUI view is currently covering that area.

**When adding any view on top of a `TerminalPanelView`,** pass a `shouldSuppressEvents: @MainActor () -> Bool` into its init that returns `true` while your view is covering the terminal. The scroll monitor checks it and short-circuits, leaving the event for SwiftUI, and the terminal's click routing checks it too, so a click on terminal area the overlay leaves uncovered does not pull focus away from it. Skipping this ships an invisible-feeling bug: trackpad scrolling scrolls the terminal underneath the overlay.

Clicks that land *on* your view need nothing more. They reach the terminal through `TBDTerminalView`'s own `mouseDown` / `mouseDragged` / `mouseUp` overrides (SwiftTerm declares those `open`), and AppKit delivers a click only to the hit-tested top view — so a view drawn over the terminal, such as a split divider's grab strip or an overlay, takes its own clicks. Focus claiming, Cmd+click on paths and links, and click passthrough to a mouse-mode app all live in those overrides; the panel supplies the focus half through `onMouseDownClaimFocus` / `onResignFocus`. Don't reintroduce a click monitor: it cannot see what is on top.

Same root cause has surfaced twice — see [issue #129](https://github.com/cheapsteak/tbd/issues/129) (transcript overlay) and the `tv.window != nil` keep-alive filter already in `TerminalPanelView.swift` (background-worktree terminals).
