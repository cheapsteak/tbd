import ArgumentParser
import Darwin
import Dispatch
import Foundation
import TBDShared

struct ChannelsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "channels",
        abstract: "Inter-session message channels",
        subcommands: [
            ChannelsPostCommand.self,
            ChannelsReadCommand.self,
            ChannelsTailCommand.self,
            // list / archive added in later tasks
        ]
    )
}

// MARK: - post

struct ChannelsPostCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "post",
        abstract: "Post a message to a channel"
    )

    @Argument(help: "Channel name (e.g. 'help', 'api-questions'). Use without leading '#'.")
    var name: String

    @Argument(help: "Message body. Use '-' to read from stdin.")
    var body: String

    @Option(name: .long, help: "Override terminal ID (defaults to TBD_TERMINAL_ID env)")
    var terminalID: String?

    @Option(name: .long, help: "Override sender session ID (requires --from-label)")
    var fromSession: String?

    @Option(name: .long, help: "Override sender display label (requires --from-session)")
    var fromLabel: String?

    func validate() throws {
        if (fromSession != nil) != (fromLabel != nil) {
            throw ValidationError("--from-session and --from-label must be specified together")
        }
    }

    mutating func run() async throws {
        // Resolve body from stdin if requested
        var resolvedBody = body
        if body == "-" {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else {
                FileHandle.standardError.write(Data("error: failed to read stdin as UTF-8\n".utf8))
                throw ExitCode.failure
            }
            resolvedBody = text
        }

        // Resolve terminalID
        var resolvedTerminalID: UUID?
        if let s = terminalID {
            guard let id = UUID(uuidString: s) else {
                FileHandle.standardError.write(Data("error: invalid --terminal-id\n".utf8))
                throw ExitCode.failure
            }
            resolvedTerminalID = id
        } else if fromSession == nil {
            // Auto-detect from env
            guard let envID = ProcessInfo.processInfo.environment["TBD_TERMINAL_ID"],
                  let id = UUID(uuidString: envID) else {
                FileHandle.standardError.write(Data("""
                    error: TBD_TERMINAL_ID not set in environment.
                    This command must run inside a TBD-managed terminal,
                    or pass --terminal-id, or --from-session and --from-label.\n
                    """.utf8))
                throw ExitCode.failure
            }
            resolvedTerminalID = id
        }

        let client = SocketClient()
        guard client.isDaemonRunning else {
            FileHandle.standardError.write(Data("error: TBD daemon is not running\n".utf8))
            throw ExitCode.failure
        }

        do {
            let result: ChannelsPostResult = try client.call(
                method: RPCMethod.channelsPost,
                params: ChannelsPostParams(
                    name: name,
                    body: resolvedBody,
                    terminalID: resolvedTerminalID,
                    fromSession: fromSession,
                    fromLabel: fromLabel
                ),
                resultType: ChannelsPostResult.self
            )
            // Friendly output: include a copy-pasteable read suggestion.
            print("Posted to #\(name) (seq \(result.seq))")
            print("→ tbd channels read \(name) --seq \(result.seq)")
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            throw ExitCode.failure
        }
    }
}

// MARK: - read

struct ChannelsReadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "read",
        abstract: "Read messages from a channel (direct file read; daemon not required)"
    )

    @Argument(help: "Channel name (without leading '#').")
    var name: String

    @Option(name: .long, help: "Show just the message with this seq")
    var seq: Int?

    @Option(name: .long, help: "Show messages with seq > this value")
    var since: Int?

    @Option(name: .long, help: "Maximum number of messages to print (default 20)")
    var limit: Int = 20

    func validate() throws {
        if seq != nil && since != nil {
            throw ValidationError("--seq and --since are mutually exclusive")
        }
    }

    mutating func run() async throws {
        let normalized: String
        do {
            normalized = try validateChannelName(name)
        } catch {
            FileHandle.standardError.write(Data("error: invalid channel name: \(error)\n".utf8))
            throw ExitCode.failure
        }

        let path = TBDConstants.channelsDir.appendingPathComponent("\(normalized).jsonl").path
        guard FileManager.default.fileExists(atPath: path) else {
            FileHandle.standardError.write(Data("error: no such channel #\(normalized)\n".utf8))
            throw ExitCode.failure
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        var matched: [(seq: Int, formatted: String)] = []
        var lineStart = 0
        for (idx, byte) in data.enumerated() where byte == 0x0A {
            let lineData = data.subdata(in: lineStart..<idx)
            lineStart = idx + 1
            guard let msg = try? ChannelMessage.decodeLine(lineData) else { continue }

            if let s = seq, msg.seq != s { continue }
            if let since = since, msg.seq <= since { continue }

            matched.append((msg.seq, format(msg)))
        }

        // Apply limit (most recent N when no --seq filter)
        let toPrint: ArraySlice<(seq: Int, formatted: String)>
        if seq != nil {
            toPrint = matched[...]
        } else {
            toPrint = matched.suffix(limit)[...]
        }
        for entry in toPrint { print(entry.formatted) }
    }

    private func format(_ m: ChannelMessage) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = formatter.string(from: m.ts)
        return "[\(ts)] (seq \(m.seq)) \(m.fromLabel): \(m.body)"
    }
}

// MARK: - tail

struct ChannelsTailCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tail",
        abstract: "Stream new messages from a channel as they arrive"
    )

    @Argument(help: "Channel name (without leading '#').")
    var name: String

    @Flag(name: .long, help: "Keep watching after the current end of file")
    var follow: Bool = false

    @Flag(name: .long, help: "Show all existing messages before tailing")
    var fromStart: Bool = false

    mutating func run() async throws {
        let normalized = try validateChannelName(name)
        let url = TBDConstants.channelsDir.appendingPathComponent("\(normalized).jsonl")

        // Ensure the file exists so we have something to open. (If the
        // channel hasn't been posted to yet, --follow would otherwise wait
        // forever on a non-existent file.)
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        if !fromStart {
            try handle.seekToEnd()
        }

        // Print whatever is already there if --from-start.
        try printNewLines(handle: handle)

        if !follow { return }

        // SIGINT must be ignored *before* installing the dispatch source, or
        // the default handler can fire between setup steps.
        signal(SIGINT, SIG_IGN)
        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signalSource.setEventHandler { Darwin.exit(0) }
        signalSource.resume()

        // Watch for VNODE_WRITE | VNODE_EXTEND on the file.
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: handle.fileDescriptor,
            eventMask: [.write, .extend],
            queue: .global(qos: .utility)
        )
        let stream = AsyncStream<Void> { continuation in
            source.setEventHandler { continuation.yield(()) }
            source.setCancelHandler { continuation.finish() }
            source.resume()
        }

        for await _ in stream {
            try printNewLines(handle: handle)
        }
    }

    private func printNewLines(handle: FileHandle) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Read whatever is available now.
        guard let chunk = try handle.read(upToCount: Int.max), !chunk.isEmpty else { return }
        var lineStart = 0
        for (idx, byte) in chunk.enumerated() where byte == 0x0A {
            let lineData = chunk.subdata(in: lineStart..<idx)
            lineStart = idx + 1
            guard let msg = try? ChannelMessage.decodeLine(lineData) else { continue }
            let ts = formatter.string(from: msg.ts)
            print("[\(ts)] (seq \(msg.seq)) \(msg.fromLabel): \(msg.body)")
        }
        // Anything after the last newline is a partial write in progress;
        // the next event will see it complete.
    }
}
