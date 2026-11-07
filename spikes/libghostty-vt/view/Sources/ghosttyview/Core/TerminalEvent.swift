// Adapted from tkzmux c961533 Sources/TkzTerminalCore/TerminalEvent.swift (MIT, see third_party/tkzmux). PORT comments mark vt-1.0.0 changes.
// TerminalEvent.swift — everything a `TerminalSession` can tell the app about.
//
// This enum is the seam. It is deliberately COMPLETE:
// later tickets (M1.9 session semantics, M2 sidebar, M3 Claude integration) consume it and must not
// need to edit this file. Every case is `Sendable` and carries only value types, because events are
// produced on a session's IO queue and consumed on the main actor through an `AsyncStream`.
import Darwin

/// How a session's child process ended.
///
/// Produced by the pty layer (M1.2) and handed to `TerminalSession.noteExit(_:)`; the session
/// republishes it as `TerminalEvent.exited`.
public enum ExitStatus: Hashable, Sendable {
    /// The process exited normally with this status code (`WEXITSTATUS`).
    case exited(code: Int32)
    /// The process was terminated by this signal (`WTERMSIG`).
    case signaled(signal: Int32)

    /// Decodes a `waitpid` status word. Returns `nil` for stop/continue statuses (not an exit).
    public init?(waitStatus: Int32) {
        if (waitStatus & 0o177) == 0 {
            self = .exited(code: (waitStatus >> 8) & 0xFF)
        } else if (waitStatus & 0o177) != 0o177 {
            self = .signaled(signal: waitStatus & 0o177)
        } else {
            return nil
        }
    }

    /// True when the process ended cleanly with status 0.
    public var isClean: Bool { self == .exited(code: 0) }
}

/// The OSC 9;4 progress states, mirrored from `GhosttyTerminalProgressState`.
public enum TerminalProgressState: Hashable, Sendable {
    case remove
    case set
    case error
    case indeterminate
    case pause
}

/// Something the terminal (or its child process) wants the app to know about.
public enum TerminalEvent: Hashable, Sendable {
    /// OSC 0 / OSC 2. The value is read back from `GHOSTTY_TERMINAL_DATA_TITLE`.
    case title(String)

    /// OSC 7 / OSC 9 / OSC 1337 CurrentDir, read back from `GHOSTTY_TERMINAL_DATA_PWD`.
    ///
    /// libghostty stores the bytes the shell emitted **without parsing**: OSC 7 gives a
    /// `file://host/path` URI, OSC 9/1337 give a bare path. Decoding is the consumer's job.
    /// An empty string means the shell cleared the pwd.
    case pwd(String)

    /// BEL (0x07).
    case bell

    /// OSC 9 / OSC 777. `title` is empty when the protocol omits it.
    case notification(title: String, body: String)

    /// OSC 9;4. `value` is the 0…100 percentage, or `nil` when the program omitted it.
    case progress(state: TerminalProgressState, value: Int?)

    /// The child process ended. Published by the pty layer via `noteExit(_:)`.
    case exited(ExitStatus)

    /// The foreground process group of the pty changed (polled by the pty layer, not by the VT).
    case foreground(pgid: pid_t, path: String?, cwd: String?)

    /// OSC 52 / OSC 1337 / OSC 5522 clipboard write. The session answers the protocol itself
    /// (SUCCESS for the standard location, UNSUPPORTED otherwise); this event exists so the app
    /// can actually put the text on `NSPasteboard` on the main actor.
    case clipboardWrite(String)
}
