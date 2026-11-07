// Why a libghostty terminal or view could not be made.
//
// These are the reasons a caller acts on: each one means "use another engine for this terminal",
// and the associated value is what goes in the log line that says why. Failures inside the engine
// once it is running are logged where they happen and do not surface here.

/// Why a `GhosttyTerminal` or `GhosttyTerminalView` could not be made.
public enum GhosttyError: Error, Sendable, Equatable {
    /// `MTLCreateSystemDefaultDevice()` returned nil, so nothing can be drawn.
    case metalUnavailable
    /// `ghostty_terminal_new`, or a terminal option set right after it, failed with this
    /// `GhosttyResult` raw value.
    case terminalInit(Int32)
    /// The renderer could not be built: a shader failed to compile, a pipeline or a command queue
    /// could not be made, or a render state could not be allocated. The string says which.
    case renderInit(String)
}

extension GhosttyError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .metalUnavailable: return "no Metal device"
        case .terminalInit(let result): return "libghostty terminal init failed (result \(result))"
        case .renderInit(let reason): return "libghostty renderer init failed: \(reason)"
        }
    }
}
