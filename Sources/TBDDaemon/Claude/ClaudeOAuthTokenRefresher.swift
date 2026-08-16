import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "oauthTokenRefresh")

// MARK: - Parsed credential blob

/// The subset of a Claude Code credentials blob the daemon needs to reason
/// about token freshness and drive a refresh. The raw JSON is preserved as
/// `rawObject` so a refresh can write the file back byte-compatibly (only the
/// four rotating fields under `claudeAiOauth` change).
public struct ClaudeOAuthCredentials: Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    /// Unix epoch milliseconds (Claude Code stores `expiresAt` in ms).
    public var expiresAtMillis: Double?
    public var scopes: [String]

    public init(accessToken: String, refreshToken: String?,
                expiresAtMillis: Double?, scopes: [String]) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAtMillis = expiresAtMillis
        self.scopes = scopes
    }

    /// True when `expiresAtMillis` is in the past (with a small skew margin so
    /// we refresh slightly ahead of the hard boundary). nil expiry → never
    /// considered expired (we let the server be the judge).
    public func isExpired(now: Date, skew: TimeInterval = 60) -> Bool {
        guard let expiresAtMillis else { return false }
        let nowMillis = now.timeIntervalSince1970 * 1000 + skew * 1000
        return expiresAtMillis < nowMillis
    }
}

/// Parse the `claudeAiOauth` object out of a credentials blob into the typed
/// fields the refresher needs. Pure/static for testability. nil when the shape
/// is missing its access token.
public func parseClaudeCredentials(_ data: Data) -> ClaudeOAuthCredentials? {
    guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = parsed["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String, !token.isEmpty
    else { return nil }
    let scopes = (oauth["scopes"] as? [String]) ?? []
    return ClaudeOAuthCredentials(
        accessToken: token,
        refreshToken: oauth["refreshToken"] as? String,
        expiresAtMillis: (oauth["expiresAt"] as? NSNumber)?.doubleValue,
        scopes: scopes
    )
}

/// Produce an updated credentials blob JSON by overwriting only the rotating
/// OAuth fields (`accessToken`, `refreshToken`, `expiresAt`) inside the
/// original blob's `claudeAiOauth` object, leaving every other key — including
/// sibling top-level keys like `mcpOAuth` and other `claudeAiOauth` fields
/// (`subscriptionType`, `rateLimitTier`, …) — byte-for-byte intact. This is
/// the round-trip-fidelity contract: the CLI must still read what we write.
///
/// Returns nil if the original blob isn't the expected object-with-claudeAiOauth
/// shape (caller should then not write anything back).
public func rewriteClaudeCredentials(
    original: Data,
    newAccessToken: String,
    newRefreshToken: String,
    newExpiresAtMillis: Double
) -> Data? {
    guard var root = try? JSONSerialization.jsonObject(with: original) as? [String: Any],
          var oauth = root["claudeAiOauth"] as? [String: Any]
    else { return nil }
    oauth["accessToken"] = newAccessToken
    oauth["refreshToken"] = newRefreshToken
    // Claude Code stores `expiresAt` as an integer millisecond epoch.
    oauth["expiresAt"] = Int(newExpiresAtMillis)
    root["claudeAiOauth"] = oauth
    // `.sortedKeys` gives deterministic output for the round-trip test; the CLI
    // parses by key so ordering is irrelevant to it.
    return try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
}

// MARK: - Token endpoint client

/// Result of a successful OAuth refresh_token grant.
public struct RefreshedOAuthToken: Sendable, Equatable {
    public let accessToken: String
    /// The rotated refresh token. Anthropic rotates refresh tokens on every
    /// grant (verified empirically 2026-07-05: the old token becomes
    /// `invalid_grant` immediately), so this MUST be persisted or the login
    /// breaks. Falls back to the caller's old token only when the server omits
    /// it (it never has in practice).
    public let refreshToken: String
    /// Absolute expiry as unix epoch milliseconds (= now + expires_in).
    public let expiresAtMillis: Double
}

public enum ClaudeOAuthRefreshError: LocalizedError, CustomStringConvertible, Equatable {
    /// The refresh token itself is dead (400 invalid_grant) — only a re-login
    /// recovers. Distinct from transient failures so callers can surface
    /// "needs re-login" rather than retrying forever.
    case invalidGrant
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case network(String)
    case badResponse(String)

    public var description: String {
        switch self {
        case .invalidGrant: return "refresh token invalid (needs re-login)"
        case .rateLimited(let ra): return "refresh rate limited\(ra.map { " (retry \(Int($0))s)" } ?? "")"
        case .http(let code): return "refresh HTTP \(code)"
        case .network(let msg): return "refresh network error: \(msg)"
        case .badResponse(let msg): return "refresh bad response: \(msg)"
        }
    }

    public var errorDescription: String? { description }
}

/// Performs the Anthropic OAuth `refresh_token` grant. Isolated behind a
/// protocol so the fetcher can be tested without a live token endpoint.
public protocol ClaudeOAuthRefreshing: Sendable {
    func refresh(refreshToken: String, scopes: [String]) async -> Result<RefreshedOAuthToken, ClaudeOAuthRefreshError>
}

/// Live refresher against `https://platform.claude.com/v1/oauth/token`, using
/// the same client id, body shape, and grant the Claude Code CLI uses (see
/// `w10` in the bundled cli.js — verified 2026-07-05). A browser/axios-style
/// User-Agent is required: Cloudflare returns 403 (error 1010) to requests
/// without one.
public struct LiveClaudeOAuthRefresher: ClaudeOAuthRefreshing {
    /// Public Claude Code OAuth client id (from cli.js `CLIENT_ID`).
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    public static let tokenURL = "https://platform.claude.com/v1/oauth/token"
    /// UA that clears the Cloudflare edge check (verified 2026-07-05).
    public static let userAgent = "axios/1.7.9"

    public let session: URLSession
    private let now: @Sendable () -> Date

    public init(session: URLSession = .shared, now: (@Sendable () -> Date)? = nil) {
        self.session = session
        self.now = now ?? { Date() }
    }

    public func refresh(refreshToken: String, scopes: [String])
        async -> Result<RefreshedOAuthToken, ClaudeOAuthRefreshError> {
        guard let url = URL(string: Self.tokenURL) else {
            return .failure(.network("invalid token URL"))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
            "scope": scopes.joined(separator: " "),
        ]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            return .failure(.badResponse("could not encode refresh body"))
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
        guard let http = response as? HTTPURLResponse else {
            return .failure(.network("non-HTTP response"))
        }
        switch http.statusCode {
        case 200:
            return Self.parseSuccess(data: data, refreshTokenFallback: refreshToken, now: now())
        case 400:
            // invalid_grant → the refresh token is dead.
            return .failure(.invalidGrant)
        case 429:
            let ra = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            return .failure(.rateLimited(retryAfter: ra))
        default:
            return .failure(.http(http.statusCode))
        }
    }

    static func parseSuccess(data: Data, refreshTokenFallback: String, now: Date)
        -> Result<RefreshedOAuthToken, ClaudeOAuthRefreshError> {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String, !access.isEmpty
        else {
            return .failure(.badResponse("no access_token in refresh response"))
        }
        let newRefresh = (obj["refresh_token"] as? String) ?? refreshTokenFallback
        let expiresIn = (obj["expires_in"] as? NSNumber)?.doubleValue ?? 0
        let expiresAtMillis = (now.timeIntervalSince1970 + expiresIn) * 1000
        return .success(RefreshedOAuthToken(
            accessToken: access,
            refreshToken: newRefresh,
            expiresAtMillis: expiresAtMillis
        ))
    }
}
