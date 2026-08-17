import Foundation
import TBDShared

extension ClaudeCloudInvoker {
    /// A pending create a complete view could not confirm this long after the
    /// invocation is a create that failed. There is no discovery to confirm
    /// it AGAINST here, so the window alone decides — and the row is retained
    /// either way, so the judgement costs nothing but a state label.
    static let pendingFailureWindow: TimeInterval = 600

    /// `list` returns the `claude_cloud_session` ledger — what this machine
    /// started — and nothing else. It is always `complete: false`.
    ///
    /// **There is no discovery, and adding one is not the fix.** No supported
    /// interface enumerates an account's cloud sessions: the Compliance API's
    /// remote-session endpoints exclude Claude Code on the web by name, the
    /// documented `/v1/claude_code/` namespace grants no read access, and the
    /// undocumented claude.ai endpoints are barred by Anthropic's Consumer
    /// Terms outside the API-key carve-out — which a subscription-login cloud
    /// session can never be inside. Driving them would put TBD's users outside
    /// the terms of the account they are signed into, for a feature they can
    /// already reach in a browser. That is a design constraint, not a gap
    /// awaiting an implementation. What would reopen it is a supported
    /// interface, not a smaller or more careful scraper.
    ///
    /// The permanent incompleteness is what makes that safe rather than
    /// merely honest: a caller may adopt and update on an incomplete
    /// snapshot but must never retire on one, so a provider that never claims
    /// completeness cannot cause a false retirement however partial its view.
    /// A cloud lane leaves the working set by the user archiving it.
    func list() async throws -> ProviderResult {
        let rows = try await db.claudeCloudSessions.rows()
        let at = now()

        // Bookkeeping first, so this snapshot reflects it.
        let expired = rows.filter {
            $0.state == ClaudeCloudLedgerState.pending.rawValue
                && at.timeIntervalSince($0.createdAt) > Self.pendingFailureWindow
        }.map(\.id)
        try await db.claudeCloudSessions.markFailed(ids: expired)

        // Only a row that names a session can be listed; `pending` and
        // `failed` rows name none. Archived rows STAY enumerated, with their
        // flag set — that is what the contract requires, and filtering them
        // would drive the session toward `gone`.
        let sessions = rows.compactMap { row -> [String: Any]? in
            guard let sessionID = row.sessionID,
                  row.state == ClaudeCloudLedgerState.resolved.rawValue
            else { return nil }
            var meta = ["repo": row.repoKey]
            if let branch = row.branch, !branch.isEmpty { meta["branch"] = branch }
            // `create` includes `environment` in the `meta` it returns; this
            // was the one field `list` dropped on the very next poll, so a
            // value that had round-tripped safely through the database
            // vanished from every caller permanently — there is no
            // discovery to re-supply it later.
            if let environment = row.environment, !environment.isEmpty {
                meta["environment"] = environment
            }
            return ClaudeCloudSessionProjection.payload(
                sessionID: sessionID, title: row.title, createdAt: row.createdAt,
                archived: row.archived, meta: meta)
        }
        let envelope: [String: Any] = ["complete": false, "sessions": sessions]
        return ProviderResult(
            exitCode: 0,
            stdout: (try? JSONSerialization.data(withJSONObject: envelope))
                ?? Data(#"{"complete":false,"sessions":[]}"#.utf8),
            stderr: "")
    }
}
