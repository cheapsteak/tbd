import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "completions.probe")

/// Asks a Claude Code binary what commands, skills and subagents it knows.
///
/// Claude Code has no flag that prints its commands, and only the running program
/// knows its built-ins. Its headless mode does answer one control-protocol
/// request, `initialize`, with every command's name, description, argument hint
/// and aliases, plus every subagent, in one flat list covering built-ins, user
/// and project commands, skills, and plugin items namespaced `plugin:name`.
///
/// So the probe starts the binary in print mode with stream-json in and out,
/// writes one `initialize` request, reads the one response line, closes stdin and
/// waits. Measured on 2.1.261 against a real logged-in profile: about half a
/// second wall time, 209 commands, zero tokens, and no credentials required.
/// Project trust does not gate it — a project with no trust record, one with
/// trust recorded, and an empty config directory all returned the project's
/// commands, skills and agents identically.
///
/// **Every flag on the command line closes a measured side effect.** Removing one
/// reintroduces its effect silently, which is why `arguments(mcpConfigPath:)` is
/// pure and asserted rather than assembled inline:
///
/// - Without `disableAllHooks`, every `SessionStart` and `SessionEnd` hook in the
///   profile, the project and enabled plugins runs on every probe, and each probe
///   leaves an empty `session-env/<uuid>/` directory behind. Merging hook arrays
///   through the overlay does not suppress them, no environment variable does,
///   and bare mode does but drops every user skill and plugin command.
/// - Without `disableClaudeAiConnectors`, a probe in OAuth mode sends an
///   authenticated request to the Anthropic API host to list cloud connectors,
///   and the nonessential-traffic switch does not stop it.
/// - Without the strict empty MCP configuration, the profile's real MCP servers
///   start: measured leaking orphaned processes and writing logs into the
///   person's Library folder.
///
/// The environment is the session's own spawn environment, unmodified. The probe
/// adds no credentials of its own: adding an API key to an OAuth profile's
/// environment changes the auth path and loses three subscription-gated commands.
/// A profile whose own environment carries a key or an endpoint keeps it, because
/// that is the environment the session runs in.
///
/// **Not read-only against `.claude.json`.** In a fresh config directory it writes
/// first-run metadata and a backup file; against an existing project entry it
/// rewrote the entry, keeping the trust key and dropping an onboarding key. Every
/// caller must therefore run it through `ClaudeConfigDirSerializer`, which is
/// where it is ordered against `ClaudeTrustSeeder`.
///
/// **Reconciler note.** This spawns a process and writes one temporary file. Both
/// are reclaimed by the call itself — the process by `runBoundedProcess`, whose
/// deadline signals the child and escalates SIGTERM to SIGKILL on its own
/// watchdog thread, the file by the `defer` in `run`. Neither can accumulate:
/// nothing here outlives the request, so no sweep covers it and none is needed.
enum ClaudeCompletionProbe {

    /// The settings overlay passed with `--settings`. Two switches, each closing
    /// a measured side effect; see the type doc comment.
    static let settingsOverlay = #"{"disableAllHooks":true,"disableClaudeAiConnectors":true}"#

    /// The MCP configuration written to a temp file and passed with
    /// `--mcp-config`, alongside `--strict-mcp-config` so the profile's own
    /// servers are not merged in.
    static let emptyMCPConfig = #"{"mcpServers":{}}"#

    /// The single line written to stdin, newline-terminated, before stdin closes.
    static let initializeRequestLine =
        #"{"type":"control_request","request_id":"r1","request":{"subtype":"initialize"}}"# + "\n"

    /// The request id the response must echo.
    static let requestID = "r1"

    /// The argv, minus argv[0]. Pure so the measured command line is a test
    /// expectation rather than a comment.
    static func arguments(mcpConfigPath: String) -> [String] {
        [
            "-p",
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--verbose",
            "--strict-mcp-config",
            "--mcp-config", mcpConfigPath,
            "--settings", settingsOverlay,
        ]
    }

    struct Outcome: Sendable, Equatable {
        let commands: [CompletionCommand]
        let agents: [CompletionAgent]
    }

    enum ProbeError: Error, Equatable, LocalizedError {
        /// The binary did not answer within the deadline; it was killed.
        case timedOut
        /// The binary exited without a usable `initialize` response.
        case noResponse
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .timedOut:
                return "the completions probe did not answer within its deadline and was killed"
            case .noResponse:
                return "the completions probe exited without an initialize response"
            case .launchFailed(let detail):
                return "the completions probe could not be launched: \(detail)"
            }
        }
    }

    /// Parse one `control_response` line into an inventory.
    ///
    /// Deliberately hand-rolled over `JSONSerialization` rather than a nest of
    /// `Decodable` wrappers: the envelope carries a dozen keys this build does not
    /// model and a newer Claude Code will add more, and every one of them must be
    /// ignored rather than fail the decode. nil means "this line is not the
    /// answer" — a hook event, a system frame, the init frame, or garbage.
    ///
    /// The init frame is explicitly not the answer: it appears only after a real,
    /// billed message, omits about twenty interactive-only commands, and carries
    /// no descriptions.
    static func decode(
        responseLine: Data
    ) -> (commands: [CompletionCommand], agents: [CompletionAgent])? {
        guard !responseLine.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: responseLine),
              let object = root as? [String: Any],
              object["type"] as? String == "control_response",
              let response = object["response"] as? [String: Any],
              response["subtype"] as? String == "success",
              response["request_id"] as? String == requestID,
              let payload = response["response"] as? [String: Any]
        else { return nil }

        let rawCommands = payload["commands"] as? [[String: Any]] ?? []
        let commands = rawCommands.compactMap { entry -> CompletionCommand? in
            guard let name = entry["name"] as? String, !name.isEmpty else { return nil }
            let hint = entry["argumentHint"] as? String
            return CompletionCommand(
                name: name,
                description: entry["description"] as? String ?? "",
                // An empty hint is the same as none: it renders as a placeholder
                // and an empty placeholder is a blank box after the token.
                argumentHint: (hint?.isEmpty ?? true) ? nil : hint,
                aliases: entry["aliases"] as? [String] ?? [])
        }
        let rawAgents = payload["agents"] as? [[String: Any]] ?? []
        let agents = rawAgents.compactMap { entry -> CompletionAgent? in
            guard let name = entry["name"] as? String, !name.isEmpty else { return nil }
            return CompletionAgent(
                name: name, description: entry["description"] as? String ?? "")
        }
        return (commands, agents)
    }

    /// Run one probe. Throws `.timedOut` when the binary does not answer inside
    /// `timeout`, having killed it first.
    ///
    /// The spawn, the one-shot stdin payload, the incremental drain of both
    /// output pipes and the deadline all belong to `runBoundedProcess`, the
    /// runner `GitManager`, `TmuxManager` and `ProviderRunner` already share.
    /// Re-implementing them here would re-acquire, one at a time, the failures
    /// that file documents: a reader parked on a GCD worker while the pool is
    /// saturated by a parallel test run, an undrained stderr deadlocking a
    /// chatty child against a full pipe buffer, a SIGTERM a wedged child is free
    /// to ignore, and a deadline that cannot fire until the read it is supposed
    /// to interrupt returns on its own.
    ///
    /// The deadline is expressed duration-relative and the injected `clock` is
    /// passed straight through, which is the shape `Tests/CLAUDE.md` prescribes:
    /// the existential clock pins `Duration`, not `Instant`, so "sleep until Y"
    /// does not compile and "time out after X" is directly advanceable on a test
    /// clock.
    static func run(
        executablePath: String,
        workingDirectory: String,
        environment: [String: String],
        timeout: Duration = .seconds(5),
        clock: any Clock<Duration> = ContinuousClock()
    ) async throws -> Outcome {
        let mcpPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-probe-mcp-\(UUID().uuidString).json")
        try? Data(emptyMCPConfig.utf8).write(to: mcpPath)
        defer { try? FileManager.default.removeItem(at: mcpPath) }

        let result: BoundedProcessOutcome
        do {
            result = try await runBoundedProcess(
                executable: executablePath,
                arguments: arguments(mcpConfigPath: mcpPath.path),
                currentDirectory: workingDirectory,
                environment: environment,
                stdin: Data(initializeRequestLine.utf8),
                timeout: timeout,
                clock: clock)
        } catch {
            // `runBoundedProcess` throws only what `Process.run()` threw; every
            // other outcome, cancellation included, comes back as `.timedOut`.
            throw ProbeError.launchFailed(error.localizedDescription)
        }

        guard case .completed(_, let stdout, let stderr) = result else {
            logger.warning("""
            completions probe timed out after \(String(describing: timeout), privacy: .public) \
            and was killed: \(executablePath, privacy: .public)
            """)
            throw ProbeError.timedOut
        }

        // The binary emits one JSON object per line and may print system frames
        // ahead of the answer. Take the first line that IS the answer.
        for line in stdout.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let decoded = decode(responseLine: Data(line)) {
                return Outcome(commands: decoded.commands, agents: decoded.agents)
            }
        }
        logger.debug("""
        completions probe produced no initialize response: \(executablePath, privacy: .public) \
        stderr=\(String(bytes: stderr.prefix(512), encoding: .utf8) ?? "", privacy: .public)
        """)
        throw ProbeError.noResponse
    }
}
