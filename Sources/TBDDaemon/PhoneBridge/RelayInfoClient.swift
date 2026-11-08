import Foundation
import TBDShared

/// Reads a relay's `GET /v1/info`. Production uses
/// ``URLSessionRelayInfoClient``; tests use a fake whose answer they set.
protocol RelayInfoFetching: Sendable {
    /// The info object of the relay at `relay`, the relay URL the user saved.
    /// Throws ``PhoneBridgeError/relayCheckFailed(_:)`` when the relay cannot
    /// be read and ``PhoneBridgeError/notATBDRelay`` when its answer is not an
    /// info object.
    func info(relay: URL) async throws -> PhoneRelayInfo
}

/// ``RelayInfoFetching`` over `URLSession`.
///
/// **Lifetimes.** As ``URLSessionRelayTransport`` does for a socket, each
/// check makes its own `URLSession`, with its own delegate, and invalidates
/// it before it returns, so nothing of one check outlives it. The client
/// itself owns only the configuration.
///
/// **What a relay cannot make the check do.** The relay is a server the user
/// named, and the check runs before every connect, so it is hardened against
/// a relay that answers badly:
/// - It follows no redirect: the delegate refuses each one, and a 3xx answer
///   is a failure. A relay cannot move the check to plain `http` or to
///   another host.
/// - It keeps no cookies, cache or credentials: the session is ephemeral,
///   with each of those stores turned off.
/// - It reads at most `PhoneBridgeConstants.relayInfoMaxBodyBytes` of the
///   body, and stops reading there.
/// - The whole request, connect to last byte, must finish within
///   `PhoneBridgeConstants.relayInfoTimeoutSeconds`, so a relay that sends
///   its answer a byte at a time cannot hold the check either.
struct URLSessionRelayInfoClient: RelayInfoFetching, @unchecked Sendable {
    // @unchecked: `configuration` is a private copy that nothing mutates;
    // each session copies it again when it is made.

    private let configuration: URLSessionConfiguration
    private let userAgent: String
    private let maximumBodyBytes: Int

    init(configuration: URLSessionConfiguration = .ephemeral,
         userAgent: String = PhoneBridgeConstants.userAgent,
         maximumBodyBytes: Int = PhoneBridgeConstants.relayInfoMaxBodyBytes) {
        let hardened = (configuration.copy() as? URLSessionConfiguration) ?? configuration
        hardened.httpCookieStorage = nil
        hardened.httpShouldSetCookies = false
        hardened.httpCookieAcceptPolicy = .never
        hardened.urlCache = nil
        hardened.requestCachePolicy = .reloadIgnoringLocalCacheData
        hardened.urlCredentialStorage = nil
        hardened.timeoutIntervalForRequest = PhoneBridgeConstants.relayInfoTimeoutSeconds
        hardened.timeoutIntervalForResource = PhoneBridgeConstants.relayInfoTimeoutSeconds
        self.configuration = hardened
        self.userAgent = userAgent
        self.maximumBodyBytes = maximumBodyBytes
    }

    /// Sends `GET <relay path>/v1/info` with the bridge's User-Agent.
    ///
    /// The request ignores any cached answer: the check runs before every
    /// connect so that a relay redeployed or replaced since the last one is
    /// judged as it is now.
    ///
    /// - A request that fails, or takes longer than the timeout, throws
    ///   `.relayCheckFailed` with the failure's description.
    /// - A redirect throws `.relayCheckFailed`, saying TBD does not follow
    ///   one.
    /// - Any other status but 200 throws `.relayCheckFailed("HTTP <code>")`.
    /// - A body larger than `maximumBodyBytes` throws `.relayCheckFailed`,
    ///   read no further than one byte past the limit.
    /// - A 200 whose body does not decode as the info object throws
    ///   `.notATBDRelay`.
    /// - A cancelled request throws `CancellationError`.
    func info(relay: URL) async throws -> PhoneRelayInfo {
        var request = URLRequest(
            url: PhoneRoom.infoURL(relay: relay),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: PhoneBridgeConstants.relayInfoTimeoutSeconds)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let delegate = RelayInfoSessionDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        // Also cancels a body still arriving when the read stops at the
        // limit, so nothing past it is read.
        defer { session.invalidateAndCancel() }

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            // The task's own delegate as well as the session's, so the
            // redirect refusal applies whichever one URLSession consults.
            (bytes, response) = try await session.bytes(for: request, delegate: delegate)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw PhoneBridgeError.relayCheckFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw PhoneBridgeError.relayCheckFailed("the answer was not an HTTP response")
        }
        if (300...399).contains(http.statusCode) {
            throw PhoneBridgeError.relayCheckFailed(
                "the relay answered with a redirect (HTTP \(http.statusCode)), and TBD does not follow redirects. "
                    + "Save the relay's own address.")
        }
        guard http.statusCode == 200 else {
            throw PhoneBridgeError.relayCheckFailed("HTTP \(http.statusCode)")
        }
        let body = try await readBody(bytes, declaredLength: http.expectedContentLength)
        do {
            return try JSONDecoder().decode(PhoneRelayInfo.self, from: body)
        } catch {
            throw PhoneBridgeError.notATBDRelay
        }
    }

    /// The body, at most `maximumBodyBytes` long. A declared length over the
    /// limit is refused before any byte is read; otherwise the read stops at
    /// the first byte past the limit.
    private func readBody(_ bytes: URLSession.AsyncBytes, declaredLength: Int64) async throws -> Data {
        let tooLarge = PhoneBridgeError.relayCheckFailed(
            "the relay's answer is larger than \(maximumBodyBytes) bytes, which no TBD relay sends")
        if declaredLength > Int64(maximumBodyBytes) {
            throw tooLarge
        }
        var body = Data()
        do {
            for try await byte in bytes {
                guard body.count < maximumBodyBytes else { throw tooLarge }
                body.append(byte)
            }
        } catch let error as PhoneBridgeError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw PhoneBridgeError.relayCheckFailed(error.localizedDescription)
        }
        return body
    }
}

/// The session delegate of one relay check. It refuses every redirect, so
/// the check reads the redirect's own answer, which `info(relay:)` refuses.
private final class RelayInfoSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Whether a relay's info object names a relay this laptop can use.
enum RelayCompatibility {
    /// The `name` every TBD relay reports.
    static let relayName = "tbd-relay"

    /// Throws ``PhoneBridgeError/notATBDRelay`` when `info.name` is not
    /// `tbd-relay`, and ``PhoneBridgeError/unsupportedRelayAPI(_:)`` when
    /// `info.api` lacks `PhoneBridgeConstants.relayAPIVersion`. The relay's
    /// version is not checked here: an older relay that still offers the API
    /// works, and the Phone pane only says an update is available.
    static func check(_ info: PhoneRelayInfo) throws {
        guard info.name == relayName else {
            throw PhoneBridgeError.notATBDRelay
        }
        guard info.api.contains(PhoneBridgeConstants.relayAPIVersion) else {
            throw PhoneBridgeError.unsupportedRelayAPI(info.api)
        }
    }
}

/// Compares relay versions, the `version` in `GET /v1/info`.
enum PhoneRelayVersion {
    /// Whether `version` comes before `other`, comparing major, then minor,
    /// then patch as numbers, so `1.10.0` is newer than `1.9.0`.
    ///
    /// Nil when either is not exactly three dot-separated runs of ASCII
    /// digits: a version this build cannot read is never reported as older.
    static func isOlder(_ version: String, than other: String) -> Bool? {
        guard let lhs = parts(version), let rhs = parts(other) else { return nil }
        return lhs.lexicographicallyPrecedes(rhs)
    }

    /// The three numbers of `major.minor.patch`, or nil.
    private static func parts(_ version: String) -> [Int]? {
        let pieces = version.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3 else { return nil }
        var numbers: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty,
                  piece.utf8.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }),
                  let number = Int(piece) else { return nil }
            numbers.append(number)
        }
        return numbers
    }
}
