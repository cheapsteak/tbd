import Foundation

/// Incremental, line-oriented parser for the tmux control-mode protocol.
///
/// Feed raw bytes from a `tmux -CC attach` stdout stream via `feed(_:)`; it
/// returns the complete events those bytes produced. A partial trailing line
/// is buffered until its terminating newline arrives.
///
/// Not thread-safe: `feed(_:)` must be called from a single thread (the
/// connection's dedicated reader thread).
final class TmuxControlParser {
    private var lineBuffer = Data()

    /// When inside a `%begin`…`%end`/`%error` block, the in-progress block.
    private var openBlock: (number: Int, lines: [String])?

    /// Feed raw stdout bytes; returns events completed by this chunk.
    func feed(_ data: Data) -> [TmuxControlEvent] {
        lineBuffer.append(data)
        var events: [TmuxControlEvent] = []
        while let newlineIndex = lineBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            var slice = Data(lineBuffer[lineBuffer.startIndex..<newlineIndex])
            if slice.last == UInt8(ascii: "\r") { slice.removeLast() }
            lineBuffer.removeSubrange(lineBuffer.startIndex...newlineIndex)
            if let event = parseLine(String(decoding: slice, as: UTF8.self)) {
                events.append(event)
            }
        }
        return events
    }

    private func parseLine(_ line: String) -> TmuxControlEvent? {
        // Inside a command block, every line is response text until %end/%error.
        if openBlock != nil {
            if line.hasPrefix("%end ") || line.hasPrefix("%error ") {
                return closeBlock(line)
            }
            openBlock?.lines.append(line)
            return nil
        }

        guard line.hasPrefix("%") else {
            return line.isEmpty ? nil : .unhandled(line: line)
        }

        let fields = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        switch fields[0] {
        case "%output":
            return .unhandled(line: line)            // implemented in Task 5
        case "%extended-output":
            return .unhandled(line: line)            // implemented in Task 5
        case "%begin":
            return .unhandled(line: line)            // implemented in Task 6
        case "%window-add":
            return fields.count >= 2 ? .windowAdd(windowID: fields[1]) : .unhandled(line: line)
        case "%window-close", "%unlinked-window-close":
            return fields.count >= 2 ? .windowClose(windowID: fields[1]) : .unhandled(line: line)
        case "%layout-change":
            return fields.count >= 3
                ? .layoutChange(windowID: fields[1], layout: fields[2])
                : .unhandled(line: line)
        case "%pause":
            return fields.count >= 2 ? .pause(paneID: fields[1]) : .unhandled(line: line)
        case "%continue":
            return fields.count >= 2 ? .continue(paneID: fields[1]) : .unhandled(line: line)
        case "%exit":
            let reason = fields.count >= 2 ? fields[1...].joined(separator: " ") : nil
            return .exit(reason: reason)
        default:
            return .unhandled(line: line)
        }
    }

    private func closeBlock(_ line: String) -> TmuxControlEvent {
        let block = openBlock!
        openBlock = nil
        return line.hasPrefix("%end ")
            ? .commandSucceeded(number: block.number, lines: block.lines)
            : .commandFailed(number: block.number, lines: block.lines)
    }
}
