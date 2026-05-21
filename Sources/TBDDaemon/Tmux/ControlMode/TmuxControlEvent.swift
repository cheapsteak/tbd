import Foundation

/// A single decoded tmux control-mode notification.
///
/// `tmux -CC attach` emits line-oriented notifications prefixed with `%`.
/// This enum is the parser's output vocabulary. Notifications the parser does
/// not model in detail surface as `.unhandled` rather than being dropped, so
/// logging reveals protocol surface we have not covered yet.
enum TmuxControlEvent: Equatable {
    /// `%output %<pane> <data>` — program output. `bytes` is octal-unescaped.
    case output(paneID: String, bytes: Data)

    /// `%extended-output %<pane> <age> : <data>` — output delivered while the
    /// pane was paused; `ageMillis` is the delay in milliseconds.
    case extendedOutput(paneID: String, ageMillis: Int, bytes: Data)

    /// A completed `%begin`…`%end` command-response block. `lines` are the raw
    /// response lines between the markers.
    case commandSucceeded(number: Int, lines: [String])

    /// A completed `%begin`…`%error` command-response block (command failed).
    case commandFailed(number: Int, lines: [String])

    /// `%window-add @<window>` — a window was created.
    case windowAdd(windowID: String)

    /// `%window-close @<window>` — a window was closed.
    case windowClose(windowID: String)

    /// `%layout-change @<window> <layout> <visible-layout> <flags>`.
    case layoutChange(windowID: String, layout: String)

    /// `%pause %<pane>` — tmux paused output for a pane.
    case pause(paneID: String)

    /// `%continue %<pane>` — tmux resumed output for a pane.
    case `continue`(paneID: String)

    /// `%exit [<reason>]` — the tmux server is detaching this control client.
    case exit(reason: String?)

    /// A `%`-prefixed notification recognized by name but not modeled, or not
    /// recognized at all. Carries the raw line for logging.
    case unhandled(line: String)
}
