import Foundation
import Security

/// Relay room IDs and pairing secrets, and the relay URLs built from them.
///
/// A room ID and a pairing secret are each 32 random bytes, written as
/// base64url without padding: 43 characters, the form the relay checks with
/// `^[A-Za-z0-9_-]{43}$` (relay API v1).
enum PhoneRoom {
    /// The random bytes in a room ID or a pairing secret.
    static let tokenByteCount = 32

    /// 32 bytes from the system's secure random generator, as base64url.
    static func newToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: tokenByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return Base64URL.encode(Data(bytes))
    }

    /// The 32 bytes `roomID` names, or nil unless it is canonical base64url
    /// for exactly 32 bytes.
    static func roomBytes(_ roomID: String) -> Data? {
        guard let bytes = Base64URL.decode(roomID), bytes.count == tokenByteCount else { return nil }
        return bytes
    }

    /// The laptop's WebSocket URL for `roomID`:
    /// `<relay path>/v1/rooms/<roomID>?role=laptop`, with `https` mapped to
    /// `wss` and `http` (a loopback test relay) to `ws`.
    ///
    /// A path prefix on the relay URL is kept, so a relay served under
    /// `https://acme.example/relay` gets `/relay/v1/rooms/...`. Trailing
    /// slashes are dropped before the path is appended, so the result never
    /// holds `//v1/`, which the relay answers with a 404.
    static func socketURL(relay: URL, roomID: String) -> URL {
        var parts = baseComponents(relay)
        switch parts.scheme?.lowercased() {
        case "https":
            parts.scheme = "wss"
        case "http":
            parts.scheme = "ws"
        default:
            break
        }
        let room = roomID.addingPercentEncoding(withAllowedCharacters: pathSegmentCharacters) ?? ""
        parts.percentEncodedPath += "/v1/rooms/" + room
        parts.percentEncodedQuery = "role=laptop"
        return parts.url ?? relay
    }

    /// The relay's `GET /v1/info` URL: `<relay path>/v1/info`.
    static func infoURL(relay: URL) -> URL {
        var parts = baseComponents(relay)
        parts.percentEncodedPath += "/v1/info"
        return parts.url ?? relay
    }

    /// The characters a path segment may carry unencoded: RFC 3986's
    /// unreserved set, which holds every base64url character. Spelled out in
    /// ASCII, because `CharacterSet.alphanumerics` also admits non-ASCII
    /// letters, which `percentEncodedPath` refuses.
    private static let pathSegmentCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    /// `relay`'s components with no query, no fragment and no trailing slash
    /// on the path, ready to have a path appended. `PhoneURLValidation.relay`
    /// already normalizes a stored relay URL this way; this keeps the
    /// builders safe for any URL.
    private static func baseComponents(_ relay: URL) -> URLComponents {
        // A URL with a host always has components and a path that is empty
        // or starts with "/", so appending "/v1/..." keeps `url` non-nil.
        var parts = URLComponents(url: relay, resolvingAgainstBaseURL: false) ?? URLComponents()
        var path = parts.percentEncodedPath
        while path.hasSuffix("/") {
            path.removeLast()
        }
        parts.percentEncodedPath = path
        parts.percentEncodedQuery = nil
        parts.percentEncodedFragment = nil
        return parts
    }
}
