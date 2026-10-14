import Foundation
import NIOHTTP1

/// The secret that gates the daemon's HTTP RPC port, and its owner-only file.
enum HTTPRPCToken {
    enum WriteError: LocalizedError {
        case openFailed(errno: Int32)
        case writeFailed(errno: Int32)
        case chmodFailed(errno: Int32)
        case renameFailed(errno: Int32)

        // A daemon that cannot write its token file does not start, so the
        // step and errno have to survive into the startup failure's log line.
        var errorDescription: String? {
            switch self {
            case .openFailed(let code): return "Creating the HTTP token file failed: \(String(cString: strerror(code)))"
            case .writeFailed(let code): return "Writing the HTTP token file failed: \(String(cString: strerror(code)))"
            case .chmodFailed(let code): return "Restricting the HTTP token file to its owner failed: \(String(cString: strerror(code)))"
            case .renameFailed(let code): return "Moving the HTTP token file into place failed: \(String(cString: strerror(code)))"
            }
        }
    }

    /// 32 random bytes, lowercase hex (64 characters).
    /// `SystemRandomNumberGenerator` is cryptographically secure on Darwin
    /// (it draws from the kernel CSPRNG).
    static func generate() -> String {
        var rng = SystemRandomNumberGenerator()
        var out = ""
        out.reserveCapacity(64)
        for _ in 0..<32 {
            let byte = UInt8.random(in: .min ... .max, using: &rng)
            out += String(byte, radix: 16).leftPadded(to: 2)
        }
        return out
    }

    /// Writes `contents` to `path` so that the file never exists with wider
    /// than owner-only permissions: a uniquely named sibling is created with
    /// mode 0600 (`O_EXCL`, `O_NOFOLLOW`), filled, then renamed over `path`.
    /// The temporary file is removed on any failure.
    static func writeOwnerOnly(_ contents: String, to path: String) throws {
        let tmp = "\(path).tmp-\(UUID().uuidString.prefix(8))"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw WriteError.openFailed(errno: errno) }

        var succeeded = false
        defer {
            if !succeeded { unlink(tmp) }
        }

        do {
            let bytes = Array(contents.utf8)
            var offset = 0
            while offset < bytes.count {
                let n = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                if n < 0 {
                    if errno == EINTR { continue }
                    let err = errno
                    close(fd)
                    throw WriteError.writeFailed(errno: err)
                }
                offset += n
            }
            // The umask can only narrow the mode given to open(); be explicit anyway.
            guard fchmod(fd, 0o600) == 0 else {
                let err = errno
                close(fd)
                throw WriteError.chmodFailed(errno: err)
            }
        }
        close(fd)

        guard rename(tmp, path) == 0 else { throw WriteError.renameFailed(errno: errno) }
        succeeded = true
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: "0", count: width - count) + self
    }
}

/// Decides, from a request head alone, whether the HTTP RPC endpoint serves it.
/// Pure and side-effect free, so the whole policy is testable without a socket.
///
/// Checks run in this order and the first failure wins:
/// 1. `Host` must be exactly one of `127.0.0.1:<port>`, `localhost:<port>`,
///    `[::1]:<port>` (case-insensitive), where `<port>` is the port the
///    connection arrived on. This defeats DNS rebinding, where a page's
///    requests reach the daemon under an attacker-controlled hostname.
/// 2. Any `Origin` header, whatever its value (including `null`), is refused.
///    The allowlist of origins is deliberately empty. Browsers attach `Origin`
///    to every POST and to every CORS preflight, so this refuses all browser
///    traffic, including "simple" cross-origin POSTs that need no preflight.
///    No `Access-Control-*` response header is ever sent.
/// 3. `X-TBD-Token` must be present exactly once and equal the per-start
///    secret, compared in constant time. A custom header is not CORS-safelisted,
///    so a browser could not send it without a preflight that check 2 refuses.
struct HTTPRequestGate {
    enum Refusal: Equatable {
        case host
        case origin
        case token

        var status: HTTPResponseStatus {
            switch self {
            case .host, .origin: return .forbidden
            case .token: return .unauthorized
            }
        }

        /// Reason category for logs. Never includes header values.
        var category: String {
            switch self {
            case .host: return "host"
            case .origin: return "origin"
            case .token: return "token"
            }
        }
    }

    static let tokenHeader = "X-TBD-Token"

    let port: Int
    let token: String
    /// Names the token file in the refusal text; never the token itself.
    let tokenFilePath: String

    init(port: Int, token: String, tokenFilePath: String = "the http-token file") {
        self.port = port
        self.token = token
        self.tokenFilePath = tokenFilePath
    }

    func refusal(for head: HTTPRequestHead) -> Refusal? {
        // Raw header values throughout: `headers[canonicalForm:]` splits on
        // commas and drops empty values, which would let `Origin:` read as absent.
        let hosts = head.headers["Host"]
        let allowedHosts = ["127.0.0.1:\(port)", "localhost:\(port)", "[::1]:\(port)"]
        guard hosts.count == 1, allowedHosts.contains(hosts[0].lowercased()) else {
            return .host
        }

        if head.headers.contains(name: "Origin") {
            return .origin
        }

        let tokens = head.headers[Self.tokenHeader]
        guard tokens.count == 1,
              Self.constantTimeEquals(Array(tokens[0].utf8), Array(token.utf8))
        else {
            return .token
        }
        return nil
    }

    func message(for refusal: Refusal) -> String {
        switch refusal {
        case .host:
            return "Host header must be 127.0.0.1:\(port), localhost:\(port) or [::1]:\(port)"
        case .origin:
            return "Browser requests are refused: this endpoint accepts no Origin header"
        case .token:
            return "Missing or wrong \(Self.tokenHeader) header: send the contents of \(tokenFilePath)"
        }
    }

    /// Compares without exiting early on the first differing byte. A length
    /// mismatch is a rejection, but the loop still runs over the shorter side.
    static func constantTimeEquals(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        var diff = UInt8(truncatingIfNeeded: a.count ^ b.count)
        diff |= UInt8(truncatingIfNeeded: (a.count ^ b.count) >> 8)
        for i in 0..<min(a.count, b.count) {
            diff |= a[i] ^ b[i]
        }
        return diff == 0
    }
}
