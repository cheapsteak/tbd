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
    /// `fromClient` is bit 0 of the `%begin` flags field (see `parseLine`).
    private var openBlock: (number: Int, fromClient: Bool, lines: [String])?

    /// Feed raw stdout bytes; returns events completed by this chunk.
    func feed(_ data: Data) -> [TmuxControlEvent] {
        lineBuffer.append(data)
        var events: [TmuxControlEvent] = []
        while let newlineIndex = lineBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            var slice = Data(lineBuffer[lineBuffer.startIndex..<newlineIndex])
            if slice.last == UInt8(ascii: "\r") { slice.removeLast() }
            lineBuffer.removeSubrange(lineBuffer.startIndex...newlineIndex)
            if let event = parseLine(String(bytes: slice, encoding: .utf8) ?? "") {
                events.append(event)
            }
        }
        return events
    }

    private func parseLine(_ line: String) -> TmuxControlEvent? {
        // Inside a command block, every line is response text until %end/%error.
        if openBlock != nil {
            if line == "%end" || line.hasPrefix("%end ")
                || line == "%error" || line.hasPrefix("%error ") {
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
            return parseOutput(fields: fields, line: line)
        case "%extended-output":
            return parseExtendedOutput(fields: fields, line: line)
        case "%begin":
            // `%begin <time> <number> <flags>`; flags bit 0 = replies to a
            // command this client wrote (missing/malformed → not from client).
            let fromClient = fields.count >= 4 ? ((Int(fields[3]) ?? 0) & 1) == 1 : false
            openBlock = (number: fields.count >= 3 ? (Int(fields[2]) ?? -1) : -1,
                         fromClient: fromClient, lines: [])
            return nil
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

    private func parseOutput(fields: [String], line: String) -> TmuxControlEvent {
        guard fields.count >= 2 else { return .unhandled(line: line) }
        let payload = payloadAfterSpaces(2, in: line)
        return .output(paneID: fields[1], bytes: TmuxOutputDecoder.decode(payload))
    }

    private func parseExtendedOutput(fields: [String], line: String) -> TmuxControlEvent {
        guard fields.count >= 4, let age = Int(fields[2]),
              let colon = line.range(of: " : ") else { return .unhandled(line: line) }
        let payload = String(line[colon.upperBound...])
        return .extendedOutput(paneID: fields[1], ageMillis: age,
                               bytes: TmuxOutputDecoder.decode(payload))
    }

    /// Returns the remainder of `line` after the first `count` space-separated
    /// tokens (and the space following the last of them). Used for `%output`,
    /// whose payload may contain literal spaces and must not be field-split.
    private func payloadAfterSpaces(_ count: Int, in line: String) -> String {
        var seen = 0
        var idx = line.startIndex
        while idx < line.endIndex {
            if line[idx] == " " {
                seen += 1
                if seen == count { return String(line[line.index(after: idx)...]) }
            }
            idx = line.index(after: idx)
        }
        return ""
    }

    private func closeBlock(_ line: String) -> TmuxControlEvent {
        let block = openBlock!
        openBlock = nil
        return line == "%end" || line.hasPrefix("%end ")
            ? .commandSucceeded(number: block.number, fromClient: block.fromClient, lines: block.lines)
            : .commandFailed(number: block.number, fromClient: block.fromClient, lines: block.lines)
    }
}
