# Tmux Input Pass-Through for Agent Teams

## Problem

Claude Code's agent teams feature doesn't work properly inside TBD's terminal. When Claude Code spawns split-pane teammates, users can't switch between panes because:

1. **Mouse clicks** don't reach tmux — `allowMouseReporting = false` in SwiftTerm causes all clicks to be handled locally for text selection, so tmux never receives click events to switch pane focus.
2. **Shift+Arrow keys** are stripped — tmux isn't configured with `xterm-keys on`, so extended key sequences lose their shift modifier before reaching applications.

## Design

### Mouse Click Pass-Through

Override mouse event handling in `TBDTerminalView` to distinguish clicks from drags:

- **Click (no drag):** Forward to tmux as a mouse press+release event so tmux can handle pane switching.
- **Click-drag:** Let SwiftTerm handle it locally for text selection (existing behavior).

**Implementation:**

1. Override `mouseDown` — record the click position, call `super.mouseDown()`.
2. Override `mouseDragged` — set a `didDrag` flag when mouse moves beyond a ~3px threshold from the initial click position.
3. Override `mouseUp` — if `didDrag` is false and `terminal.mouseMode != .off`, compute the grid position and send press+release mouse events to tmux via `terminal.encodeButton()` + `terminal.sendEvent()`. Always call `super.mouseUp()`.

Grid position is computed the same way `extractFilePath` already does: `bounds.width / terminal.cols` for cell width, `bounds.height / terminal.rows` for cell height.

The key SwiftTerm APIs used are all public:
- `terminal.encodeButton(button:release:shift:meta:control:)` — encodes mouse button flags
- `terminal.sendEvent(buttonFlags:x:y:)` — sends the escape sequence to the PTY
- `terminal.mouseMode` — checks if tmux has mouse reporting enabled

### Shift+Arrow Key Pass-Through

Add `set -g xterm-keys on` to the tmux server configuration in `TmuxManager.ensureServer()`, alongside the existing global settings (`mouse on`, `status off`). This tells tmux to pass through extended xterm key sequences including Shift+Up/Down.

## Files Changed

1. **`Sources/TBDApp/Terminal/TBDTerminalView.swift`** — Add `mouseDown`, `mouseUp`, `mouseDragged` overrides.
2. **`Sources/TBDDaemon/Tmux/TmuxManager.swift`** — Add `set -g xterm-keys on` in `ensureServer()`.
