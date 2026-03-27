# Terminal Enhancements: Kitty Keyboard Protocol, OSC 777, OSC 9

## Problem

TBD's embedded terminal (SwiftTerm → tmux → shell) doesn't send distinct escape sequences for Shift+Enter, so Claude Code can't distinguish it from plain Enter. Users can't use Shift+Enter for multi-line input. Additionally, SwiftTerm already parses OSC 777 (notifications) and OSC 9 (progress) sequences but TBD doesn't handle them.

## Solution

Three changes, ordered by impact:

1. **Enable Kitty keyboard protocol in tmux** — fixes Shift+Enter and all modifier+key combos
2. **Wire up OSC 777 notifications** — route terminal notifications into TBD's existing notification system
3. **Wire up OSC 9 progress** — surface progress state in the worktree UI

## Architecture

### Data Flow

```
Claude Code (inner app)
    ↕ CSI u sequences, OSC 777, OSC 9
tmux (middleman, -L tbd-<hash>)
    ↕ passthrough
SwiftTerm (outer terminal emulator)
    ↕ delegate callbacks
TerminalPanelView.Coordinator
    ↕ callbacks / published state
TBD UI (worktree rows, notifications)
```

### 1. Kitty Keyboard Protocol via tmux

**What:** Add `set -g extended-keys-format kitty` to TBD's tmux server configuration.

**Where:** `TmuxManager.swift`, in `ensureServer()` (lines 92-97), alongside the existing `set -g status off` / `set -g mouse on` options.

**Why this works:**
- tmux 3.6a supports the Kitty keyboard protocol
- `extended-keys on` is already set (user's global tmux.conf)
- SwiftTerm has full Kitty keyboard protocol support (KittyKeyboardProtocol.swift, KittyKeyboardEncoder.swift)
- When Claude Code sends `CSI = 1 u` to request the protocol, tmux negotiates with the outer terminal (SwiftTerm), and key events flow back encoded as `CSI key;modifier u`

**Change:** One line added to `ensureServer()`:
```swift
try? await runTmux(["-L", server, "set", "-g", "extended-keys-format", "kitty"])
```

**No changes needed in:**
- SwiftTerm (already supports the protocol)
- TBDTerminalView (handleNaturalTextEditing only fires for Cmd/Opt combos, not Shift+Enter)
- TerminalPanelView (passthrough works automatically)

### 2. OSC 777 Notifications

**What:** Override SwiftTerm's default (no-op) handling of `notify(source:title:body:)` on the `TerminalDelegate` protocol, and route notifications into TBD's existing notification system.

**Important detail:** `notify` is on `TerminalDelegate` (the low-level Terminal protocol), **not** on `TerminalViewDelegate` (the view-level protocol the Coordinator conforms to). `MacTerminalView` does not handle or forward this — it falls through to a default empty implementation. We need to subclass or otherwise intercept this.

**Approach:** Override `notify` in `TBDTerminalView` (our existing `TerminalView` subclass). `TerminalView` conforms to `TerminalDelegate`, so we can override the method there and forward via a callback.

**Where:** `TBDTerminalView.swift` — add the override and a callback property.

**Interface:**
```swift
// On TBDTerminalView
var onNotification: ((String, String) -> Void)?  // (title, body)

// Override in TBDTerminalView (TerminalDelegate method)
// Note: need to verify this is overridable — check if it's open/public in MacTerminalView
```

**Filtering:** Only fire if the terminal window is not key (not focused). Check `window?.isKeyWindow != true`.

### 3. OSC 9 Progress Reporting

**What:** SwiftTerm's `MacTerminalView` **already handles OSC 9 internally** — it has a built-in `TerminalProgressBarView` that renders a progress bar directly in the terminal view, with a 15-second auto-hide timer.

**No code changes needed.** This works out of the box.

**Optional future enhancement:** If we want to also surface progress in the worktree sidebar row (outside the terminal view), we could override `progressReport` in `TBDTerminalView` (same approach as notify), call `super`, and forward the state via a callback. But this is unnecessary for now — the built-in progress bar is sufficient.

## What This Does NOT Change

- No changes to SwiftTerm library code
- No changes to the TBDTerminalView key handling (handleNaturalTextEditing is unaffected)
- No changes to the existing notification hook system (notify.sh continues to work)
- No new dependencies

## Testing

- **Shift+Enter:** Launch Claude Code in TBD, press Shift+Enter — should insert newline instead of submitting
- **OSC 777:** Run `printf '\033]777;notify;Test Title;Test Body\007'` in a TBD terminal — should create a TBD notification (verify via DB or notification UI)
- **OSC 9:** Run `printf '\033]9;4;1;50\007'` in a TBD terminal — SwiftTerm's built-in progress bar should appear at top of terminal view (already works, just verify)
