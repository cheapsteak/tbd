import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "completions")

/// Answers "what can this session complete?" — the daemon side of
/// `terminal.completions`.
///
/// Three decisions sit between the RPC and the answer.
///
/// **Which binary to ask.** Claude Code updates itself in the background and a
/// running session keeps the old binary until it restarts; five versions sit side
/// by side on this machine and two ran at once with different command counts. So
/// the probe asks the executable the session *is running*, read from the process
/// table by the recorded child pid through the shared process-path helper, and
/// falls back silently to the daemon's normally resolved executable when the pid
/// is unknown, the child has not yet exec'd, or the versioned file is gone. The
/// fallback carries no marker: offering a command the running session lacks costs
/// one "unknown command" reply, which is tolerable, and a marker would add a
/// field to the RPC and a state to the UI for nothing.
///
/// **Whether to ask at all.** Results are cached per executable identity, profile
/// config directory and worktree path. The cache is stale when the modification
/// time changes on the settings file, on the commands, skills or agents
/// directories under the config directory or the worktree's `.claude`, or on the
/// two plugin manifests — a handful of `stat` calls. The probe runs only on a
/// cache miss, never on a timer and never on a keystroke.
///
/// **What to answer when the binary does not.** A failed or timed-out probe falls
/// back to the filesystem scan, marked `.fallback` / `.scan`. The app renders both
/// identically. A fallback is deliberately not cached: the next request tries the
/// binary again rather than serving a degraded list until something on disk
/// happens to change.
///
/// Two probe outcomes reach this type as `ProbeError.timedOut` and are worth
/// naming, because neither is a binary that refused to answer. A cancelled probe
/// surfaces that way — the bounded-process runner relays cancellation as a
/// timeout — and so does a child that emitted the answer but lingered past the
/// deadline, whose answer is dropped with it. Both land on the scan fallback,
/// which is the designed degradation rather than a case to special-case here.
///
/// Every probe runs inside `ClaudeConfigDirSerializer`, because the probe rewrites
/// `.claude.json` and `ClaudeTrustSeeder` does too.
actor CompletionInventoryService {

    /// Everything one request needs, resolved by the handler from the terminal's
    /// row and its worktree — so this type never touches the database.
    struct Request: Sendable, Equatable {
        let terminalID: UUID
        /// The holder transport's recorded child pid, when there is one.
        let childPID: Int32?
        /// The tmux pane's process id, when the handler could read one.
        let panePID: Int32?
        /// The profile's Claude config directory, which decides the answer as
        /// much as the binary does.
        let configDir: String
        let worktreePath: String
        /// The session's own spawn environment, unmodified.
        let environment: [String: String]
    }

    typealias Prober = @Sendable (String, String, [String: String]) async throws
        -> ClaudeCompletionProbe.Outcome
    typealias Scanner = @Sendable (String, String)
        -> (commands: [CompletionCommand], agents: [CompletionAgent])

    private struct CacheKey: Hashable {
        let executablePath: String
        let configDir: String
        let worktreePath: String
    }

    private struct CacheEntry {
        let fingerprint: String
        let result: TerminalCompletionsResult
    }

    private let probe: Prober
    private let scan: Scanner
    private let resolveExecutable: @Sendable () -> String?
    private let executablePathForPID: @Sendable (Int32) -> String?
    private let fingerprint: @Sendable (String, String) -> String
    private let serializer: ClaudeConfigDirSerializer
    private var cache: [CacheKey: CacheEntry] = [:]

    init(
        probe: @escaping Prober = { executablePath, cwd, environment in
            try await ClaudeCompletionProbe.run(
                executablePath: executablePath,
                workingDirectory: cwd,
                environment: environment)
        },
        scan: @escaping Scanner = { configDir, worktreePath in
            ClaudeCompletionScan.scan(configDir: configDir, worktreePath: worktreePath)
        },
        resolveExecutable: @escaping @Sendable () -> String? = {
            try? ClaudeExecutableResolver.resolve()
        },
        executablePathForPID: @escaping @Sendable (Int32) -> String? = { pid in
            ProcessLiveness.executablePath(pid: pid)
        },
        fingerprint: @escaping @Sendable (String, String) -> String
            = CompletionInventoryService.liveFingerprint,
        serializer: ClaudeConfigDirSerializer = .shared
    ) {
        self.probe = probe
        self.scan = scan
        self.resolveExecutable = resolveExecutable
        self.executablePathForPID = executablePathForPID
        self.fingerprint = fingerprint
        self.serializer = serializer
    }

    /// Which binary this request should ask. `nil` when nothing resolves, which
    /// is the one case with no probe to run at all.
    static func pinnedExecutable(
        childPID: Int32?,
        panePID: Int32?,
        executablePathForPID: (Int32) -> String?,
        fallback: () -> String?
    ) -> String? {
        for pid in [childPID, panePID].compactMap({ $0 }) where pid > 0 {
            if let path = executablePathForPID(pid), !path.isEmpty { return path }
        }
        return fallback()
    }

    func inventory(for request: Request) async -> TerminalCompletionsResult {
        guard let executablePath = Self.pinnedExecutable(
            childPID: request.childPID,
            panePID: request.panePID,
            executablePathForPID: executablePathForPID,
            fallback: resolveExecutable
        ) else {
            logger.debug("""
            completions: no claude executable resolves for terminal \
            \(request.terminalID.uuidString, privacy: .public) — scanning instead
            """)
            return fallbackResult(request)
        }

        let key = CacheKey(
            executablePath: executablePath,
            configDir: request.configDir,
            worktreePath: request.worktreePath)
        let stamp = fingerprint(request.configDir, request.worktreePath)
        if let entry = cache[key], entry.fingerprint == stamp {
            return TerminalCompletionsResult(
                commands: entry.result.commands,
                agents: entry.result.agents,
                freshness: .stale,
                source: entry.result.source)
        }

        do {
            // Bound as locals so the `@Sendable` body captures the seam and the
            // request's fields rather than the actor.
            let prober = probe
            let cwd = request.worktreePath
            let environment = request.environment
            let outcome = try await serializer.run(configDir: request.configDir) {
                try await prober(executablePath, cwd, environment)
            }
            let result = TerminalCompletionsResult(
                commands: outcome.commands, agents: outcome.agents,
                freshness: .fresh, source: .probe)
            cache[key] = CacheEntry(fingerprint: stamp, result: result)
            logger.debug("""
            completions: probed \(executablePath, privacy: .public) — \
            \(outcome.commands.count, privacy: .public) commands, \
            \(outcome.agents.count, privacy: .public) agents
            """)
            return result
        } catch {
            // `.timedOut` also covers a cancelled probe and one whose answer
            // arrived too late to keep; both degrade to the scan by design.
            logger.warning("""
            completions probe failed for terminal \
            \(request.terminalID.uuidString, privacy: .public) \
            (\(String(describing: error), privacy: .public)) — falling back to a scan
            """)
            // Deliberately NOT cached: the next request must try the binary again
            // rather than serve a degraded list until something on disk changes.
            return fallbackResult(request)
        }
    }

    private func fallbackResult(_ request: Request) -> TerminalCompletionsResult {
        let scanned = scan(request.configDir, request.worktreePath)
        return TerminalCompletionsResult(
            commands: scanned.commands, agents: scanned.agents,
            freshness: .fallback, source: .scan)
    }

    /// The staleness fingerprint: modification times of everything that decides
    /// the answer. A handful of `stat` calls, run once per request.
    ///
    /// A missing entry contributes a fixed marker rather than being skipped, so
    /// creating the first `commands/` directory is itself a change.
    static let liveFingerprint: @Sendable (String, String) -> String = { configDir, worktreePath in
        let config = URL(fileURLWithPath: configDir, isDirectory: true)
        let project = URL(fileURLWithPath: worktreePath, isDirectory: true)
            .appendingPathComponent(".claude", isDirectory: true)
        let paths: [URL] = [
            config.appendingPathComponent("settings.json"),
            config.appendingPathComponent("commands"),
            config.appendingPathComponent("skills"),
            config.appendingPathComponent("agents"),
            config.appendingPathComponent("plugins/installed_plugins.json"),
            config.appendingPathComponent("plugins/known_marketplaces.json"),
            project.appendingPathComponent("settings.json"),
            project.appendingPathComponent("commands"),
            project.appendingPathComponent("skills"),
            project.appendingPathComponent("agents"),
        ]
        let parts = paths.map { url -> String in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let modified = attrs[.modificationDate] as? Date
            else { return "-" }
            return String(modified.timeIntervalSince1970)
        }
        return parts.joined(separator: "|")
    }
}
