import Foundation
import SwiftTerm

/// Supplies DECRQM answers. The caller owns the delegate plumbing because the
/// daemon's headless emulator and the app's view route replies to different
/// places, and neither may let a query reach the child process.
public protocol ModeReplyReader {
    /// Returns DECRQM's `Ps`: 1 set, 2 reset, 4 permanently reset, 0 unknown;
    /// nil when the terminal did not answer.
    func requestMode(_ mode: Int, decPrivate: Bool) -> Int?
}

public struct CapturedTerminalState: Sendable, Equatable {
    public var cols: Int
    public var rows: Int
    public var cursorX: Int
    public var cursorY: Int
    public var alternateOn: Bool
    public var applicationCursor: Bool
    public var applicationKeypad: Bool
    public var originMode: Bool
    public var wraparound: Bool
    public var reverseWraparound: Bool
    public var insertMode: Bool
    public var marginMode: Bool
    public var cursorVisible: Bool
    public var bracketedPaste: Bool
    /// 1000, 1002 or 1003 — the tracking modes are mutually exclusive.
    public var mouseTracking: Int?
    public var sgrMouseEncoding: Bool
    public var focusReporting: Bool
    public var scrollTop: Int
    public var scrollBottom: Int
    public var savedX: Int?
    public var savedY: Int?
}

public enum TerminalModeCapture {
    public static func capture(
        from terminal: Terminal, reply: ModeReplyReader
    ) -> CapturedTerminalState {
        func isSet(_ mode: Int, decPrivate: Bool = true) -> Bool {
            reply.requestMode(mode, decPrivate: decPrivate) == 1
        }

        let tracking = [1003, 1002, 1000].first { isSet($0) }

        return CapturedTerminalState(
            cols: terminal.cols,
            rows: terminal.rows,
            cursorX: terminal.buffer.x,
            cursorY: terminal.buffer.y,
            // Mode 1049 is NOT in cmdDecRqm's switch — it answers "unknown".
            // The public property is the only correct source.
            alternateOn: terminal.isCurrentBufferAlternate,
            applicationCursor: terminal.applicationCursor,
            applicationKeypad: isSet(66),
            originMode: isSet(6),
            wraparound: isSet(7),
            reverseWraparound: isSet(45),
            insertMode: isSet(4, decPrivate: false),
            marginMode: isSet(69),
            cursorVisible: isSet(25),
            bracketedPaste: terminal.bracketedPasteMode,
            mouseTracking: tracking,
            sgrMouseEncoding: isSet(1006),
            focusReporting: isSet(1004),
            scrollTop: terminal.buffer.scrollTop,
            scrollBottom: terminal.buffer.scrollBottom,
            // tmux reports UINT_MAX when nothing was saved; SwiftTerm has no
            // such sentinel, so a zero saved cursor is indistinguishable from
            // "never saved" and is carried as-is. The saved MODES
            // (savedOriginMode and friends) are internal and cannot be read —
            // an accepted v1 loss, recorded in the plan's facts section.
            savedX: terminal.buffer.savedX,
            savedY: terminal.buffer.savedY)
    }
}
