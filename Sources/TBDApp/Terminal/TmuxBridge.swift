import Foundation

// MARK: - Octal Escape Decoder

/// Decodes tmux control mode octal-escaped strings into raw `Data`.
///
/// Tmux `%output` notifications encode non-printable bytes as `\NNN` (octal).
/// For example: `\033` = ESC (0x1B), `\012` = newline (0x0A), `\\` = literal backslash.
/// Regular text passes through as-is.
func decodeOctalEscapes(_ string: String) -> Data {
    var result = Data()
    result.reserveCapacity(string.utf8.count)

    var iterator = string.utf8.makeIterator()

    while let byte = iterator.next() {
        if byte == UInt8(ascii: "\\") {
            // Look at next character
            guard let next = iterator.next() else {
                // Trailing backslash, emit it
                result.append(byte)
                break
            }

            if next == UInt8(ascii: "\\") {
                // Escaped backslash
                result.append(UInt8(ascii: "\\"))
            } else if next >= UInt8(ascii: "0") && next <= UInt8(ascii: "3") {
                // Potential octal sequence: \NNN (3 digits, first digit 0-3 for values 0-255)
                guard let d1 = iterator.next(),
                      d1 >= UInt8(ascii: "0") && d1 <= UInt8(ascii: "7"),
                      let d2 = iterator.next(),
                      d2 >= UInt8(ascii: "0") && d2 <= UInt8(ascii: "7") else {
                    // Not a valid 3-digit octal, emit what we have
                    result.append(byte)
                    result.append(next)
                    // d1/d2 already consumed if they existed but were invalid;
                    // this is a best-effort parser for well-formed tmux output
                    continue
                }
                let val = (next - UInt8(ascii: "0")) * 64
                    + (d1 - UInt8(ascii: "0")) * 8
                    + (d2 - UInt8(ascii: "0"))
                result.append(val)
            } else {
                // Unknown escape, emit both characters
                result.append(byte)
                result.append(next)
            }
        } else {
            result.append(byte)
        }
    }

    return result
}

// MARK: - TmuxBridge

/// Manages tmux control mode connections, one per repo server.
///
/// Each connection launches `tmux -L <server> -CC attach -t main` and parses the
/// control mode protocol, routing pane output to registered handlers.
actor TmuxBridge {
    /// Represents a single tmux control mode connection.
    private final class TmuxConnection {
        let server: String
        let process: Process
        let stdinPipe: Pipe
        let stdoutPipe: Pipe
        var paneHandlers: [String: @Sendable (Data) -> Void] = [:]
        var readTask: Task<Void, Never>?

        /// Accumulates lines between %begin and %end for command response blocks.
        var commandBlock: [String]?

        init(server: String, process: Process, stdinPipe: Pipe, stdoutPipe: Pipe) {
            self.server = server
            self.process = process
            self.stdinPipe = stdinPipe
            self.stdoutPipe = stdoutPipe
        }
    }

    /// Active connections keyed by server name.
    private var connections: [String: TmuxConnection] = [:]

    /// Delegate for receiving non-output notifications (window add/close, exit, etc.).
    var onWindowAdd: (@Sendable (String, String) -> Void)?
    var onWindowClose: (@Sendable (String, String) -> Void)?
    var onExit: (@Sendable (String, String?) -> Void)?

    // MARK: - Connection Management

    /// Launch a tmux control mode connection for the given server.
    ///
    /// Runs `tmux -L <server> -CC attach -t main` and begins parsing stdout.
    func connect(server: String) throws {
        guard connections[server] == nil else { return }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tmux", "-L", server, "-CC", "attach", "-t", "main"]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let connection = TmuxConnection(
            server: server,
            process: process,
            stdinPipe: stdinPipe,
            stdoutPipe: stdoutPipe
        )

        do {
            try process.run()
        } catch {
            throw TmuxBridgeError.launchFailed(server: server, underlying: error)
        }

        connections[server] = connection

        // Start background reading task
        let readTask = Task.detached { [weak self] in
            await self?.readLoop(server: server)
            return
        }
        connection.readTask = readTask
    }

    /// Disconnect from the given server, killing the tmux control mode process.
    func disconnect(server: String) {
        guard let connection = connections.removeValue(forKey: server) else { return }
        connection.readTask?.cancel()
        connection.process.terminate()
        connection.stdinPipe.fileHandleForWriting.closeFile()
    }

    // MARK: - Pane Registration

    /// Register a handler to receive decoded output for a specific pane.
    func registerPane(server: String, paneID: String, handler: @Sendable @escaping (Data) -> Void) {
        guard let connection = connections[server] else { return }
        connection.paneHandlers[paneID] = handler
    }

    /// Unregister a pane output handler.
    func unregisterPane(server: String, paneID: String) {
        guard let connection = connections[server] else { return }
        connection.paneHandlers.removeValue(forKey: paneID)
    }

    // MARK: - Commands

    /// Send text input to a specific pane via `send-keys`.
    ///
    /// The `-l` flag sends literal text (no key name lookup).
    func sendKeys(server: String, paneID: String, text: String) {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let command = "send-keys -t \(paneID) -l -- \"\(escaped)\"\n"
        writeCommand(server: server, command: command)
    }

    /// Resize a tmux window.
    func resizeWindow(server: String, windowID: String, width: Int, height: Int) {
        let command = "resize-window -t \(windowID) -x \(width) -y \(height)\n"
        writeCommand(server: server, command: command)
    }

    /// Write a raw command string to the tmux control mode stdin.
    func writeCommand(server: String, command: String) {
        guard let connection = connections[server] else { return }
        guard let data = command.data(using: .utf8) else { return }
        connection.stdinPipe.fileHandleForWriting.write(data)
    }

    // MARK: - Stdout Read Loop

    /// Reads stdout line-by-line from the tmux control mode process and dispatches
    /// parsed notifications. Runs on a background thread via `Task.detached`.
    private func readLoop(server: String) async {
        guard let connection = connections[server] else { return }

        let fileHandle = connection.stdoutPipe.fileHandleForReading
        var buffer = Data()
        let newline = UInt8(ascii: "\n")

        while !Task.isCancelled {
            let chunk: Data
            do {
                chunk = fileHandle.availableData
            }

            guard !chunk.isEmpty else {
                // EOF — process exited
                await handleExit(server: server, reason: "process exited")
                break
            }

            buffer.append(chunk)

            // Extract complete lines from the buffer
            while let newlineIndex = buffer.firstIndex(of: newline) {
                let lineData = buffer[buffer.startIndex..<newlineIndex]
                buffer = Data(buffer[(newlineIndex + 1)...])

                if let line = String(data: Data(lineData), encoding: .utf8) {
                    await parseLine(server: server, line: line)
                }
            }
        }
    }

    // MARK: - Protocol Parsing

    /// Parse a single line of tmux control mode protocol output.
    private func parseLine(server: String, line: String) async {
        guard let connection = connections[server] else { return }

        // Inside a command response block, accumulate lines until %end
        if connection.commandBlock != nil {
            if line.hasPrefix("%end ") {
                connection.commandBlock = nil
            } else {
                connection.commandBlock?.append(line)
            }
            return
        }

        if line.hasPrefix("%output ") {
            parseOutput(connection: connection, line: line)
        } else if line.hasPrefix("%begin ") {
            connection.commandBlock = []
        } else if line.hasPrefix("%exit") {
            let reason = line.count > 5 ? String(line.dropFirst(6)) : nil
            await handleExit(server: server, reason: reason)
        } else if line.hasPrefix("%window-add ") {
            let windowID = String(line.dropFirst("%window-add ".count))
            onWindowAdd?(server, windowID)
        } else if line.hasPrefix("%window-close ") {
            let windowID = String(line.dropFirst("%window-close ".count))
            onWindowClose?(server, windowID)
        } else if line.hasPrefix("%pause ") {
            // Flow control: pause output for pane. For now we log and continue;
            // full flow control would involve buffering/throttling.
            let paneID = String(line.dropFirst("%pause ".count))
            _ = paneID // placeholder for future flow control
        } else if line.hasPrefix("%continue ") {
            // Flow control: resume output for pane.
            let paneID = String(line.dropFirst("%continue ".count))
            _ = paneID // placeholder for future flow control
        }
        // Other lines (e.g., session info on attach) are ignored.
    }

    /// Parse a `%output <pane-id> <octal-escaped-data>` notification.
    private func parseOutput(connection: TmuxConnection, line: String) {
        // Format: %output %<pane-id> <data>
        // Example: %output %0 \033[31mhello\033[0m
        let content = String(line.dropFirst("%output ".count))

        guard let spaceIndex = content.firstIndex(of: " ") else { return }

        let paneID = String(content[content.startIndex..<spaceIndex])
        let escapedData = String(content[content.index(after: spaceIndex)...])
        let decoded = decodeOctalEscapes(escapedData)

        if let handler = connection.paneHandlers[paneID] {
            handler(decoded)
        }
    }

    /// Handle a tmux exit / disconnect event.
    private func handleExit(server: String, reason: String?) async {
        if let connection = connections.removeValue(forKey: server) {
            connection.readTask?.cancel()
            connection.process.terminate()
        }
        onExit?(server, reason)
    }
}

// MARK: - Errors

enum TmuxBridgeError: Error, CustomStringConvertible {
    case launchFailed(server: String, underlying: Error)
    case notConnected(server: String)

    var description: String {
        switch self {
        case .launchFailed(let server, let underlying):
            "Failed to launch tmux for server '\(server)': \(underlying)"
        case .notConnected(let server):
            "Not connected to tmux server '\(server)'"
        }
    }
}
