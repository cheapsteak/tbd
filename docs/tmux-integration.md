# Tmux Integration: Learnings & Architecture

How TBD integrates with tmux, what we tried, what worked, and why.

## Architecture: Grouped Sessions + Direct PTY

Each terminal panel in TBD gets its own tmux client via a **grouped session**. SwiftTerm connects to the PTY natively — no protocol parsing needed.

```
┌─────────────────────────────────────────────┐
│  tmux server: tbd-a1b2c3d4                  │
│                                             │
│  Session "main" (daemon-managed, persists)  │
│    Window @1: claude code                   │
│    Window @2: setup hook                    │
│    Window @3: claude code                   │
│    Window @4: setup hook                    │
│                                             │
│  Session "tbd-view-abc123" (grouped)        │
│    → shares all windows with "main"         │
│    → independent current-window pointer     │
│    → currently viewing @1                   │
│                                             │
│  Session "tbd-view-def456" (grouped)        │
│    → shares all windows with "main"         │
│    → currently viewing @3                   │
│                                             │
└─────────────────────────────────────────────┘
```

### How it works

1. **Daemon** creates tmux windows in session `main` (one tmux server per repo)
2. **App** creates a grouped session per visible terminal panel: `tmux new-session -d -t main -s tbd-view-<uuid>`
3. **App** selects the right window: `tmux select-window -t tbd-view-<uuid>:@3`
4. **SwiftTerm** spawns `tmux attach -t tbd-view-<uuid>` in a native PTY via `LocalProcess`
5. **On hide**: `tmux kill-session -t tbd-view-<uuid>` — the grouped session dies, but `main` persists
6. **On app close/reopen**: all grouped sessions die, `main` persists. App creates new grouped sessions on demand.

### Why grouped sessions

- Each client has **independent current-window** — switching windows in one panel doesn't affect others
- Each client has **independent size** — no size conflicts between panels of different dimensions
- **Session persistence** — the `main` session survives app restarts, tmux handles all scrollback
- **Native PTY** — SwiftTerm works exactly as designed, all input/output/resize through the terminal driver

## What We Tried First: Control Mode (-CC)

We initially used `tmux -CC attach` (control mode), where tmux sends structured protocol messages instead of rendering its TUI:

```
%output %3 \033[31mhello\033[0m
%begin 1234567890 42 0
%end 1234567890 42 0
%window-add @5
```

### Why control mode failed for us

1. **Complexity**: iTerm2 has ~3,000 lines dedicated to its tmux gateway (`TmuxGateway.m`, `TmuxController.m`, `TmuxWindowOpener.m`). No other terminal has successfully implemented it — [Ghostty](https://github.com/ghostty-org/ghostty/issues/1935) and [Windows Terminal](https://github.com/microsoft/terminal/issues/5612) both have open feature requests.

2. **Size synchronization**: `refresh-client -C cols,rows` sets the control client size, which constrains ALL windows. Multiple panels of different sizes cause constant resize fights.

3. **`%output` is streaming, not stateful**: Control mode only sends output *changes*. When SwiftUI recreates a view (switching tabs, polling updates), all prior content is lost. Workaround (`capture-pane`) produced staircase rendering because its output format (`\n` line endings) differs from live terminal output (`\r\n`).

4. **Input encoding**: `send-keys -l` (literal mode) can't handle control characters like Enter (`\r`). `send-keys -H` (hex) works but adds complexity.

5. **Actor/threading conflicts**: The blocking `availableData` read loop blocked the Swift actor, preventing `registerPane` and `sendKeys` from executing.

### Control mode IS the right approach if:
- You're building a full terminal emulator with dedicated tmux integration code (like iTerm2)
- You want to render tmux panes without tmux's TUI
- You have resources to handle all the edge cases (~3,000+ lines)

### Control mode is the WRONG approach if:
- You want to embed terminals quickly with an existing terminal emulator library
- You have multiple panels of different sizes
- You want session persistence without complex state management

## Tmux Concepts Reference

### Hierarchy
```
Server (socket: /tmp/tmux-UID/tbd-xxx)
  └── Session (named: "main")
        └── Window (@1, @2, ...) — like tabs
              └── Pane (%0, %1, ...) — splits within a window
```

### Key commands

```bash
# Server management (use -L for custom socket name)
tmux -L myserver new-session -s main -d     # create server + session
tmux -L myserver kill-server                 # kill everything

# Grouped sessions (share windows, independent focus)
tmux -L myserver new-session -t main -s view1   # create grouped session
tmux -L myserver select-window -t view1:@3      # select window in grouped session
tmux -L myserver kill-session -t view1           # kill grouped session only

# Window management
tmux -L myserver new-window -t main -c /path    # create window
tmux -L myserver kill-window -t @3               # kill window
tmux -L myserver list-windows -t main            # list windows

# Pane info
tmux -L myserver list-panes -a -F '#{window_id} #{pane_id} #{pane_current_command}'

# Hide tmux chrome (for embedding)
tmux -L myserver set -g status off              # hide status bar
tmux -L myserver set -g pane-border-style fg=black  # hide pane borders

# Input
tmux -L myserver send-keys -t %3 -H 68 65 6C 6C 6F 0D  # send "hello\r" as hex

# Capture pane content (careful: output uses \n not \r\n)
tmux -L myserver capture-pane -p -e -t %3       # print with ANSI escapes
```

### Size management

- `refresh-client -C cols,rows` — sets control client size (affects ALL windows)
- `resize-window -t @3 -x cols -y rows` — resize specific window
- `resize-pane -t %3 -x cols -y rows` — resize specific pane
- With grouped sessions, each client has its own size naturally via the PTY

### Session groups

When you create a session with `-t existing-session`, the new session **shares all windows** with the target but maintains:
- Its own "current window" pointer
- Its own attached client size
- Its own key bindings and options (if set per-session)

This is the key feature that makes embedding work — multiple viewers can look at different windows simultaneously without interfering.

## Resources

- [tmux Control Mode Wiki](https://github.com/tmux/tmux/wiki/Control-Mode) — protocol spec, notification format
- [iTerm2 tmux Integration Docs](https://iterm2.com/documentation-tmux-integration.html) — user-facing docs for -CC mode
- [iTerm2 tmux Architecture (DeepWiki)](https://deepwiki.com/gnachman/iTerm2/5.2-tmux-integration) — internal architecture: TmuxGateway, TmuxController, TmuxWindowOpener
- [iTerm2 tmux Best Practices](https://gitlab.com/gnachman/iterm2/-/wikis/tmux-Integration-Best-Practices) — tips from the iTerm2 wiki
- [tmux Getting Started Wiki](https://github.com/tmux/tmux/wiki/Getting-Started) — covers session groups, window management
- [Ghostty control mode request](https://github.com/ghostty-org/ghostty/issues/1935) — discussion of challenges
- [Windows Terminal control mode request](https://github.com/microsoft/terminal/issues/5612) — more discussion of challenges
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — the terminal emulator library we use
- [tmux man page](https://man.openbsd.org/tmux.1) — authoritative reference
