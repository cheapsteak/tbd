import Foundation
import TBDShared
import os

enum CodexUsageParser {
    private struct AccountResponse: Decodable {
        let result: AccountResult?
        let error: AppServerError?
    }

    private struct AccountResult: Decodable {
        let account: CodexAccount?
    }

    private struct RateLimitsResponse: Decodable {
        let result: RateLimitsResult?
        let error: AppServerError?
    }

    private struct RateLimitsResult: Decodable {
        let rateLimits: CodexRateLimitSnapshot
        let rateLimitsByLimitId: [String: CodexRateLimitSnapshot]?
    }

    private struct AppServerError: Decodable {
        let message: String?
    }

    static func account(from data: Data) throws -> CodexAccount? {
        let response = try JSONDecoder().decode(AccountResponse.self, from: data)
        if let message = response.error?.message {
            throw CodexUsageFetchError.appServer(message)
        }
        return response.result?.account
    }

    static func rateLimits(from data: Data) throws -> [CodexRateLimitSnapshot] {
        let response = try JSONDecoder().decode(RateLimitsResponse.self, from: data)
        if let message = response.error?.message {
            throw CodexUsageFetchError.appServer(message)
        }
        guard let result = response.result else { return [] }
        if let buckets = result.rateLimitsByLimitId, !buckets.isEmpty {
            return buckets.keys.sorted().compactMap { buckets[$0] }
        }
        return [result.rateLimits]
    }
}

enum CodexUsageFetchError: Error {
    case appServer(String)
}

/// Runs a short-lived Codex app-server session and performs the documented
/// initialize → account/read → account/rateLimits/read exchange. The process
/// is bounded by both the daemon's starvation-resistant watchdog and an
/// injected clock, and is terminated immediately after the final response.
struct CodexUsageFetcher: Sendable {
    /// nil resolves the production CLI path with `CodexExecutableResolver`;
    /// tests can inject an exact executable and arguments.
    var executable: String?
    var arguments: [String]
    var timeout: Duration = .seconds(5)
    var clock: any Clock<Duration> = ContinuousClock()

    init(
        executable: String? = nil,
        arguments: [String] = ["app-server", "--stdio"],
        timeout: Duration = .seconds(5),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.executable = executable
        self.arguments = arguments
        self.timeout = timeout
        self.clock = clock
    }

    func fetch() async -> CodexUsageResult {
        guard let executable = executable ?? CodexExecutableResolver.resolveIfAvailable() else {
            return CodexUsageResult(unavailableReason: "Codex CLI unavailable")
        }
        let cancellation = CodexUsageCancellationRelay()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                let session = CodexUsageSession(
                    executable: executable,
                    arguments: arguments,
                    timeout: timeout,
                    clock: clock,
                    continuation: continuation
                )
                cancellation.register { session.cancel() }
                session.start()
            }
        }, onCancel: {
            cancellation.cancel()
        })
    }
}

private final class CodexUsageCancellationRelay: @unchecked Sendable {
    private struct State {
        var action: (@Sendable () -> Void)?
        var cancelled = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func register(_ action: @escaping @Sendable () -> Void) {
        let runNow = state.withLock { state -> Bool in
            if state.cancelled { return true }
            state.action = action
            return false
        }
        if runNow { action() }
    }

    func cancel() {
        let action = state.withLock { state -> (@Sendable () -> Void)? in
            guard !state.cancelled else { return nil }
            state.cancelled = true
            return state.action
        }
        action?()
    }
}

private final class CodexUsageSession: @unchecked Sendable {
    private struct State {
        var buffer = Data()
        var account: CodexAccount?
        var rateLimits: [CodexRateLimitSnapshot] = []
        var completedResult: CodexUsageResult?
        var finished = false
        var watchdogToken: UInt64?
        var clockTask: Task<Void, any Error>?
    }

    private let executable: String
    private let arguments: [String]
    private let timeout: Duration
    private let clock: any Clock<Duration>
    private let continuation: CheckedContinuation<CodexUsageResult, Never>
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        executable: String,
        arguments: [String],
        timeout: Duration,
        clock: any Clock<Duration>,
        continuation: CheckedContinuation<CodexUsageResult, Never>
    ) {
        self.executable = executable
        self.arguments = arguments
        self.timeout = timeout
        self.clock = clock
        self.continuation = continuation
    }

    func start() {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }
        // Drain stderr so a verbose/broken child cannot fill its pipe.
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        process.terminationHandler = { [weak self] process in
            self?.terminated(status: process.terminationStatus)
        }

        let token = SubprocessWatchdog.shared.schedule(after: timeout) { [weak self] in
            self?.timeOut()
        }
        state.withLock { $0.watchdogToken = token }
        let clockTask = Task { [weak self, clock, timeout] in
            try await clock.sleep(for: timeout)
            self?.timeOut()
        }
        state.withLock { $0.clockTask = clockTask }

        do {
            try process.run()
            try send(Self.initializeRequest)
        } catch {
            finish(CodexUsageResult(unavailableReason: "Codex CLI unavailable"))
        }
    }

    func cancel() {
        stopProcess()
        finish(CodexUsageResult(unavailableReason: "Usage unavailable"))
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        let lines = state.withLock { state -> [Data] in
            state.buffer.append(data)
            var lines: [Data] = []
            while let newline = state.buffer.firstIndex(of: 0x0A) {
                lines.append(state.buffer.prefix(upTo: newline))
                state.buffer.removeSubrange(...newline)
            }
            return lines
        }
        for line in lines {
            handle(line)
        }
    }

    private func handle(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let id = object["id"] as? Int else {
            return // notification or an unknown future message
        }
        do {
            switch id {
            case 1:
                try send(Self.initializedNotification)
                try send(Self.accountRequest)
            case 2:
                let account = try CodexUsageParser.account(from: line)
                state.withLock { $0.account = account }
                try send(Self.rateLimitsRequest)
            case 3:
                let rateLimits = try CodexUsageParser.rateLimits(from: line)
                let result = state.withLock { state -> CodexUsageResult in
                    state.rateLimits = rateLimits
                    let result = CodexUsageResult(account: state.account, rateLimits: rateLimits)
                    state.completedResult = result
                    return result
                }
                stopProcess()
                // Process termination normally reaps the child and finishes.
                // If it already exited between response and signal, finish now.
                if !process.isRunning { finish(result) }
            default:
                break
            }
        } catch {
            stopProcess()
            finish(CodexUsageResult(unavailableReason: "Usage unavailable"))
        }
    }

    private func send(_ data: Data) throws {
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    private func terminated(status: Int32) {
        let result = state.withLock { state -> CodexUsageResult in
            if let completed = state.completedResult { return completed }
            return CodexUsageResult(
                account: state.account,
                rateLimits: state.rateLimits,
                unavailableReason: status == 0 ? "Usage unavailable" : "Codex CLI unavailable"
            )
        }
        finish(result)
    }

    private func timeOut() {
        stopProcess()
        finish(CodexUsageResult(unavailableReason: "Usage timed out"))
    }

    private func stopProcess() {
        stdinPipe.fileHandleForWriting.closeFile()
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        if pid > 0 {
            kill(pid, SIGTERM)
            SubprocessWatchdog.shared.schedule(after: .milliseconds(500)) { [weak process] in
                if process?.isRunning == true { kill(pid, SIGKILL) }
            }
        }
    }

    private func finish(_ result: CodexUsageResult) {
        let pending = state.withLock { state -> (Bool, UInt64?, Task<Void, any Error>?) in
            guard !state.finished else { return (false, nil, nil) }
            state.finished = true
            return (true, state.watchdogToken, state.clockTask)
        }
        guard pending.0 else { return }
        if let token = pending.1 { SubprocessWatchdog.shared.cancel(token) }
        pending.2?.cancel()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        continuation.resume(returning: result)
    }

    private static let initializeRequest = line([
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": [
            "clientInfo": ["name": "tbd", "title": "TBD", "version": "1"],
            "capabilities": [:],
        ],
    ])
    private static let initializedNotification = line([
        "jsonrpc": "2.0", "method": "initialized", "params": [:],
    ])
    private static let accountRequest = line([
        "jsonrpc": "2.0", "id": 2, "method": "account/read",
        "params": ["refreshToken": false],
    ])
    private static let rateLimitsRequest = line([
        "jsonrpc": "2.0", "id": 3, "method": "account/rateLimits/read", "params": [:],
    ])

    private static func line(_ object: [String: Any]) -> Data {
        var data = try! JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        return data
    }
}
