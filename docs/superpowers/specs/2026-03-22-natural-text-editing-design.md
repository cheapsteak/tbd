# Natural Text Editing

## Problem

Standard macOS text editing shortcuts (Cmd+Arrow for line navigation, Opt+Delete for word deletion) don't work in the terminal because these key combinations aren't translated to the escape sequences that shells expect. iTerm2 solves this with a "Natural Text Editing" preset that maps these shortcuts to the correct terminal sequences.

## Design

### TBDTerminalView subclass

A new `TBDTerminalView` subclass of SwiftTerm's `TerminalView` that overrides `keyDown(with:)` to intercept macOS-native key combinations and translate them to terminal escape sequences.

**File:** `Sources/TBDApp/Terminal/TBDTerminalView.swift`

**Toggle:** `var naturalTextEditing: Bool = true` — defaults on, no UI yet.

### Key mappings

| Shortcut | Bytes | Purpose |
|----------|-------|---------|
| Cmd+← | `0x01` | Line start (Ctrl-A) |
| Cmd+→ | `0x05` | Line end (Ctrl-E) |
| Cmd+Delete | `0x15` | Delete to line start (Ctrl-U) |
| Opt+Delete | `0x1b, 0x7f` | Delete word back (ESC DEL) |
| Opt+Fn+Delete (forward delete) | `0x1b, 0x64` | Delete word forward (ESC d) |

Opt+← and Opt+→ already work via SwiftTerm's built-in `optionAsMetaKey` handling (sends ESC b / ESC f).

### Integration

`TerminalPanelView.makeNSView` changes from `TerminalView` to `TBDTerminalView`. The coordinator's `terminalView` property type updates accordingly.

### tmux compatibility

All mapped sequences are standard readline/shell sequences that pass through tmux transparently. No tmux-specific handling needed.

## Approach chosen

Subclass TerminalView rather than wrapping with an NSView interceptor. Subclassing is cleaner — `keyDown` is a public override point, avoids responder chain complexity, and keeps the toggle and key handling co-located.
