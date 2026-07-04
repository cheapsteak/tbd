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

public struct ClaudeOAuthTokenReadError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
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
    case ok([ClaudeUsageLimitBucket])
    /// No stored credential for this profile (not logged in), or the
    /// credential could not be read. The reason is human-readable and MUST
    /// NOT contain token bytes.
    case noCredentials(String)
    case httpError(Int)  // 401 = token invalid/expired, 429 = rate limited, ...
    case networkError(String)
    case decodeError(String)

    /// Short human-readable reason for non-ok statuses, used in snapshot
    /// status strings. nil for `.ok`.
    public var failureReason: String? {
        switch self {
        case .ok: return nil
        case .noCredentials(let reason): return "no credentials (\(reason))"
        case .httpError(let code): return "HTTP \(code)"
        case .networkError(let msg): return "network error: \(msg)"
        case .decodeError(let msg): return "decode error: \(msg)"
        }
    }
}

public protocol ProfileUsageFetching: Sendable {
    /// Fetch the usage buckets for the OAuth account logged into the given
    /// isolated `CLAUDE_CONFIG_DIR`. Never throws — failures come back as
    /// non-ok statuses so a poller sweep can record them per profile.
    func fetchUsage(configDirPath: String) async -> ProfileUsageFetchStatus
}

/// Live fetcher: resolve the profile's OAuth access token, then GET
/// `https://api.anthropic.com/api/oauth/usage` with it — the same endpoint
/// `LiveClaudeUsageFetcher` uses for API-key profiles, but with CLI-mediated
/// (keychain) credentials and the richer `limits[]` parse.
public struct LiveProfileUsageFetcher: ProfileUsageFetching {
    public let tokenReader: ClaudeOAuthTokenReading
    public let session: URLSession

    public init(
        tokenReader: ClaudeOAuthTokenReading = SecurityCLIOAuthTokenReader(),
        session: URLSession = .shared
    ) {
        self.tokenReader = tokenReader
        self.session = session
    }

    public func fetchUsage(configDirPath: String) async -> ProfileUsageFetchStatus {
        let token: String?
        do {
            token = try await tokenReader.accessToken(forConfigDirPath: configDirPath)
        } catch {
            return .noCredentials("credential read failed: \(error)")
        }
        guard let token else {
            return .noCredentials("no stored credential — needs /login")
        }

        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            return .networkError("invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
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
        guard http.statusCode == 200 else {
            return .httpError(http.statusCode)
        }
        do {
            return .ok(try ClaudeUsagePayloadParser.parseBuckets(from: data))
        } catch {
            return .decodeError("\(error)")
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

    public struct ParseError: Error, CustomStringConvertible {
        public let description: String
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
