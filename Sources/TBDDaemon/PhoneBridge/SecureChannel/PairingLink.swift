import Foundation

/// What the pairing QR code carries after the loader URL's `#`:
/// `<loaderURL>#p=<base64url(UTF-8 JSON)>`.
///
/// `room`, `secret` and `key` are 32 bytes each in base64url without padding:
/// the relay room ID, the one-time pairing secret (the Noise PSK) and the
/// laptop's X25519 public key. `exp` is the offer's expiry in unix seconds.
/// The loader parses the same format with the same rules, in the same order,
/// so both sides name the same error for the same link.
///
/// Parity contract: for every link text except those below, `parse` and the
/// loader's `parsePairingLink` return the same link or fail with the same
/// error code, and `phone/test-vectors/pairing-link.json` pins the cases.
/// Outside the contract, either side's answer is acceptable, because the
/// daemon never builds such a link:
/// - duplicate object keys (this decoder keeps the first, the loader the last);
/// - nesting depth within a few levels of 512;
/// - numbers whose decimal text differs from the IEEE-754 double they round
///   to in ways only one side observes, such as a nonzero number too small
///   for a double, which this decoder refuses and the loader reads as 0;
/// - JSON that this decoder accepts and the loader's `JSON.parse` refuses:
///   one trailing comma before a `}` or `]`, and anything malformed inside
///   the value of a key the link does not define (a lone surrogate, an
///   unknown escape, a raw control character, or a misspelled number such
///   as `01` or `1.`), because this decoder checks only the values it reads;
/// - link text with surrounding whitespace, or a tab or line break inside
///   it, which the loader drops before parsing and `URL(string:)`
///   percent-encodes.
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
    /// The longest relay host name, as in DNS.
    private static let maxRelayHostBytes = 253
    private static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

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
    /// several faults fails with the same error here and in the loader. See
    /// the parity contract on `PairingLink`.
    static func parse(_ url: URL, now: Date = Date()) throws -> PairingLink {
        guard let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedFragment,
              fragment.hasPrefix("p=") else {
            throw PairingLinkError.missingFragment
        }
        guard let payload = Base64URL.decode(String(fragment.dropFirst(2))) else {
            throw PairingLinkError.badBase64
        }
        let json = try jsonText(payload)
        let decoder = JSONDecoder()
        let probe: VersionProbe
        do {
            probe = try decoder.decode(VersionProbe.self, from: json)
        } catch {
            throw PairingLinkError.badJSON
        }
        let version = try wholeNumber(probe.v)
        guard version == currentVersion else {
            throw PairingLinkError.unsupportedVersion(version)
        }
        let wire: Wire
        do {
            wire = try decoder.decode(Wire.self, from: json)
        } catch {
            throw PairingLinkError.badJSON
        }
        let exp = try wholeNumber(wire.exp)
        let link = PairingLink(
            v: version,
            relay: wire.relay,
            room: wire.room,
            secret: wire.secret,
            key: wire.key,
            name: wire.name,
            exp: exp
        )
        try link.checkFields()
        guard now.timeIntervalSince1970 < Double(link.exp) else {
            throw PairingLinkError.expired
        }
        return link
    }

    /// The version alone, read first so that a newer format reports
    /// `unsupportedVersion` rather than whatever field it changed.
    private struct VersionProbe: Decodable {
        let v: Double
    }

    /// The link's JSON as the loader reads it: numbers as doubles, and
    /// unknown keys ignored.
    private struct Wire: Decodable {
        let v: Double
        let relay: String
        let room: String
        let secret: String
        let key: String
        let name: String
        let exp: Double
    }

    /// The payload as UTF-8 JSON text, under the loader's byte rules: no 00
    /// byte, at most one leading byte order mark, and strict UTF-8. Valid
    /// UTF-8 JSON never holds a raw 00 byte. Refusing one stops `JSONDecoder`
    /// reading the payload as UTF-16 or UTF-32, as it does when a 00
    /// byte is among its first four bytes. Its own byte order mark check
    /// would also skip a second mark, which the loader's `JSON.parse`
    /// refuses.
    private static func jsonText(_ payload: Data) throws -> Data {
        guard !payload.contains(0) else {
            throw PairingLinkError.badJSON
        }
        let text = payload.starts(with: byteOrderMark) ? payload.dropFirst(byteOrderMark.count) : payload
        guard !text.starts(with: byteOrderMark), String(validating: text, as: UTF8.self) != nil else {
            throw PairingLinkError.badJSON
        }
        return Data(text)
    }

    /// The loader reads every JSON number as a double, so `v` and `exp` are
    /// read as doubles here too. A value that is not a whole number is
    /// `badJSON`. One beyond `Int`'s range becomes `Int.max` or `Int.min`,
    /// which the checks that follow refuse, as the loader's do.
    private static func wholeNumber(_ value: Double) throws -> Int {
        guard value.isFinite, value == value.rounded() else {
            throw PairingLinkError.badJSON
        }
        return Int(exactly: value) ?? (value < 0 ? Int.min : Int.max)
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

    /// Whether the relay matches this grammar as a whole string, in lowercase
    /// ASCII only, with nothing after the host or port: no path, not even
    /// `/`, and no query, fragment or user info.
    ///
    /// - `https://` HOST [`:` PORT]
    /// - `http://localhost` [`:` PORT] or `http://127.0.0.1` [`:` PORT], for
    ///   a local test relay
    ///
    /// HOST is one or more labels joined by `.`, at most 253 bytes in all.
    /// Each label is 1 to 63 of `a-z`, `0-9` and `-`, neither starting nor
    /// ending with `-` and not starting with `xn--`. The last label starts
    /// with a letter, so a dotted IPv4 address is refused. PORT is 1 to 5
    /// digits with no leading zero, from 1 to 65535.
    ///
    /// The loader matches the same grammar with a regular expression. Neither
    /// side trims or lowercases the relay, so the caller gets it back as sent.
    private static func isAllowedRelay(_ relay: String) -> Bool {
        let bytes = Array(relay.utf8)
        let authority: ArraySlice<UInt8>
        let isSecure: Bool
        if bytes.starts(with: "https://".utf8) {
            authority = bytes.dropFirst("https://".utf8.count)
            isSecure = true
        } else if bytes.starts(with: "http://".utf8) {
            authority = bytes.dropFirst("http://".utf8.count)
            isSecure = false
        } else {
            return false
        }
        var host = authority
        if let colon = authority.firstIndex(of: UInt8(ascii: ":")) {
            guard isPort(authority[authority.index(after: colon)...]) else {
                return false
            }
            host = authority[..<colon]
        }
        if isSecure {
            return isHostName(host)
        }
        return host.elementsEqual("localhost".utf8) || host.elementsEqual("127.0.0.1".utf8)
    }

    /// 1 to 5 ASCII digits with no leading zero, from 1 to 65535.
    private static func isPort(_ digits: ArraySlice<UInt8>) -> Bool {
        guard (1...5).contains(digits.count),
              digits.first != UInt8(ascii: "0"),
              digits.allSatisfy({ isASCIIDigit($0) }) else {
            return false
        }
        let value = digits.reduce(0) { $0 * 10 + Int($1 - UInt8(ascii: "0")) }
        return value <= 65_535
    }

    private static func isHostName(_ host: ArraySlice<UInt8>) -> Bool {
        let labels = host.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
        guard host.count <= maxRelayHostBytes,
              let lastLabel = labels.last,
              let lastLabelStart = lastLabel.first,
              isLowercaseLetter(lastLabelStart) else {
            return false
        }
        return labels.allSatisfy { isHostLabel($0) }
    }

    private static func isHostLabel(_ label: ArraySlice<UInt8>) -> Bool {
        guard (1...63).contains(label.count),
              label.first != UInt8(ascii: "-"),
              label.last != UInt8(ascii: "-"),
              !label.starts(with: "xn--".utf8) else {
            return false
        }
        return label.allSatisfy { isLowercaseLetter($0) || isASCIIDigit($0) || $0 == UInt8(ascii: "-") }
    }

    private static func isLowercaseLetter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
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
