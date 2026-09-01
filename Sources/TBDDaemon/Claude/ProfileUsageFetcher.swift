import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "profileUsageFetcher")

// MARK: - OAuth token reading (per profile config dir)

/// Reads the Claude Code OAuth access token that `/login` stored for a given
/// isolated `CLAUDE_CONFIG_DIR`.
///
/// The daemon must NOT read the credential item via `SecItemCopyMatching`:
/// Claude Code's keychain items are ACL'd to specific client binaries and a
/// direct Security-framework read from TBDDaemon would trigger a blocking
/// keychain prompt (or fail outright). Instead the live implementation shells
/// out to `/usr/bin/security find-generic-password`, which is authorized for
/// these items (verified empirically against all three live profiles on
/// 2026-07-03), with the profile dir's `.credentials.json` file as a fallback
/// (Claude Code writes that file when the keychain is unavailable).
public protocol ClaudeOAuthTokenReading: Sendable {
    /// Returns the OAuth access token for the credentials belonging to the
    /// given config dir path, or nil when no credential is stored (not logged
    /// in). Throws only on unexpected read errors (tool failure, bad JSON).
    func accessToken(forConfigDirPath path: String) async throws -> String?
}

public struct ClaudeOAuthTokenReadError: LocalizedError, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }

    public var errorDescription: String? { description }
}

/// Parse the `claudeAiOauth.accessToken` field out of a Claude Code
/// credentials JSON blob (the keychain item / `.credentials.json` payload).
/// Pure and static for testability. Returns nil when the shape is missing.
public func parseClaudeCredentialsAccessToken(_ data: Data) -> String? {
    guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = parsed["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String,
          !token.isEmpty
    else { return nil }
    return token
}

/// Live token reader: `/usr/bin/security find-generic-password -s <service> -w`
/// with the service name derived from the config dir path (same derivation
/// Claude Code uses — see `ClaudeCodeCredentialsKeychain`). Falls back to
/// `<configDir>/.credentials.json` when the keychain item is absent.
public struct SecurityCLIOAuthTokenReader: ClaudeOAuthTokenReading {
    public init() {}

    public func accessToken(forConfigDirPath path: String) async throws -> String? {
        let service = ClaudeCodeCredentialsKeychain.serviceName(forConfigDirPath: path)
        let outcome = try await Self.runSecurityFindGenericPassword(service: service)
        switch outcome {
        case .found(let data):
            guard let token = parseClaudeCredentialsAccessToken(data) else {
                throw ClaudeOAuthTokenReadError("keychain item present but has no claudeAiOauth.accessToken")
            }
            return token
        case .notFound:
            // Fall back to the on-disk credentials file (Claude Code writes it
            // when the keychain is unavailable).
            let fileURL = URL(fileURLWithPath: path).appendingPathComponent(".credentials.json")
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            return parseClaudeCredentialsAccessToken(data)
        }
    }

    enum SecurityOutcome {
        case found(Data)
        case notFound
    }

    /// Run `security find-generic-password -s <service> -w` and capture the
    /// secret bytes from stdout. Exit code 44 (errSecItemNotFound) maps to
    /// `.notFound`; other non-zero exits throw. Never routes through a shell.
    static func runSecurityFindGenericPassword(service: String) async throws -> SecurityOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        process.environment = [:]  // no env needed; never inherit shell state
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()  // swallow; may echo item metadata

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                switch proc.terminationStatus {
                case 0:
                    // stdout is the secret followed by a trailing newline.
                    var bytes = data
                    if bytes.last == UInt8(ascii: "\n") { bytes.removeLast() }
                    continuation.resume(returning: .found(bytes))
                case 44:  // errSecItemNotFound
                    continuation.resume(returning: .notFound)
                default:
                    continuation.resume(throwing: ClaudeOAuthTokenReadError(
                        "security find-generic-password exited \(proc.terminationStatus)"))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: ClaudeOAuthTokenReadError(
                    "failed to launch /usr/bin/security: \(error.localizedDescription)"))
            }
        }
    }
}

// MARK: - Per-profile usage fetch

public enum ProfileUsageFetchStatus: Equatable, Sendable {
    /// Buckets from a successful fetch, plus the `anthropic-organization-id`
    /// response header when one was sent.
    ///
    /// Both fetchers read that header opportunistically: the token probe is
    /// known to return it, and whether `/api/oauth/usage` does is unverified,
    /// so nil is a normal outcome rather than a failure. It is an account
    /// identifier, not a credential — safe to log at `.public`, but it must
    /// never be composed into a string that also carries token bytes.
    case ok([ClaudeUsageLimitBucket], organizationID: String?)
    /// No stored credential for this profile (not logged in), or the
    /// credential could not be read. The reason is human-readable and MUST
    /// NOT contain token bytes.
    case noCredentials(String)
    /// The stored credential is present but the account needs the user to
    /// re-run `/login`: either the access token was rejected (401/403) and
    /// automatic refresh could not recover it, or the refresh token itself is
    /// dead (`invalid_grant`).
    case needsLogin(String)
    /// HTTP 429. `retryAfter` carries the server's `Retry-After` (seconds) when
    /// present, so the poller can honor it instead of guessing a backoff.
    case rateLimited(retryAfter: TimeInterval?)
    case httpError(Int)
    case networkError(String)
    case decodeError(String)

    /// Short human-readable reason for non-ok statuses, used in snapshot
    /// status strings. nil for `.ok`.
    public var failureReason: String? {
        switch self {
        case .ok: return nil
        case .noCredentials(let reason): return "no credentials (\(reason))"
        case .needsLogin(let reason): return "needs re-login (\(reason))"
        case .rateLimited(let ra):
            return ra.map { "rate limited (retry \(Int($0))s)" } ?? "rate limited"
        case .httpError(let code): return "HTTP \(code)"
        case .networkError(let msg): return "network error: \(msg)"
        case .decodeError(let msg): return "decode error: \(msg)"
        }
    }

    /// Machine-readable classification for the snapshot / UI.
    public var kind: ProfileUsageStatusKind {
        switch self {
        case .ok: return .ok
        case .noCredentials: return .noCredentials
        case .needsLogin: return .needsLogin
        case .rateLimited: return .rateLimited
        case .httpError: return .unknown
        case .networkError: return .networkError
        case .decodeError: return .decodeError
        }
    }

    /// The `Retry-After` the server asked for, if any (429 only).
    public var retryAfter: TimeInterval? {
        if case .rateLimited(let ra) = self { return ra }
        return nil
    }
}

/// Where a fetcher gets its bearer credential.
///
/// `.configDir` resolves a `/login` credential out of an isolated
/// `CLAUDE_CONFIG_DIR`; `.token` is a stored `claude setup-token` used
/// directly. The enum exists so `OAuthProfileUsagePoller` can dispatch on
/// profile kind without knowing how either fetcher obtains its credential.
///
/// A `.token` value carries secret bytes, so `CustomStringConvertible` is
/// implemented to *enforce* that it never reaches a log line or an error
/// string. Merely omitting the conformance would not: Swift's default
/// reflection renders `String(describing:)` of this enum as
/// `token("sk-ant-oat01-…")`, printing the secret in full. The conformance
/// below makes every interpolation, every `String(describing:)`, and every
/// `%@`-style rendering safe by construction. The config-dir path is not
/// secret and stays visible, because it is the only thing that makes a
/// `.configDir` failure diagnosable.
public enum ProfileUsageCredential: Equatable, Sendable, CustomStringConvertible {
    case configDir(String)
    case token(String)

    public var description: String {
        switch self {
        case let .configDir(path): return "configDir(\(path))"
        case .token: return "token(<redacted>)"
        }
    }
}

public protocol ProfileUsageFetching: Sendable {
    /// Fetch the usage buckets for the account the given credential
    /// authenticates. Never throws — failures come back as non-ok statuses so
    /// a poller sweep can record them per profile. A fetcher that cannot serve
    /// a credential shape returns `.noCredentials` rather than trapping.
    func fetchUsage(credential: ProfileUsageCredential) async -> ProfileUsageFetchStatus
}

/// Live fetcher: resolve the profile's OAuth access token, then GET
/// `https://api.anthropic.com/api/oauth/usage` with it — the same endpoint
/// `LiveClaudeUsageFetcher` uses for API-key profiles, but with CLI-mediated
/// (keychain) credentials and the richer `limits[]` parse.
///
/// Token freshness is handled here so a profile whose access token has expired
/// (nothing running a Claude session on it to refresh it) recovers on its own:
/// before the GET, an expired credential is refreshed via the OAuth
/// `refresh_token` grant and the rotated pair written back to the keychain (so
/// the CLI benefits too); a 401/403 on the GET triggers one refresh-and-retry.
/// When refresh fails because the refresh token is dead, the profile is
/// classified `.needsLogin` rather than an eternal auth error.
public struct LiveProfileUsageFetcher: ProfileUsageFetching {
    public let credentialStore: ClaudeCredentialStoring
    public let refresher: ClaudeOAuthRefreshing
    public let session: URLSession
    private let now: @Sendable () -> Date

    public init(
        credentialStore: ClaudeCredentialStoring = SecurityCLIClaudeCredentialStore(),
        refresher: ClaudeOAuthRefreshing = LiveClaudeOAuthRefresher(),
        session: URLSession = .shared,
        now: (@Sendable () -> Date)? = nil
    ) {
        self.credentialStore = credentialStore
        self.refresher = refresher
        self.session = session
        self.now = now ?? { Date() }
    }

    public func fetchUsage(credential: ProfileUsageCredential) async -> ProfileUsageFetchStatus {
        // This fetcher serves `/login`-authenticated profiles only. A setup
        // token 403s on `/api/oauth/usage` (it lacks the `user:profile`
        // scope), so there is nothing sensible to do with `.token` here —
        // `TokenProfileUsageFetcher` serves those.
        guard case .configDir(let configDirPath) = credential else {
            return .noCredentials("config-dir fetcher cannot serve a token credential")
        }

        // 1. Read the full credential blob.
        let blob: Data?
        do {
            blob = try await credentialStore.readBlob(forConfigDirPath: configDirPath)
        } catch {
            return .noCredentials("credential read failed: \(error)")
        }
        guard let blob, var creds = parseClaudeCredentials(blob) else {
            return .noCredentials("no stored credential — needs /login")
        }

        // 2. Proactively refresh an already-expired access token before the
        //    request (avoids a guaranteed 401 round-trip).
        if creds.isExpired(now: now()) {
            switch await refreshAndPersist(creds, blob: blob, configDirPath: configDirPath) {
            case .refreshed(let updated):
                creds = updated
            case .needsLogin(let reason):
                return .needsLogin(reason)
            case .transient(let status):
                return status
            }
        }

        // 3. Fetch usage. On 401/403, refresh once and retry.
        let firstAttempt = await requestUsage(accessToken: creds.accessToken)
        if case .httpError(let code) = firstAttempt, code == 401 || code == 403 {
            switch await refreshAndPersist(creds, blob: blob, configDirPath: configDirPath) {
            case .refreshed(let updated):
                return await requestUsage(accessToken: updated.accessToken)
            case .needsLogin(let reason):
                return .needsLogin(reason)
            case .transient(let status):
                return status
            }
        }
        return firstAttempt
    }

    // MARK: Refresh + persist

    private enum RefreshOutcome {
        case refreshed(ClaudeOAuthCredentials)
        case needsLogin(String)
        case transient(ProfileUsageFetchStatus)
    }

    /// Refresh the access token and write the rotated pair back to the
    /// keychain. A failed write-back is treated as `.needsLogin`: we must not
    /// report success against a token the CLI can't see (the refresh token has
    /// already rotated server-side, so the un-persisted old one is now dead).
    private func refreshAndPersist(_ creds: ClaudeOAuthCredentials, blob: Data,
                                   configDirPath: String) async -> RefreshOutcome {
        guard let refreshToken = creds.refreshToken else {
            return .needsLogin("no refresh token stored")
        }
        let result = await refresher.refresh(refreshToken: refreshToken, scopes: creds.scopes)
        switch result {
        case .success(let token):
            guard let rewritten = rewriteClaudeCredentials(
                original: blob,
                newAccessToken: token.accessToken,
                newRefreshToken: token.refreshToken,
                newExpiresAtMillis: token.expiresAtMillis
            ) else {
                return .needsLogin("could not rewrite credential blob")
            }
            let wrote = await credentialStore.writeBlob(rewritten, forConfigDirPath: configDirPath)
            guard wrote else {
                return .needsLogin("token refreshed but keychain write-back was denied")
            }
            var updated = creds
            updated.accessToken = token.accessToken
            updated.refreshToken = token.refreshToken
            updated.expiresAtMillis = token.expiresAtMillis
            return .refreshed(updated)
        case .failure(let error):
            switch error {
            case .invalidGrant:
                return .needsLogin("refresh token expired")
            case .rateLimited(let ra):
                return .transient(.rateLimited(retryAfter: ra))
            case .network(let msg):
                return .transient(.networkError("refresh: \(msg)"))
            case .http(let code):
                return .transient(.httpError(code))
            case .badResponse(let msg):
                return .transient(.networkError("refresh: \(msg)"))
            }
        }
    }

    // MARK: Usage request

    private func requestUsage(accessToken: String) async -> ProfileUsageFetchStatus {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            return .networkError("invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return .networkError(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            return .networkError("non-HTTP response")
        }
        switch http.statusCode {
        case 200:
            do {
                let buckets = try ClaudeUsagePayloadParser.parseBuckets(from: data)
                // Opportunistic: whether this endpoint sends the header is
                // unverified, so nil is a normal outcome. An empty string
                // becomes nil — "" would read as "this account's id is the
                // empty string" rather than "absent".
                let organizationID = http
                    .value(forHTTPHeaderField: "anthropic-organization-id")
                    .flatMap { $0.isEmpty ? nil : $0 }
                return .ok(buckets, organizationID: organizationID)
            } catch {
                return .decodeError("\(error)")
            }
        case 429:
            let ra = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            return .rateLimited(retryAfter: ra)
        default:
            return .httpError(http.statusCode)
        }
    }
}

// MARK: - Payload parsing

/// Defensive parser for the `/api/oauth/usage` response. The primary source
/// is the `limits[]` array (each entry a `ClaudeUsageLimitBucket`); when the
/// API omits it, the top-level `five_hour` / `seven_day` windows are
/// synthesized into `session` / `weekly_all` buckets so older response shapes
/// still yield data. Malformed individual entries are skipped, unknown kinds
/// flow through, absent buckets simply don't appear.
public enum ClaudeUsagePayloadParser {

    public struct ParseError: LocalizedError, CustomStringConvertible {
        public let description: String

        public var errorDescription: String? { description }
    }

    public static func parseBuckets(from data: Data) throws -> [ClaudeUsageLimitBucket] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload: RawPayload
        do {
            payload = try decoder.decode(RawPayload.self, from: data)
        } catch {
            throw ParseError(description: "usage payload not decodable: \(error)")
        }

        if let limits = payload.limits, !limits.isEmpty {
            let buckets = limits.compactMap { raw -> ClaudeUsageLimitBucket? in
                guard let kind = raw.kind, let percent = raw.percent else { return nil }
                return ClaudeUsageLimitBucket(
                    kind: kind,
                    group: raw.group,
                    percent: percent,
                    severity: raw.severity,
                    resetsAt: parseResetDate(raw.resetsAt),
                    modelDisplayName: raw.scope?.model?.displayName,
                    isActive: raw.isActive
                )
            }
            if !buckets.isEmpty { return buckets }
        }

        // Fallback: synthesize from the legacy top-level windows. Utilization
        // is passed through on the API's own scale (0–100 on current
        // responses).
        var fallback: [ClaudeUsageLimitBucket] = []
        if let window = payload.fiveHour, let pct = window.utilization {
            fallback.append(ClaudeUsageLimitBucket(
                kind: "session", group: "session", percent: pct,
                resetsAt: parseResetDate(window.resetsAt)))
        }
        if let window = payload.sevenDay, let pct = window.utilization {
            fallback.append(ClaudeUsageLimitBucket(
                kind: "weekly_all", group: "weekly", percent: pct,
                resetsAt: parseResetDate(window.resetsAt)))
        }
        guard !fallback.isEmpty else {
            throw ParseError(description: "usage payload contains no limits and no five_hour/seven_day windows")
        }
        return fallback
    }

    /// Parse an API timestamp like "2026-07-04T01:10:00.245613+00:00".
    /// Tries fractional-second ISO 8601 first, then plain ISO 8601.
    /// nil in / unparseable → nil out (bucket keeps a nil reset).
    public static func parseResetDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    // MARK: Raw decodable shapes (everything optional — parse defensively)

    private struct RawPayload: Decodable {
        struct RawWindow: Decodable {
            let utilization: Double?
            let resetsAt: String?
        }
        struct RawModel: Decodable {
            let displayName: String?
        }
        struct RawScope: Decodable {
            let model: RawModel?
        }
        struct RawLimit: Decodable {
            let kind: String?
            let group: String?
            let percent: Double?
            let severity: String?
            let resetsAt: String?
            let scope: RawScope?
            let isActive: Bool?
        }
        let fiveHour: RawWindow?
        let sevenDay: RawWindow?
        let limits: [RawLimit]?
    }
}
