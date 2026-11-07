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
struct URLSessionRelayInfoClient: RelayInfoFetching {
    private let session: URLSession
    private let userAgent: String

    init(session: URLSession = .shared, userAgent: String = PhoneBridgeConstants.userAgent) {
        self.session = session
        self.userAgent = userAgent
    }

    /// Sends `GET <relay path>/v1/info` with the bridge's User-Agent and a
    /// timeout of `PhoneBridgeConstants.relayInfoTimeoutSeconds`.
    ///
    /// The request ignores any cached answer: the check runs before every
    /// connect so that a relay redeployed or replaced since the last one is
    /// judged as it is now.
    ///
    /// - A request that fails throws `.relayCheckFailed` with the failure's
    ///   description.
    /// - An answer other than HTTP 200 throws `.relayCheckFailed("HTTP <code>")`.
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

        let body: Data
        let response: URLResponse
        do {
            (body, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw PhoneBridgeError.relayCheckFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw PhoneBridgeError.relayCheckFailed("the answer was not an HTTP response")
        }
        guard http.statusCode == 200 else {
            throw PhoneBridgeError.relayCheckFailed("HTTP \(http.statusCode)")
        }
        do {
            return try JSONDecoder().decode(PhoneRelayInfo.self, from: body)
        } catch {
            throw PhoneBridgeError.notATBDRelay
        }
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
