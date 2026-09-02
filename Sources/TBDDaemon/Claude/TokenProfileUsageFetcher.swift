import Foundation
import os
import TBDShared

private let tokenProbeLogger = Logger(subsystem: "com.tbd.daemon", category: "tokenUsageProbe")

// MARK: - Header parsing

/// Parses the `anthropic-ratelimit-unified-*` response headers a
/// `max_tokens: 0` probe returns into the same bucket shape the OAuth usage
/// endpoint produces. Pure and separately testable — no networking, which is
/// the point: the header math is the part worth testing exhaustively.
///
/// Headers carry no per-model breakdown, so this never emits a
/// `weekly_scoped` bucket. A token profile therefore renders two bars where a
/// signed-in profile renders three or more. `UsageBarsView` draws the 5-hour
/// and weekly bars from optional lookups and then loops over the scoped
/// buckets, so an empty scoped set simply contributes no rows.
public enum TokenUsageHeaderParser {

    /// Bucket `kind` values, matching what `/api/oauth/usage` names them so
    /// every downstream consumer treats a token profile's buckets identically.
    static let sessionKind = "session"
    static let weeklyAllKind = "weekly_all"

    public static func buckets(from headers: [String: String]) -> [ClaudeUsageLimitBucket] {
        [
            bucket(from: headers, window: "5h", kind: sessionKind, group: "session"),
            bucket(from: headers, window: "7d", kind: weeklyAllKind, group: "weekly"),
        ].compactMap { $0 }
    }

    private static func bucket(from headers: [String: String],
                               window: String,
                               kind: String,
                               group: String) -> ClaudeUsageLimitBucket? {
        let prefix = "anthropic-ratelimit-unified-\(window)"
        // A window with no parsable utilization contributes NOTHING. Emitting
        // a 0% bar would read as "plenty of headroom" for a window we simply
        // could not measure — a wrong answer, not a conservative one.
        guard let raw = value(headers, "\(prefix)-utilization"),
              let utilization = Double(raw) else { return nil }

        let resetsAt = value(headers, "\(prefix)-reset")
            .flatMap(Double.init)
            .map { Date(timeIntervalSince1970: $0) }

        return ClaudeUsageLimitBucket(
            kind: kind,
            group: group,
            // The header is a 0–1 fraction; `percent` is a 0–100 scale.
            percent: utilization * 100,
            severity: severity(for: value(headers, "\(prefix)-status")),
            resetsAt: resetsAt,
            modelDisplayName: nil,
            isActive: nil
        )
    }

    /// HTTP header names are case-insensitive; a dictionary lookup is not.
    /// The exact-key hit is tried first so the common case stays O(1).
    private static func value(_ headers: [String: String], _ name: String) -> String? {
        if let direct = headers[name] { return direct }
        let lowered = name.lowercased()
        return headers.first { $0.key.lowercased() == lowered }?.value
    }

    /// Maps the window's `-status` header onto the severity vocabulary the
    /// usage endpoint uses. Any status that is neither `allowed` nor
    /// `allowed_warning` is a rejected state, which is `critical`; an absent
    /// header yields nil rather than a guess.
    private static func severity(for status: String?) -> String? {
        switch status {
        case "allowed": return "normal"
        case "allowed_warning": return "warning"
        case .some: return "critical"
        case nil: return nil
        }
    }
}

// MARK: - Probe fetcher

/// Reads subscription usage for a `claude setup-token` profile.
///
/// Setup tokens 403 on `/api/oauth/usage` and `/api/oauth/profile` — they lack
/// the `user:profile` scope — so utilization cannot be read the way a
/// signed-in profile's is. The mechanism instead is a `max_tokens: 0` POST to
/// `/v1/messages`, which returns 200, bills roughly eight input tokens and no
/// output tokens, and carries utilization in its response headers.
///
/// This costs a real (if tiny) billed request, which is why
/// `OAuthProfileUsagePoller` gates it on session activity rather than sweeping
/// it on the 90-second cadence.
public struct TokenProfileUsageFetcher: ProfileUsageFetching {
    /// The cheapest model to address the probe at. It is never asked to
    /// generate anything (`max_tokens: 0`), so the choice only has to be a
    /// model the account may call.
    public static let probeModel = "claude-haiku-4-5-20251001"

    /// The Anthropic API version the probe pins, sent as `anthropic-version`.
    ///
    /// The header is **required** on `/v1/messages`. Omitting it returns
    /// `HTTP 400 {"error":{"message":"anthropic-version: header is required"}}`
    /// with none of the `anthropic-ratelimit-unified-*` headers the probe
    /// exists to read, so every token profile reports a failure and renders no
    /// usage bars at all.
    public static let apiVersion = "2023-06-01"

    private let session: URLSession
    private let endpoint: URL

    public init(session: URLSession = .shared,
                endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!) {
        self.session = session
        self.endpoint = endpoint
    }

    public func fetchUsage(credential: ProfileUsageCredential) async -> ProfileUsageFetchStatus {
        // A `.configDir` credential belongs to `LiveProfileUsageFetcher`. An
        // empty token is the "secret file removed out from under the profile"
        // case, which is `.noCredentials`, not a rejected token.
        guard case .token(let token) = credential, !token.isEmpty else {
            return .noCredentials("token profile has no stored token")
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // max_tokens: 0 makes this the cheapest possible real request: it
        // returns 200 with the rate-limit headers and generates no output.
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": Self.probeModel,
            "max_tokens": 0,
            "messages": [["role": "user", "content": "."]],
        ])

        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            // The token is in the request, never in the error: URLError's
            // description names the URL and the failure, not the headers.
            return .networkError(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            return .networkError("non-HTTP response")
        }

        switch http.statusCode {
        case 200:
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let key = key as? String, let value = value as? String {
                    headers[key] = value
                }
            }
            let organizationID = headers
                .first { $0.key.lowercased() == "anthropic-organization-id" }
                .map(\.value)
                .flatMap { $0.isEmpty ? nil : $0 }
            let buckets = TokenUsageHeaderParser.buckets(from: headers)
            tokenProbeLogger.debug(
                "token usage probe ok: \(buckets.count, privacy: .public) buckets, org \(organizationID ?? "none", privacy: .public)")
            return .ok(buckets, organizationID: organizationID)
        case 401, 403:
            // The token was rejected. Reuses `.needsLogin` deliberately: the
            // state is the same shape (supply a new credential), and widening
            // `ProfileUsageStatusKind` would break snapshot decode on older
            // apps, because `decodeIfPresent` THROWS on an unrecognised raw
            // value rather than returning nil. The reason carries the status
            // code only — never token bytes.
            return .needsLogin("token rejected (HTTP \(http.statusCode))")
        case 429:
            let retryAfter = http
                .value(forHTTPHeaderField: "Retry-After")
                .flatMap(TimeInterval.init)
            return .rateLimited(retryAfter: retryAfter)
        default:
            // A 4xx outside `retryableClientErrorCodes` is a defect in the
            // request TBD sent — a missing required header, an unknown field —
            // not a transport hiccup. `.networkError` promises "transient,
            // will clear on its own", so reporting one here both misclassifies
            // the failure and gives the UI wording that misleads. `.httpError`
            // (kind `.unknown`) is the existing case for it; no
            // `ProfileUsageStatusKind` case is added, because that enum
            // decodes with `decodeIfPresent`, which THROWS on an unrecognised
            // raw value and would break snapshot decode on older apps.
            //
            // A RETRYABLE 4xx does stay `.networkError`, and correctly so: 408
            // Request Timeout and 425 Too Early both invite the identical
            // request again (401/403/429 are handled above, each with its own
            // case). 5xx stays `.networkError` too: the server may well
            // recover, and a retry is exactly the right response.
            if ProfileUsageFetchStatus.isPermanentRequestError(http.statusCode) {
                tokenProbeLogger.error(
                    "token usage probe request rejected: HTTP \(http.statusCode, privacy: .public) — the probe request itself is malformed; retrying cannot fix it")
                return .httpError(http.statusCode)
            }
            return .networkError("HTTP \(http.statusCode)")
        }
    }
}
