import Foundation
import os

/// Checks, once per route, that the session behind it runs in first-party
/// mode (spec `docs/specs/2026-09-21-model-proxy-tool-search-design.md`,
/// "The probe").
///
/// The daemon spawns a routed session with the override that keeps Claude Code
/// treating the proxy's base URL as the Anthropic API. Claude Code sends
/// `x-client-request-id` on a `/v1/messages` request only under the predicate
/// that override controls, so the header's absence on the route's first
/// messages request means the session is running degraded — tool search off,
/// among other things — and nothing else would say so.
///
/// The verdict reads the method, the URI and the header names the handler
/// already holds: never the body, never a header's value. The latch is the
/// only state, and a route's entry is dropped with the route.
actor FirstPartyProbe {
    /// What one request says about the override.
    enum Verdict: Equatable, Sendable {
        /// Not a messages request, so it says nothing either way.
        case notApplicable
        /// A messages request carrying the header.
        case honored
        /// A messages request without it.
        case notHonored
    }

    /// The header Claude Code adds only in first-party mode.
    static let headerName = "x-client-request-id"

    private static let log = Logger(subsystem: "com.tbd.modelproxy", category: "first-party")

    /// Tokens whose first messages request has been examined.
    private var examined: Set<String> = []

    /// The verdict for one request, as a pure function so it is testable
    /// without a logger or a server.
    ///
    /// Only a `POST` whose path, query stripped, ends in `/v1/messages`
    /// applies: `count_tokens`, the `HEAD /api/hello` warm-up and anything a
    /// future release calls on the base URL carry no promise about the header.
    /// Header names compare case-insensitively, as HTTP's do.
    static func verdict(method: String, uri: String, headerNames: [String]) -> Verdict {
        let path = uri.prefix(while: { $0 != "?" })
        guard method == "POST", path.hasSuffix("/v1/messages") else { return .notApplicable }
        let carries = headerNames.contains { $0.lowercased() == headerName }
        return carries ? .honored : .notHonored
    }

    /// Latches `token` on its first applicable request and logs once when that
    /// request did not carry the header.
    ///
    /// Returns whether this call was the one that examined the route, so the
    /// latch is observable without the log. The token is the route's bearer
    /// credential and is never logged; the terminal id is what a reader needs.
    @discardableResult
    func examine(token: String, terminalID: UUID, verdict: Verdict) -> Bool {
        guard verdict != .notApplicable, examined.insert(token).inserted else { return false }
        if verdict == .notHonored {
            Self.log.error(
                "terminal \(terminalID.uuidString, privacy: .public): first-party override not honored")
        }
        return true
    }

    /// Drops the latch for a route that is gone.
    func forget(token: String) {
        examined.remove(token)
    }
}
