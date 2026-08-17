import Foundation
import TBDShared

extension ClaudeCloudInvoker {
    /// `create` runs `claude --cloud "<prompt>"` from the repository
    /// checkout, on a pseudo-terminal, and reads the session id and its title
    /// out of what it prints.
    ///
    /// **The ledger row is written BEFORE the invocation**, so a create whose
    /// output could not be read leaves a `pending` row rather than nothing,
    /// carrying the repository, the branch and the prompt that were
    /// submitted. That row is what keeps an unreadable answer from being
    /// silent: it names what was asked for, and with no discovery to match it
    /// against, it is what the user is shown.
    func create(stdin: Data?, timeout: TimeInterval) async throws -> ProviderResult {
        guard let stdin,
              let body = try? JSONSerialization.jsonObject(with: stdin) as? [String: Any]
        else {
            return Self.errorResult(
                exitCode: 2, code: "invalid_params",
                message: "create requires a JSON object on stdin")
        }
        let params = body["params"] as? [String: Any] ?? [:]
        let idempotencyKey = (body["idempotency_key"] as? String) ?? UUID().uuidString
        let prompt = ((params["prompt"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            return Self.errorResult(
                exitCode: 2, code: "invalid_params",
                message: "create requires a non-empty `prompt`")
        }
        let repoKey = ((params["repo"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = (params["branch"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let environment = (params["environment"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        // The checkout `claude --cloud` runs from. Resolved through the same
        // normalization the mirror uses for `meta["repo"]`, so a session
        // created here round-trips into the repository its `+` was clicked
        // from instead of landing unmatched.
        let repos = try await db.repos.list()
        guard let repoID = RemoteRepoMatching.resolveRepoID(metaRepo: repoKey, repos: repos),
              let repo = try await db.repos.get(id: repoID)
        else {
            return Self.errorResult(
                exitCode: 1, code: "not_found",
                message: "no repository registered in TBD matches '\(repoKey)'")
        }

        let paramsJSON = String(
            data: (try? JSONSerialization.data(withJSONObject: params)) ?? Data("{}".utf8),
            encoding: .utf8) ?? "{}"
        let row = try await db.claudeCloudSessions.upsertPending(
            idempotencyKey: idempotencyKey, repoKey: repoKey, repoPath: repo.path,
            branch: branch, environment: environment, paramsJSON: paramsJSON, now: now())

        // The measured CLI surface (design §11) takes the description and
        // nothing else — no branch flag, no environment flag. Both are
        // recorded on the ledger row and reported as `meta`; inventing a flag
        // would be a guess about a surface this design is written to.
        let request = ClaudeCloudSpawnRequest(
            arguments: ["--cloud", prompt],
            workingDirectory: repo.path,
            usesPseudoTerminal: true,
            timeout: timeout)
        let outcome = try await spawner.spawn(request)
        switch outcome {
        case .timedOut:
            // Thrown, not synthesized: the handler's single same-key retry is
            // armed by `ProviderRunError`, and the pending row above is what
            // makes that retry safe.
            throw ProviderRunError.timeout(verb: "create")
        // `create` runs on a pty, so the two streams already merged into
        // `output`; the separate pipe-mode `stderr` field is always empty
        // here and unused.
        case let .completed(status, output, _):
            guard status == 0 else {
                return Self.errorResult(
                    exitCode: 1, code: "unreachable",
                    message: "claude --cloud exited \(status): "
                        + ClaudeCloudCreateOutputParser.failureMessage(
                            .noSessionID, received: output))
            }
            switch ClaudeCloudCreateOutputParser.sessionID(fromOutput: output) {
            case .failure(let failure):
                // `contractBug` is the honest class: the built-in provider
                // could not satisfy the contract, and the remedy is a fix to
                // TBD rather than a retry or a re-authentication.
                let message = ClaudeCloudCreateOutputParser.failureMessage(
                    failure, received: output)
                claudeCloudLogger.error(
                    "claude-cloud create could not read a session id: \(message, privacy: .public)")
                return Self.errorResult(exitCode: 2, code: "contract_bug", message: message)
            case .success(let sessionID):
                // Lenient by design: a missing title costs friendliness, not
                // the lane, so it never fails a create that succeeded.
                let title = ClaudeCloudCreateOutputParser.title(fromOutput: output)
                let resolvedAt = now()
                try await db.claudeCloudSessions.resolve(
                    id: row.id, sessionID: sessionID, title: title, now: resolvedAt)
                var meta = ["repo": repoKey]
                if let branch { meta["branch"] = branch }
                if let environment { meta["environment"] = environment }
                let payload = ClaudeCloudSessionProjection.payload(
                    sessionID: sessionID, title: title, createdAt: row.createdAt,
                    archived: false, meta: meta)
                return ProviderResult(
                    exitCode: 0,
                    stdout: (try? JSONSerialization.data(withJSONObject: payload)) ?? Data(),
                    stderr: "")
            }
        }
    }
}

/// The one place a ledger row becomes a contract Session object, shared by
/// `create` and `list` so the two can never describe the same session
/// differently.
enum ClaudeCloudSessionProjection {
    static func payload(
        sessionID: String, title: String?, createdAt: Date, archived: Bool,
        meta: [String: String]
    ) -> [String: Any] {
        var object: [String: Any] = [
            "id": sessionID,
            "created_at": ISO8601DateFormatter().string(from: createdAt),
            // The ledger knows a session was created; it does not know
            // whether it lives. The contract is explicit that `unknown` means
            // only that no machine-readable state is available — never
            // healthy, idle, or finished.
            "state": "unknown",
            "agent_state": "unknown",
            // ALWAYS explicit, including `false`. The wire field is
            // three-valued — absent means "no claim made" and moves no row —
            // so omitting it when a session is unarchived would mean TBD never
            // observes the `false` transition, and unarchiving through this
            // ledger would not return the row to the active list.
            "archived": archived,
            "meta": meta,
        ]
        if let title { object["title"] = title }
        return object
    }
}
