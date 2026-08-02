import Foundation
import os

private let codexImportLogger = Logger(
    subsystem: "com.tbd.daemon", category: "codex-session-import")

enum CodexSessionImportError: LocalizedError, Equatable {
    case appServer(String)
    case malformedResponse(String)
    case processExited(Int32)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .appServer(let message):
            return "Codex could not import this session: \(message)"
        case .malformedResponse(let detail):
            return "Codex returned an invalid session-import response: \(detail)"
        case .processExited(let status):
            return "Codex app-server exited before the session import completed (status \(status))."
        case .timedOut:
            return "Codex did not finish importing the session before the deadline."
        }
    }
}

protocol CodexAppServerConnection: Sendable {
    func send(_ line: Data) throws
    func receive() async throws -> Data
    func close()
}

protocol CodexAppServerTransport: Sendable {
    func connect(executablePath: String, codexHome: URL) async throws
        -> any CodexAppServerConnection
}

/// Imports one Claude transcript through Codex's native app-server protocol.
///
/// The public operation accepts a single session, not arbitrary migration
/// items. That type boundary prevents callers from forwarding `detect` output,
/// whose sibling item types can rewrite Codex configuration, hooks, and skills.
struct CodexSessionImporter: Sendable {
    let executablePath: String
    let codexHome: URL
    let transport: any CodexAppServerTransport
    let timeout: Duration
    let clock: any Clock<Duration>

    init(
        executablePath: String,
        codexHome: URL,
        transport: any CodexAppServerTransport = ProcessCodexAppServerTransport(),
        timeout: Duration = .seconds(10),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.executablePath = executablePath
        self.codexHome = codexHome
        self.transport = transport
        self.timeout = timeout
        self.clock = clock
    }

    func importSession(
        transcriptPath: String,
        cwd: String,
        title: String? = nil
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await performImport(
                    transcriptPath: transcriptPath,
                    cwd: cwd,
                    title: title)
            }
            group.addTask {
                try await clock.sleep(for: timeout)
                throw CodexSessionImportError.timedOut
            }

            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw CodexSessionImportError.malformedResponse(
                    "the app-server conversation ended without a result")
            }
            return result
        }
    }

    private func performImport(
        transcriptPath: String,
        cwd: String,
        title: String?
    ) async throws -> String {
        let connection = try await transport.connect(
            executablePath: executablePath,
            codexHome: codexHome)
        return try await withTaskCancellationHandler(operation: {
            defer { connection.close() }

            try connection.send(try Self.initializeRequest())
            try await expectResponse(id: 1, from: connection)
            try connection.send(try Self.initializedNotification())
            try connection.send(try Self.importRequest(
                transcriptPath: transcriptPath,
                cwd: cwd,
                title: title))

            let importID = try await expectImportResponse(from: connection)
            while true {
                let line = try await connection.receive()
                if let target = try Self.importTarget(
                    from: line,
                    matchingImportID: importID) {
                    codexImportLogger.info(
                        "Imported Claude transcript into Codex thread \(target, privacy: .public)")
                    return target
                }
            }
        }, onCancel: {
            connection.close()
        })
    }

    private func expectResponse(
        id: Int,
        from connection: any CodexAppServerConnection
    ) async throws {
        while true {
            let object = try Self.object(from: try await connection.receive())
            guard Self.integerID(in: object) == id else { continue }
            if let message = Self.errorMessage(in: object) {
                throw CodexSessionImportError.appServer(message)
            }
            guard object["result"] != nil else {
                throw CodexSessionImportError.malformedResponse(
                    "request \(id) had neither a result nor an error")
            }
            return
        }
    }

    private func expectImportResponse(
        from connection: any CodexAppServerConnection
    ) async throws -> String {
        while true {
            let object = try Self.object(from: try await connection.receive())
            guard Self.integerID(in: object) == 2 else { continue }
            if let message = Self.errorMessage(in: object) {
                throw CodexSessionImportError.appServer(message)
            }
            guard let result = object["result"] as? [String: Any],
                  let importID = result["importId"] as? String,
                  !importID.isEmpty else {
                throw CodexSessionImportError.malformedResponse(
                    "the import response did not contain importId")
            }
            return importID
        }
    }

    static func importTarget(
        from data: Data,
        matchingImportID: String
    ) throws -> String? {
        let object = try object(from: data)
        guard object["method"] as? String
                == "externalAgentConfig/import/completed",
              let params = object["params"] as? [String: Any],
              params["importId"] as? String == matchingImportID,
              let results = params["itemTypeResults"] as? [[String: Any]] else {
            return nil
        }

        for result in results where result["itemType"] as? String == "SESSIONS" {
            if let failures = result["failures"] as? [[String: Any]],
               let failure = failures.first {
                let message = failure["message"] as? String
                    ?? "Codex reported an unspecified session-import failure"
                throw CodexSessionImportError.appServer(message)
            }

            guard let successes = result["successes"] as? [[String: Any]] else {
                continue
            }
            // Codex 0.146 repeats `itemType` on each success. The 0.145
            // response observed during the original design omitted it and
            // relied on the enclosing SESSIONS result. Accept both shapes,
            // while rejecting an explicitly different item type.
            for success in successes {
                if let itemType = success["itemType"] as? String,
                   itemType != "SESSIONS" {
                    continue
                }
                if let target = success["target"] as? String, !target.isEmpty {
                    return target
                }
            }
        }

        throw CodexSessionImportError.malformedResponse(
            "the completed notification contained no successful SESSIONS target")
    }

    static func initializeRequest() throws -> Data {
        try jsonLine([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "clientInfo": [
                    "name": "tbd",
                    "title": "TBD",
                    "version": "1",
                ],
                "capabilities": ["experimentalApi": true],
            ],
        ])
    }

    static func initializedNotification() throws -> Data {
        try jsonLine([
            "jsonrpc": "2.0",
            "method": "initialized",
            "params": [:],
        ])
    }

    static func importRequest(
        transcriptPath: String,
        cwd: String,
        title: String?
    ) throws -> Data {
        var session: [String: Any] = [
            "path": transcriptPath,
            "cwd": cwd,
        ]
        if let title, !title.isEmpty {
            session["title"] = title
        }

        return try jsonLine([
            "jsonrpc": "2.0",
            "id": 2,
            "method": "externalAgentConfig/import",
            "params": [
                "migrationItems": [[
                    "itemType": "SESSIONS",
                    "description": "Continue one Claude session in Codex",
                    "details": ["sessions": [session]],
                ]],
                "source": "tbd",
            ],
        ])
    }

    private static func jsonLine(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }

    private static func object(from data: Data) throws -> [String: Any] {
        do {
            guard let object = try JSONSerialization.jsonObject(with: data)
                    as? [String: Any] else {
                throw CodexSessionImportError.malformedResponse(
                    "expected a JSON object")
            }
            return object
        } catch let error as CodexSessionImportError {
            throw error
        } catch {
            throw CodexSessionImportError.malformedResponse(
                "invalid JSON: \(error.localizedDescription)")
        }
    }

    private static func integerID(in object: [String: Any]) -> Int? {
        (object["id"] as? NSNumber)?.intValue
    }

    private static func errorMessage(in object: [String: Any]) -> String? {
        guard let error = object["error"] as? [String: Any] else { return nil }
        return error["message"] as? String ?? "Codex returned an unspecified error"
    }
}

struct ProcessCodexAppServerTransport: CodexAppServerTransport {
    func connect(executablePath: String, codexHome: URL) async throws
        -> any CodexAppServerConnection {
        try ProcessCodexAppServerConnection.start(
            executablePath: executablePath,
            codexHome: codexHome)
    }
}

private actor CodexAppServerLineInbox {
    private var lines: [Data] = []
    private var waiter: CheckedContinuation<Data, any Error>?
    private var terminalError: (any Error)?

    func yield(_ line: Data) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: line)
        } else {
            lines.append(line)
        }
    }

    func finish(_ error: any Error) {
        terminalError = error
        if let waiter {
            self.waiter = nil
            waiter.resume(throwing: error)
        }
    }

    func next() async throws -> Data {
        if !lines.isEmpty { return lines.removeFirst() }
        if let terminalError { throw terminalError }
        return try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
        }
    }
}

private final class ProcessCodexAppServerConnection: CodexAppServerConnection,
    @unchecked Sendable {
    private struct ReadState {
        var buffer = Data()
        var closed = false
    }

    private let process: Process
    private let stdinPipe: Pipe
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe
    private let inbox = CodexAppServerLineInbox()
    private let readState = OSAllocatedUnfairLock(initialState: ReadState())
    private let writeLock = NSLock()

    private init(
        process: Process,
        stdinPipe: Pipe,
        stdoutPipe: Pipe,
        stderrPipe: Pipe
    ) {
        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
    }

    static func start(executablePath: String, codexHome: URL) throws
        -> ProcessCodexAppServerConnection {
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let connection = ProcessCodexAppServerConnection(
            process: process,
            stdinPipe: stdinPipe,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe)

        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHome.path
        process.environment = environment

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak connection] handle in
            connection?.consume(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let message = String(data: data, encoding: .utf8) else { return }
            codexImportLogger.debug(
                "Codex app-server stderr: \(message, privacy: .private)")
        }
        process.terminationHandler = { [weak connection] process in
            connection?.finish(status: process.terminationStatus)
        }

        do {
            try process.run()
            return connection
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }
    }

    func send(_ line: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        try stdinPipe.fileHandleForWriting.write(contentsOf: line)
    }

    func receive() async throws -> Data {
        try await inbox.next()
    }

    func close() {
        let shouldClose = readState.withLock { state in
            guard !state.closed else { return false }
            state.closed = true
            return true
        }
        guard shouldClose else { return }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        try? stdinPipe.fileHandleForWriting.close()
        Task { await inbox.finish(CancellationError()) }
        if process.isRunning { process.terminate() }
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        let lines = readState.withLock { state -> [Data] in
            guard !state.closed else { return [] }
            state.buffer.append(data)
            var complete: [Data] = []
            while let newline = state.buffer.firstIndex(of: 0x0A) {
                let line = Data(state.buffer[..<newline])
                state.buffer.removeSubrange(...newline)
                if !line.isEmpty { complete.append(line) }
            }
            return complete
        }
        for line in lines {
            Task { await inbox.yield(line) }
        }
    }

    private func finish(status: Int32) {
        let wasClosed = readState.withLock { state -> Bool in
            let previous = state.closed
            state.closed = true
            return previous
        }
        guard !wasClosed else { return }
        Task { await inbox.finish(CodexSessionImportError.processExited(status)) }
    }
}
