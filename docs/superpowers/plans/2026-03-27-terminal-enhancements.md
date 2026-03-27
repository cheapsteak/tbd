# Terminal Enhancements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable Kitty keyboard protocol (fixes Shift+Enter in Claude Code) and OSC 777 terminal notifications in TBD's embedded terminal.

**Architecture:** One tmux option added to server setup enables the Kitty keyboard protocol end-to-end. One `TerminalDelegate` method override in `TBDTerminalView` routes OSC 777 notifications into TBD's notification system via callback. OSC 9 progress already works via SwiftTerm's built-in progress bar — no changes needed.

**Tech Stack:** Swift, SwiftTerm, tmux, AppKit

---

### Task 1: Enable Kitty keyboard protocol in tmux server setup

**Files:**
- Modify: `Sources/TBDDaemon/Tmux/TmuxManager.swift:91-97`

- [ ] **Step 1: Add `extended-keys-format kitty` to `ensureServer()`**

In `TmuxManager.swift`, add two lines after line 95 (the `mouse on` setting) and before line 97 (the `SSH_AUTH_SOCK` line):

```swift
// Enable Kitty keyboard protocol so apps can distinguish Shift+Enter from Enter
try? await runTmux(["-L", server, "set", "-g", "extended-keys", "on"])
try? await runTmux(["-L", server, "set", "-g", "extended-keys-format", "kitty"])
```

We set both `extended-keys on` (in case the user's tmux.conf doesn't have it) and `extended-keys-format kitty` (to use CSI u encoding instead of the default xterm format).

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 3: Run tests**

Run: `swift test 2>&1 | tail -10`
Expected: All tests pass. The `ensureServer` test uses `dryRun: true` which skips `runTmux` calls, so our new lines are not exercised in tests (by design — they're runtime tmux commands).

- [ ] **Step 4: Commit**

```bash
git add Sources/TBDDaemon/Tmux/TmuxManager.swift
git commit -m "feat: enable Kitty keyboard protocol in tmux (fixes Shift+Enter)"
```

---

### Task 2: Wire up OSC 777 notifications in TBDTerminalView

**Files:**
- Modify: `Sources/TBDApp/Terminal/TBDTerminalView.swift`
- Modify: `Sources/TBDApp/Terminal/TerminalPanelView.swift`
- Modify: `Sources/TBDApp/Panes/PanePlaceholder.swift`

- [ ] **Step 1: Add notification callback and override to TBDTerminalView**

In `Sources/TBDApp/Terminal/TBDTerminalView.swift`, add a callback property and override the `notify` method from `TerminalDelegate`. Add these after the `worktreePath` property (line 10) and before the `extractFilePath` method (line 12):

```swift
var onNotification: ((String, String) -> Void)?
```

Then add this override after the `handleNaturalTextEditing` method (after line 124, before the closing brace of the class):

```swift
override func notify(source: Terminal, title: String, body: String) {
    DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        // Only notify when this terminal is not focused
        guard self.window?.isKeyWindow != true else { return }
        self.onNotification?(title, body)
    }
}
```

Note: `notify(source: Terminal, ...)` is a `TerminalDelegate` method with a default empty implementation. `TerminalView` (an `open class`) conforms to `TerminalDelegate`. Our subclass `TBDTerminalView` can override it. The `Terminal` type is from `import SwiftTerm`.

- [ ] **Step 2: Add notification callback to TerminalPanelView**

In `Sources/TBDApp/Terminal/TerminalPanelView.swift`, add a callback property after the `onFilePathClicked` property (line 29):

```swift
var onTerminalNotification: ((String, String) -> Void)?
```

Then in `makeNSView(context:)`, wire it up. Add after line 47 (`tv.onFilePathClicked = onFilePathClicked`):

```swift
tv.onNotification = onTerminalNotification
```

- [ ] **Step 3: Pass notification callback from PanePlaceholder**

In `Sources/TBDApp/Panes/PanePlaceholder.swift`, add the `onTerminalNotification` parameter where `TerminalPanelView` is constructed (after the `onFilePathClicked` closure, around line 146). The exact wiring depends on how the notification system is accessed from this view. For now, log the notification so the callback is exercised:

```swift
onTerminalNotification: { title, body in
    debugLog("OSC 777: \(title) — \(body)")
}
```

- [ ] **Step 4: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 5: Run tests**

Run: `swift test 2>&1 | tail -10`
Expected: All tests pass (no test changes — this is UI-layer code in `TBDApp` target which has no unit tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/TBDApp/Terminal/TBDTerminalView.swift Sources/TBDApp/Terminal/TerminalPanelView.swift Sources/TBDApp/Panes/PanePlaceholder.swift
git commit -m "feat: wire up OSC 777 terminal notifications"
```
