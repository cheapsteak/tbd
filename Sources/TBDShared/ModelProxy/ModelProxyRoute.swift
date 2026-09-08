import Foundation

/// One session's forwarding instruction, written by the daemon as
/// `routes/<token>.json` under `TBDConstants.modelProxyDir` before the spawn it
/// serves, and read by `TBDModelProxy`.
///
/// The route is the proxy's only source of truth for a request: the upstream
/// base URL, the TBD terminal whose stream file the tee writes, and whether
/// streaming is on for that terminal all come from here and never from a
/// request header. A request whose token names no route is refused, so the
/// proxy cannot be driven as an open forwarder by another local process, and
/// no spoofed header can steer a tee into a terminal's stream file.
public struct ModelProxyRoute: Codable, Sendable, Equatable {
    /// Bumped only when the on-disk shape changes incompatibly. A proxy that
    /// reads a version it does not know refuses the route rather than guessing.
    public static let schemaVersion = 1

    public let version: Int
    /// 32 lowercase hex characters — 128 random bits. Also the last path
    /// component of the route file, so it must never be taken from a request
    /// without `isValidToken` first.
    public let token: String
    public let terminalID: UUID
    /// Absolute `http(s)` base URL with no trailing slash, e.g.
    /// `https://api.anthropic.com`.
    public let upstream: String
    public let streamingEnabled: Bool
    public let createdAt: Date

    public init(
        token: String,
        terminalID: UUID,
        upstream: String,
        streamingEnabled: Bool,
        createdAt: Date = Date()
    ) {
        self.version = Self.schemaVersion
        self.token = token
        self.terminalID = terminalID
        self.upstream = upstream
        self.streamingEnabled = streamingEnabled
        self.createdAt = createdAt
    }

    /// Mints a fresh 128-bit token rendered as 32 lowercase hex characters.
    ///
    /// The generator is a parameter so a test can pin the value; production
    /// call sites take the default and get `UInt64.random`, which draws from
    /// the system CSPRNG.
    public static func mintToken(random: () -> UInt64 = { UInt64.random(in: .min ... .max) }) -> String {
        func hex16(_ value: UInt64) -> String {
            let digits = String(value, radix: 16)
            return String(repeating: "0", count: 16 - digits.count) + digits
        }
        return hex16(random()) + hex16(random())
    }

    /// True for 32 lowercase hex characters and nothing else.
    ///
    /// Deliberately a whitelist over the whole string rather than a scan for
    /// bad substrings: it is the check that keeps a token taken off the wire
    /// from ever composing a path outside `routes/`.
    public static func isValidToken(_ s: String) -> Bool {
        guard s.count == 32 else { return false }
        return s.allSatisfy { $0.isLowercaseHexDigit }
    }
}

private extension Character {
    /// ASCII `0`-`9` or `a`-`f`. Explicitly ASCII: `isHexDigit` also accepts
    /// uppercase and full-width forms, which would let a token that is not
    /// what the daemon minted past the whitelist.
    var isLowercaseHexDigit: Bool {
        guard let ascii = asciiValue else { return false }
        return (ascii >= 0x30 && ascii <= 0x39) || (ascii >= 0x61 && ascii <= 0x66)
    }
}

// MARK: - On-disk coding

extension ModelProxyRoute {
    /// The one coder pair for a route file.
    ///
    /// The daemon writes these files and the proxy reads them, out of two
    /// binaries that are upgraded independently, so the date strategy cannot
    /// be left to whichever `JSONEncoder` each side happens to construct: a
    /// writer on `.deferredToDate` and a reader on `.iso8601` disagree about
    /// `createdAt` and every route on disk becomes malformed at once. Pinning
    /// ISO-8601 in one place also makes a route file readable by a human
    /// looking at `routes/` during an incident.
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// The bytes to write to `routes/<token>.json`.
    public func encodedForRouteFile() throws -> Data {
        try Self.makeEncoder().encode(self)
    }

    /// Decodes the bytes of a `routes/<token>.json`.
    public static func decodeRouteFile(_ data: Data) throws -> ModelProxyRoute {
        try makeDecoder().decode(ModelProxyRoute.self, from: data)
    }
}
