// Why a libghostty terminal or view could not be made.
//
// These are the reasons a caller acts on: each one means "use another engine for this terminal",
// and the associated value is what goes in the log line that says why. Failures inside the engine
// once it is running are logged where they happen and do not surface here.
import Foundation
import GhosttyVt

/// Why a `GhosttyTerminal` or `GhosttyTerminalView` could not be made.
public enum GhosttyError: Error, LocalizedError, Sendable, Equatable {
    /// `MTLCreateSystemDefaultDevice()` returned nil, so nothing can be drawn.
    case metalUnavailable
    /// `ghostty_terminal_new`, or a terminal option set right after it, failed with this
    /// `GhosttyResult` raw value. nil when there is no result to give: `ghostty_terminal_new`
    /// returned success but no terminal, or the failure did not come from a libghostty call.
    /// Not a sentinel value, because every negative value is a real result:
    /// `GHOSTTY_OUT_OF_MEMORY` is -1.
    case terminalInit(Int32?)
    /// The renderer could not be built: a shader failed to compile, a pipeline or a command queue
    /// could not be made, or a render state could not be allocated. The string says which.
    case renderInit(String)
}

extension GhosttyError: CustomStringConvertible {
    /// What `localizedDescription` returns, payload included. Without it a log line or an alert
    /// gets the NSError bridge string, which drops the payload.
    public var errorDescription: String? { description }

    /// `GHOSTTY_OUT_OF_MEMORY`'s raw value, as `terminalInit` carries it.
    private static let outOfMemory = Int32(truncatingIfNeeded: GHOSTTY_OUT_OF_MEMORY.rawValue)

    public var description: String {
        switch self {
        case .metalUnavailable:
            return "This Mac has no Metal device, so the libghostty terminal cannot draw"
        case .terminalInit(nil):
            return "libghostty could not create a terminal, and reported no GhosttyResult"
        case .terminalInit(let result?) where result == Self.outOfMemory:
            return "libghostty could not create a terminal: out of memory (GhosttyResult \(result))"
        case .terminalInit(let result?):
            return "libghostty could not create a terminal: GhosttyResult \(result)"
        case .renderInit(let reason):
            return "The libghostty terminal's Metal renderer could not be built: \(reason)"
        }
    }
}
