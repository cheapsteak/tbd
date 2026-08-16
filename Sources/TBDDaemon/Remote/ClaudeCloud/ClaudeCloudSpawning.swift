import Foundation

/// One invocation of the vendor `claude` CLI, as a value.
struct ClaudeCloudSpawnRequest: Sendable, Equatable {
    /// Arguments after the executable. Never a shell string — the CLI is
    /// executed directly, so nothing here is shell-escaped or re-parsed.
    let arguments: [String]
    let workingDirectory: String
    /// `create` alone. The CLI refuses `--cloud` creation when stdout is not
    /// a terminal, by design and loudly, so the obvious pipe implementation
    /// does not degrade — it never works. Everything else must stay on pipes:
    /// a pty is ONE descriptor, so stdout and stderr merge on it.
    let usesPseudoTerminal: Bool
    let timeout: TimeInterval
}

enum ClaudeCloudSpawnOutcome: Sendable, Equatable {
    /// `output` is the captured stdout, plus stderr when the two merged on a
    /// pseudo-terminal. Decoded lossily so ANSI bytes survive to the parser's
    /// strip step rather than failing the decode.
    case completed(status: Int32, output: String)
    case timedOut
}

/// The seam every vendor invocation goes through, so no test reaches a real
/// `claude` binary, a network, or a credential store.
protocol ClaudeCloudSpawning: Sendable {
    func spawn(_ request: ClaudeCloudSpawnRequest) async throws -> ClaudeCloudSpawnOutcome
}

/// Production conformance over the same bounded runner every other daemon
/// spawn uses — watchdog-backed deadline, incremental draining, single-resume
/// guard — rather than a second engine whose deadline discipline could rot.
struct BoundedProcessClaudeSpawner: ClaudeCloudSpawning {
    let executable: String

    init(executable: String) { self.executable = executable }

    /// The environment one invocation runs under. Pure and static so the
    /// pinned geometry is assertable without a spawn.
    ///
    /// `runBoundedProcess` REPLACES the child's environment wholesale, so this
    /// starts from the caller's full login environment and overrides. Under a
    /// pseudo-terminal the geometry is pinned to the runner's own 400x200:
    /// `winsize` is advisory and the kernel wraps nothing, but a child that
    /// ASKS formats to it and inserts REAL newlines at the wrap, which would
    /// land in the captured bytes and split the line the create parse reads.
    static func invocationEnvironment(
        base: [String: String], usesPseudoTerminal: Bool
    ) -> [String: String] {
        guard usesPseudoTerminal else { return base }
        var env = base
        env["TERM"] = "xterm-256color"
        env["COLUMNS"] = "400"
        env["LINES"] = "200"
        return env
    }

    func spawn(_ request: ClaudeCloudSpawnRequest) async throws -> ClaudeCloudSpawnOutcome {
        let outcome = try await runBoundedProcess(
            executable: executable,
            arguments: request.arguments,
            currentDirectory: request.workingDirectory,
            environment: Self.invocationEnvironment(
                base: ProcessInfo.processInfo.environment,
                usesPseudoTerminal: request.usesPseudoTerminal),
            // None, ever: under `.pseudoTerminal` the replica is the child's
            // stdin AND stdout on one descriptor, so a payload is refused
            // outright, and neither verb here has anything to write.
            stdin: nil,
            timeout: .seconds(request.timeout),
            stdio: request.usesPseudoTerminal ? .pseudoTerminal : .pipes)
        switch outcome {
        case .timedOut:
            return .timedOut
        case let .completed(status, stdoutData, stderrData):
            // Under a pty `stderrData` is always empty (the streams merged);
            // under pipes it carries the CLI's diagnostics, which belong in
            // the message a failing verb reports.
            // swiftlint:disable:next optional_data_string_conversion
            let stdout = String(decoding: stdoutData, as: UTF8.self)
            // swiftlint:disable:next optional_data_string_conversion
            let stderr = String(decoding: stderrData, as: UTF8.self)
            return .completed(status: status, output: stdout + stderr)
        }
    }
}
