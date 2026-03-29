# Grouped tmux sessions for independent panel views

## Posture: Make

This is a tmux configuration pattern, not a library dependency. The technique is a handful of tmux commands. No library models this specific multi-panel use case.

## The problem

Multiple UI panels need independent views of the same set of terminal sessions — different current windows, different sizes, different scroll positions. A single tmux connection forces all panels to share state.

## The technique

Use tmux grouped sessions. Each repo gets one tmux server (via `-L` socket name). Each UI panel attaches its own session grouped to a shared server. Panels can navigate independently — switching windows in one panel doesn't affect another.

Each terminal is a tmux window with exactly one pane. No tmux pane splits are used — all spatial layout is managed by the host UI (SwiftUI). This keeps the tmux topology flat and predictable.

Key configuration applied to each server:
- `set -g mouse on` — enables mouse click passthrough for agent team pane switching
- `set -g status off` — TBD owns the tab bar, not tmux
- `set -g xterm-keys on` — passes through extended key sequences (Shift+Arrow)
- `set -g extended-keys-format kitty` — enables Kitty keyboard protocol for Shift+Enter and modifier combos

## Why not alternatives

- **Tmux control mode (`-CC`):** Single controller, shared state, size conflicts between panels. iTerm2 uses this but dedicates ~3000 lines to working around its constraints.
- **Multiple independent servers:** Can't share sessions across panels. Each panel would need its own copy of every terminal.
- **No tmux (direct PTY):** Loses session persistence across app crashes. Tmux's independent process model is the key to crash resilience.

## Where this applies

Any multi-panel terminal UI that needs independent navigation of shared sessions with crash-resilient persistence.
