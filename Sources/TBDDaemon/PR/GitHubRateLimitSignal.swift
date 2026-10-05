import Foundation

/// What one `gh` response says about the GitHub GraphQL budget.
///
/// Every GitHub GraphQL query `PRStatusManager` builds selects
/// `rateLimit { cost remaining resetAt }` at the query root, so a successful
/// answer carries a reading. A response with no such field (`gh repo view`, a
/// non-JSON failure) parses to nil and says nothing about the budget.
public enum GitHubRateLimitSignal: Sendable, Equatable {
    case reading(cost: Int, remaining: Int, resetAt: Date)
    /// A rate-limit error. Carries no `rateLimit` field.
    case limited

    /// The GraphQL selection every GitHub query places at its root.
    static let selection = "rateLimit { cost remaining resetAt }"

    static func parse(_ result: GHCommandResult) -> GitHubRateLimitSignal? {
        if mentionsRateLimit(result.stderr) { return .limited }
        guard let data = result.stdout.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // Read stdout structurally, never as raw text: a successful answer
        // carries PR titles and branch names, and a PR titled "Handle
        // RATE_LIMITED" must not read as the budget running out.
        if let errors = root["errors"] as? [[String: Any]],
           errors.contains(where: { error in
               (error["type"] as? String) == "RATE_LIMITED"
                   || mentionsRateLimit(error["message"] as? String ?? "")
           }) {
            return .limited
        }
        guard let payload = root["data"] as? [String: Any],
              let rate = payload["rateLimit"] as? [String: Any],
              let cost = rate["cost"] as? Int,
              let remaining = rate["remaining"] as? Int,
              let resetRaw = rate["resetAt"] as? String,
              // A local formatter, not a shared static: ISO8601DateFormatter is
              // not Sendable, and this runs off the actor.
              let resetAt = ISO8601DateFormatter().date(from: resetRaw) else { return nil }
        return .reading(cost: cost, remaining: remaining, resetAt: resetAt)
    }

    /// GitHub's rate-limit wording, as `gh` prints it on stderr and as a
    /// GraphQL error message carries it.
    private static func mentionsRateLimit(_ text: String) -> Bool {
        text.contains("RATE_LIMITED") || text.localizedCaseInsensitiveContains("API rate limit exceeded")
    }
}
