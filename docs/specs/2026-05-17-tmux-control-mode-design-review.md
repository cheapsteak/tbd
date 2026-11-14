# Review: tmux control mode integration design

**Date:** 2026-05-17
**Reviewed doc:** [`2026-05-17-tmux-control-mode-design.md`](./2026-05-17-tmux-control-mode-design.md)

## Findings

1. **`capture-pane` replay is not established as a valid terminal byte stream.**

   The design treats `capture-pane -peqJ` output as replayable terminal input: the daemon writes the capture into a freshly vended pipe before live `%output` resumes, and "SwiftTerm sees one byte stream" ([design lines 93-100](./2026-05-17-tmux-control-mode-design.md#scrollback), especially line 96).

   `capture-pane` is a rendered snapshot/history export, not a faithful terminal-state stream. Feeding it into SwiftTerm before live `%output` can leave cursor position, alternate-screen state, cleared regions, wrapping state, and current-screen contents wrong when live bytes resume. The iTerm2 reference is not enough to prove this approach: iTerm2 parses tmux history into its screen model rather than simply prepending raw capture text to a live terminal byte stream.

   This undermines the central scrollback decision. The spec should either redesign this as explicit screen/history reconstruction, or mark raw capture replay as an implementation risk that requires a prototype before the architecture is considered resolved.

2. **Attach replay can deadlock on pipe capacity.**

   The first-attach flow says the daemon creates a pipe, issues `capture-pane -peqJ -S -50000`, writes the capture into the pipe, then vends the read FD to the app ([design lines 146-155](./2026-05-17-tmux-control-mode-design.md#pane-first-attached)). The same doc notes Darwin pipe buffers are small, roughly 16-64 KB ([line 182](./2026-05-17-tmux-control-mode-design.md#constraints-this-design-imposes)), while the proposed 50,000-line history may be 10-20 MB per pane ([line 97](./2026-05-17-tmux-control-mode-design.md#scrollback)).

   If the daemon writes the full capture before the app has the read FD and a reader running, the write can block indefinitely. The attach protocol needs to vend first and stream concurrently, use a spool/temp file, make the pipe nonblocking with a clear drain loop, or otherwise define replay backpressure separately from live `%output` flow control.

3. **`history-limit` migration is unspecified.**

   The design proposes setting tmux `history-limit` to 50,000 lines for TBD-managed sessions ([line 97](./2026-05-17-tmux-control-mode-design.md#scrollback)). tmux applies `history-limit` to new window histories; existing windows keep the limit they had when created.

   Without a migration policy, upgraded existing panes will silently retain the old limit, so reattach behavior and truncation telemetry will vary by pane age. The implementation plan should specify where the option is set before window creation and what happens to existing tmux servers/windows during upgrade.

4. **Resize target type is inconsistent.**

   The resize flow shows `resize-window -t %42 -x W -y H` ([line 173](./2026-05-17-tmux-control-mode-design.md#resize)), but `resize-window` is a window operation and TBD already stores both `tmuxWindowID` and `tmuxPaneID`.

   Since this design relies on daemon-authoritative sizing, the spec should consistently use window IDs for `resize-window`, or explicitly document pane-target resolution if tmux accepts it across the intended version range.

## Context Checked

- Current TBD terminal integration is grouped-session/direct-PTY based in `Sources/TBDApp/Terminal/TmuxBridge.swift` and `Sources/TBDApp/Terminal/TerminalPanelView.swift`.
- SwiftTerm currently receives bytes from `LocalProcessDelegate.dataReceived`, not from daemon-vended FDs.
- Current tmux setup in `Sources/TBDDaemon/Tmux/TmuxManager.swift` sets status/mouse/keyboard options but does not set `history-limit`.
- Local tmux version checked: `tmux 3.6a`.
