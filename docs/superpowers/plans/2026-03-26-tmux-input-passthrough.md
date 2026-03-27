# Tmux Input Pass-Through Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable Claude Code agent team pane switching inside TBD's terminal by forwarding mouse clicks and Shift+Arrow keys through to tmux.

**Architecture:** Two independent changes — (1) override mouse events in TBDTerminalView to forward single clicks to tmux while preserving drag-to-select, (2) add `xterm-keys on` to tmux server config for Shift+Arrow pass-through.

**Tech Stack:** Swift, SwiftTerm (TerminalView subclass), tmux CLI

---

### Task 1: Add xterm-keys to tmux server config

**Files:**
- Modify: `Sources/TBDDaemon/Tmux/TmuxManager.swift:95` (after `mouse on` line)

- [ ] **Step 1: Add xterm-keys setting**

In `TmuxManager.swift`, inside `ensureServer()`, add this line after the `mouse on` setting (line 95):

```swift
// Enable extended key sequences so Shift+Arrow etc. pass through to applications
try? await runTmux(["-L", server, "set", "-g", "xterm-keys", "on"])
```

The full block (lines 91-98) should read:

```swift
// Hide tmux chrome globally — TBD app provides its own UI
try? await runTmux(["-L", server, "set", "-g", "status", "off"])
try? await runTmux(["-L", server, "set", "-g", "pane-border-style", "fg=black"])
// Enable mouse so scroll wheel enters copy-mode and scrolls history
try? await runTmux(["-L", server, "set", "-g", "mouse", "on"])
// Enable extended key sequences so Shift+Arrow etc. pass through to applications
try? await runTmux(["-L", server, "set", "-g", "xterm-keys", "on"])
// Set SSH_AUTH_SOCK to stable symlink so shells get a resilient path
try? await runTmux(["-L", server, "setenv", "-g", "SSH_AUTH_SOCK", SSHAgentResolver.defaultSymlinkPath])
```

- [ ] **Step 2: Build to verify**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 3: Run tests**

Run: `swift test --filter TmuxManagerTests 2>&1 | tail -10`
Expected: All tests pass (dry-run tests don't execute tmux commands, so the new line has no effect on them).

- [ ] **Step 4: Commit**

```bash
git add Sources/TBDDaemon/Tmux/TmuxManager.swift
git commit -m "feat: enable xterm-keys in tmux for Shift+Arrow pass-through"
```

---

### Task 2: Add mouse click pass-through to TBDTerminalView

**Files:**
- Modify: `Sources/TBDApp/Terminal/TBDTerminalView.swift` (add mouse overrides after `performKeyEquivalent`)

- [ ] **Step 1: Add drag-tracking state properties**

Add these properties after the existing `worktreePath` property (line 10), before `extractFilePath`:

```swift
// MARK: - Mouse click pass-through
// Track mouseDown position to distinguish clicks from drags.
// Single clicks are forwarded to tmux for pane switching;
// click-drags are handled locally by SwiftTerm for text selection.
private var mouseDownLocation: CGPoint = .zero
private var didDrag: Bool = false
private static let dragThreshold: CGFloat = 3.0
```

- [ ] **Step 2: Add mouseDown override**

Add after the closing brace of `handleNaturalTextEditing` (after line 123), before the final class closing brace:

```swift
override func mouseDown(with event: NSEvent) {
    mouseDownLocation = convert(event.locationInWindow, from: nil)
    didDrag = false
    super.mouseDown(with: event)
}
```

- [ ] **Step 3: Add mouseDragged override**

Add immediately after `mouseDown`:

```swift
override func mouseDragged(with event: NSEvent) {
    let current = convert(event.locationInWindow, from: nil)
    let dx = current.x - mouseDownLocation.x
    let dy = current.y - mouseDownLocation.y
    if sqrt(dx * dx + dy * dy) > Self.dragThreshold {
        didDrag = true
    }
    super.mouseDragged(with: event)
}
```

- [ ] **Step 4: Add mouseUp override**

Add immediately after `mouseDragged`:

```swift
override func mouseUp(with event: NSEvent) {
    // If this was a click (not a drag) and tmux has mouse mode enabled,
    // forward the click to tmux so it can handle pane switching.
    if !didDrag && terminal.mouseMode != .off {
        let point = convert(event.locationInWindow, from: nil)
        let charWidth = bounds.width / CGFloat(terminal.cols)
        let lineHeight = bounds.height / CGFloat(terminal.rows)
        let col = Int(point.x / charWidth)
        let row = Int((bounds.height - point.y) / lineHeight)

        let pressFlags = terminal.encodeButton(
            button: 0, release: false,
            shift: false, meta: false, control: false
        )
        terminal.sendEvent(buttonFlags: pressFlags, x: col, y: row)

        let releaseFlags = terminal.encodeButton(
            button: 0, release: true,
            shift: false, meta: false, control: false
        )
        terminal.sendEvent(buttonFlags: releaseFlags, x: col, y: row)
    }
    super.mouseUp(with: event)
}
```

Key details:
- `button: 0` is left mouse button in SwiftTerm's encoding
- `release: false` for press, `release: true` for release
- Grid position uses the same math as `extractFilePath` — `bounds.width / terminal.cols` for cell width, flipped Y axis via `bounds.height - point.y`
- `terminal.mouseMode` is set by tmux when `mouse on` is configured (already done in TmuxManager)
- `super.mouseUp()` is always called so SwiftTerm still handles link detection etc.

- [ ] **Step 5: Build to verify**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 6: Commit**

```bash
git add Sources/TBDApp/Terminal/TBDTerminalView.swift
git commit -m "feat: forward single clicks to tmux for pane switching"
```
