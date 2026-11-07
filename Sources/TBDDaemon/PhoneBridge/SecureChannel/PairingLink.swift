import Foundation

/// What the pairing QR code carries after the loader URL's `#`:
/// `<loaderURL>#p=<base64url(UTF-8 JSON)>`.
///
/// `room`, `secret` and `key` are 32 bytes each in base64url without padding:
/// the relay room ID, the one-time pairing secret (the Noise PSK) and the
/// laptop's X25519 public key. `exp` is the offer's expiry in unix seconds.
/// The loader parses the same format with the same rules, in the same order,
/// so both sides name the same error for the same link.
struct PairingLink: Codable, Equatable, Sendable {
    var v: Int
    var relay: String
    var room: String
    var secret: String
    var key: String
    var name: String
    var exp: Int

    static let currentVersion = 1
    /// The laptop's name is 1 to 256 UTF-8 bytes. Whoever builds a link
    /// truncates a longer name at a character boundary.
    static let maxNameBytes = 256
    /// JavaScript's `Number.MAX_SAFE_INTEGER`, the largest `exp` the loader
    /// reads exactly.
    static let maxExp = 9_007_199_254_740_991

    func url(loaderURL: URL) -> URL {
        let encoder = JSONEncoder()
        // Sorted keys and unescaped slashes make the bytes match
        // `JSON.stringify` over the same keys in sorted order.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Encoding a struct of Strings and Ints cannot throw.
        let json = try! encoder.encode(self)
        var components = URLComponents(url: loaderURL, resolvingAgainstBaseURL: false)!
        components.fragment = "p=" + Base64URL.encode(json)
        return components.url!
    }

    /// Reads a pairing link, checking it in a fixed order so that a link with
    /// several faults fails with the same error here and in the loader.
    static func parse(_ url: URL, now: Date = Date()) throws -> PairingLink {
        guard let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedFragment,
              fragment.hasPrefix("p=") else {
            throw PairingLinkError.missingFragment
        }
        guard let json = Base64URL.decode(String(fragment.dropFirst(2))) else {
            throw PairingLinkError.badBase64
        }
        // JSONDecoder may take bytes after a UTF-16 byte-order mark as UTF-16,
        // while the loader's decoder is strict UTF-8, so check UTF-8 first.
        guard String(validating: json, as: UTF8.self) != nil else {
            throw PairingLinkError.badJSON
        }
        let decoder = JSONDecoder()
        let version: Int
        do {
            version = try decoder.decode(VersionProbe.self, from: json).v
        } catch {
            throw PairingLinkError.badJSON
        }
        guard version == currentVersion else {
            throw PairingLinkError.unsupportedVersion(version)
        }
        let link: PairingLink
        do {
            link = try decoder.decode(PairingLink.self, from: json)
        } catch {
            throw PairingLinkError.badJSON
        }
        try link.checkFields()
        guard now.timeIntervalSince1970 < Double(link.exp) else {
            throw PairingLinkError.expired
        }
        return link
    }

    /// The version alone, read first so that a newer format reports
    /// `unsupportedVersion` rather than whatever field it changed.
    private struct VersionProbe: Decodable {
        let v: Int
    }

    /// Throws `badField` for the first field that fails, in the order relay,
    /// room, secret, key, name, exp.
    private func checkFields() throws {
        guard Self.isAllowedRelay(relay) else {
            throw PairingLinkError.badField("relay")
        }
        for (field, value) in [("room", room), ("secret", secret), ("key", key)] {
            guard Base64URL.decode(value)?.count == 32 else {
                throw PairingLinkError.badField(field)
            }
        }
        guard !name.isEmpty, name.utf8.count <= Self.maxNameBytes else {
            throw PairingLinkError.badField("name")
        }
        guard (1...Self.maxExp).contains(exp) else {
            throw PairingLinkError.badField("exp")
        }
    }

    /// `https`, or plain `http` to a loopback host for a local test relay.
    /// `URLComponents(string:)` accepts text such as `not a url`, so the
    /// scheme and host are checked explicitly. Both compare without case, as
    /// the loader's `URL` lowercases them.
    private static func isAllowedRelay(_ relay: String) -> Bool {
        guard let components = URLComponents(string: relay),
              let host = components.host?.lowercased(), !host.isEmpty else {
            return false
        }
        let scheme = components.scheme?.lowercased()
        return scheme == "https"
            || (scheme == "http" && (host == "localhost" || host == "127.0.0.1"))
    }
}

/// Why a pairing link was refused. `code` is the name the loader's
/// `PairingLinkError` carries for the same fault.
enum PairingLinkError: LocalizedError, Equatable {
    case missingFragment
    case badBase64
    case badJSON
    case unsupportedVersion(Int)
    case badField(String)
    case expired

    /// The case name without its payload.
    var code: String {
        switch self {
        case .missingFragment: return "missingFragment"
        case .badBase64: return "badBase64"
        case .badJSON: return "badJSON"
        case .unsupportedVersion: return "unsupportedVersion"
        case .badField: return "badField"
        case .expired: return "expired"
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingFragment:
            return "The pairing link has no #p= part."
        case .badBase64:
            return "The pairing link's #p= part is not base64url without padding."
        case .badJSON:
            return "The pairing link's #p= part is not a pairing object in UTF-8 JSON."
        case .unsupportedVersion(let version):
            return "The pairing link is version \(version); this TBD reads version \(PairingLink.currentVersion)."
        case .badField(let field):
            return "The pairing link's \(field) field is not valid."
        case .expired:
            return "The pairing link has expired."
        }
    }
}
