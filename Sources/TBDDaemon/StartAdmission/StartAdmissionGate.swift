import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "start-admission")

/// Runs the user's start-admission command and reads its verdict.
///
/// TBD decides neither when the machine is full nor when a call is on; the
/// command does. The runner owns only the contract around it: where the file
/// lives, the environment it sees, the timeout brake, and what each way of
/// failing to answer means. A user who installed a gate wants it to hold when
/// it cannot decide, so every failure to answer is a hold.
///
/// Design: docs/specs/2026-10-21-agent-start-admission-design.md.
struct StartAdmissionGate: StartAdmissionEvaluating {
    /// The longest reason a hold carries.
    static let reasonLimit = 200
    static let defaultTimeout: Duration = .seconds(10)

    /// Resolves the command's path (through `TBD_HOME`) and is the base of the
    /// command's own environment.
    let environment: [String: String]
    let timeout: Duration
    let clock: any Clock<Duration>

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: Duration = StartAdmissionGate.defaultTimeout,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.environment = environment
        self.timeout = timeout
        self.clock = clock
    }

    var hookPath: String { TBDConstants.startAdmissionHookPath(environment: environment) }

    func evaluate(_ request: StartAdmissionRequest) async -> StartAdmissionVerdict {
        let path = hookPath
        guard FileManager.default.fileExists(atPath: path) else { return .admit }
        let verdict = await run(path, request)
        switch verdict {
        case .admit:
            logger.info("admitted \(request.kind.rawValue, privacy: .public) of \(request.agent.rawValue, privacy: .public) for actor \(request.actorKind, privacy: .public)")
        case .hold(let reason):
            logger.info("held \(request.kind.rawValue, privacy: .public) of \(request.agent.rawValue, privacy: .public) for actor \(request.actorKind, privacy: .public): \(reason, privacy: .private)")
        }
        return verdict
    }

    /// The variables added to the daemon's own environment.
    static func addedEnvironment(for request: StartAdmissionRequest) -> [String: String] {
        var added = [
            "TBD_START_KIND": request.kind.rawValue,
            "TBD_AGENT": request.agent.rawValue,
            "TBD_ACTOR": request.actorKind,
            "TBD_WORKTREE_ID": request.worktreeID.uuidString,
        ]
        if let terminalID = request.terminalID {
            added["TBD_TERMINAL_ID"] = terminalID.uuidString
        }
        return added
    }

    private func run(_ path: String, _ request: StartAdmissionRequest) async -> StartAdmissionVerdict {
        // The two coordinate variables describe this request only. A daemon
        // started from inside a TBD terminal carries its own in its
        // environment, and the command must not read those as the request's.
        var childEnvironment = environment
        childEnvironment.removeValue(forKey: "TBD_TERMINAL_ID")
        childEnvironment.merge(Self.addedEnvironment(for: request)) { _, added in added }

        let outcome: BoundedProcessOutcome
        do {
            outcome = try await runBoundedProcess(
                executable: path,
                arguments: [],
                currentDirectory: nil,
                environment: childEnvironment,
                timeout: timeout,
                clock: clock)
        } catch {
            return .hold(reason: "start-admission could not run: \(error.localizedDescription)")
        }
        switch outcome {
        case .completed(let status, let stdout, _):
            if status == 0 { return .admit }
            return .hold(reason: Self.reason(fromStdout: stdout) ?? "start-admission exited \(status)")
        case .signaled(let signal, _, _):
            return .hold(reason: "start-admission was killed by signal \(signal)")
        case .timedOut:
            return .hold(reason: "start-admission did not answer within \(Self.describe(timeout))")
        }
    }

    private static func describe(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        return seconds >= 1 ? "\(Int(seconds)) seconds" : "\(Int(seconds * 1000)) ms"
    }

    /// The first non-empty line of stdout, cut to `reasonLimit` characters.
    static func reason(fromStdout stdout: Data) -> String? {
        guard let text = String(bytes: stdout, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return String(trimmed.prefix(reasonLimit)) }
        }
        return nil
    }
}
