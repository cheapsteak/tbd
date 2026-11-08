import Foundation

/// The rules for the relay and loader URLs a user pastes into the Phone pane.
///
/// Phone traffic is end-to-end encrypted, but a cleartext connection would
/// still show it to anyone on the network, and would let them replace the
/// loader, the code that holds a phone's keys. So both URLs must use `https`.
/// Plain `http` is allowed only for a test server on this Mac, at `localhost`
/// or `127.0.0.1`.
///
/// Both functions trim whitespace, lowercase the scheme and the host, and keep
/// the port. The relay address goes into every pairing link, and the pairing
/// link's relay rule (`PairingLink` in the daemon, `pairingLink.js` in the
/// loader) takes a scheme, a host and a port and nothing else. So `relay`
/// accepts exactly the addresses that rule accepts, once it has trimmed,
/// lowercased and dropped one trailing `/`; a QR code is never built for a
/// relay the phone would refuse.
public enum PhoneURLValidation {
    public enum Failure: Error, Equatable, LocalizedError {
        case notAURL
        case unsupportedScheme
        case noHost
        case hasQuery
        case hasFragment
        case hasPath
        case hasUserInfo
        case badHost
        case badPort

        public var errorDescription: String? {
            switch self {
            case .notAURL:
                return "That is not a web address. Enter the full address, starting with https://."
            case .unsupportedScheme:
                return "The address must start with https://. Only a test server on this Mac "
                    + "(localhost or 127.0.0.1) may use http://."
            case .noHost:
                return "The address has no server name. Enter the full address, "
                    + "such as https://acme-relay.acme.workers.dev."
            case .hasQuery:
                return "The address must not include a query (a ? and what follows it). Remove it."
            case .hasFragment:
                return "The address must not include a fragment (a # and what follows it). Remove it."
            case .hasPath:
                return "A relay address has no path. Use just its https:// address, "
                    + "such as https://acme-relay.acme.workers.dev."
            case .hasUserInfo:
                return "The address must not include a user name or password (the part before an @). Remove it."
            case .badHost:
                return "The server name must be a domain name made of the letters a to z, digits, hyphens "
                    + "and dots, such as acme-relay.acme.workers.dev. An IP address or an international "
                    + "name can't be used."
            case .badPort:
                return "The port must be a number from 1 to 65535 with no leading zero, such as :8787."
            }
        }
    }

    /// The relay address in the form a pairing link carries: `https://` HOST
    /// [`:` PORT], or `http://localhost` or `http://127.0.0.1` with an
    /// optional port, all in lowercase, with no path, not even `/`.
    ///
    /// HOST is one or more labels joined by `.`, at most 253 bytes in all.
    /// Each label is 1 to 63 of `a-z`, `0-9` and `-`, neither starting nor
    /// ending with `-` and not starting with `xn--`. The last label starts
    /// with a letter, so a dotted IPv4 address is refused. PORT is 1 to 5
    /// digits with no leading zero, from 1 to 65535. This is the daemon's
    /// `PairingLink` relay rule; a daemon test checks the two agree.
    public static func relay(_ raw: String) throws -> URL {
        let parts = try checkedComponents(raw)
        guard parts.percentEncodedQuery == nil else { throw Failure.hasQuery }
        guard parts.percentEncodedFragment == nil else { throw Failure.hasFragment }
        guard parts.percentEncodedUser == nil, parts.percentEncodedPassword == nil else {
            throw Failure.hasUserInfo
        }
        guard parts.percentEncodedPath.isEmpty || parts.percentEncodedPath == "/" else {
            throw Failure.hasPath
        }
        let address = try relayAddress(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let url = URL(string: address) else { throw Failure.notAURL }
        return url
    }

    /// The loader URL, normalized, with its path kept as given. It may not
    /// carry a fragment, because the pairing link puts its own after the `#`.
    public static func loader(_ raw: String) throws -> URL {
        let parts = try checkedComponents(raw)
        guard parts.percentEncodedFragment == nil else { throw Failure.hasFragment }
        guard let url = parts.url else { throw Failure.notAURL }
        return url
    }

    private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1"]

    /// `raw`, trimmed and parsed, with an allowed scheme and a host, both
    /// lowercased.
    private static func checkedComponents(_ raw: String) throws -> URLComponents {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // The scheme is read before Foundation parses anything: a string with
        // no scheme is no URL here, even though Foundation reads one such as
        // "acme.example" as a relative path.
        guard let scheme = Self.scheme(of: trimmed) else { throw Failure.notAURL }
        guard scheme == "https" || scheme == "http" else { throw Failure.unsupportedScheme }
        guard var parts = URLComponents(string: trimmed) else {
            // Foundation may refuse an empty authority ("https://") outright;
            // that is still a missing host.
            throw Self.hasEmptyAuthority(trimmed) ? Failure.noHost : Failure.notAURL
        }
        let originalHost = parts.encodedHost ?? ""
        let host = originalHost.lowercased()
        // Plain http is checked first, so an http URL to anything but the two
        // loopback names, an IPv6 literal included, is refused for its scheme.
        guard scheme == "https" || loopbackHosts.contains(host) else { throw Failure.unsupportedScheme }
        guard !host.isEmpty else { throw Failure.noHost }
        if parts.scheme != scheme {
            parts.scheme = scheme
        }
        if host != originalHost {
            parts.encodedHost = host
        }
        return parts
    }

    /// `trimmed` rebuilt as `scheme://host[:port]` from its own text, with
    /// the scheme and host in lowercase, after the pairing link's relay rule
    /// accepts the host and port. `trimmed` has passed `checkedComponents`
    /// and has no user info, query, fragment, or path but `/`, so it is the
    /// scheme, `://`, the authority and at most one `/`. The port is read
    /// from the text, not from Foundation, so a leading zero or an empty port
    /// is refused rather than rewritten.
    private static func relayAddress(_ trimmed: String) throws -> String {
        guard let separator = trimmed.range(of: "://") else { throw Failure.noHost }
        let scheme = asciiLowercased(trimmed[..<separator.lowerBound])
        var authority = trimmed[separator.upperBound...]
        if authority.hasSuffix("/") {
            authority = authority.dropLast()
        }
        var hostText = authority
        var port: Substring?
        if let colon = authority.firstIndex(of: ":") {
            hostText = authority[..<colon]
            port = authority[authority.index(after: colon)...]
        }
        let host = asciiLowercased(hostText)
        switch scheme {
        case "https":
            guard isHostName(Array(host.utf8)) else { throw Failure.badHost }
        case "http":
            guard loopbackHosts.contains(host) else { throw Failure.unsupportedScheme }
        default:
            throw Failure.unsupportedScheme
        }
        var address = scheme + "://" + host
        if let port {
            guard isPort(Array(port.utf8)) else { throw Failure.badPort }
            address += ":" + String(port)
        }
        return address
    }

    /// `text` with only its ASCII letters lowercased, so no other character
    /// (a Kelvin sign, say) can lowercase into one the relay rule accepts.
    private static func asciiLowercased(_ text: Substring) -> String {
        text.map { $0.isASCII ? $0.lowercased() : String($0) }.joined()
    }

    /// The longest relay host name, as in DNS.
    private static let maxRelayHostBytes = 253

    /// Labels joined by `.`, the last starting with a letter; see `relay`.
    private static func isHostName(_ host: [UInt8]) -> Bool {
        let labels = host.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
        guard host.count <= maxRelayHostBytes,
              let lastLabelStart = labels.last?.first,
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

    /// 1 to 5 ASCII digits with no leading zero, from 1 to 65535.
    private static func isPort(_ digits: [UInt8]) -> Bool {
        guard (1...5).contains(digits.count),
              digits.first != UInt8(ascii: "0"),
              digits.allSatisfy({ isASCIIDigit($0) }) else {
            return false
        }
        let value = digits.reduce(0) { $0 * 10 + Int($1 - UInt8(ascii: "0")) }
        return value <= 65_535
    }

    private static func isLowercaseLetter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    /// The lowercased scheme: the letters, digits, `+`, `-` and `.` before the
    /// first `:`, starting with a letter (RFC 3986 section 3.1). Nil when there
    /// is none.
    private static func scheme(of string: String) -> String? {
        guard let colon = string.firstIndex(of: ":") else { return nil }
        let candidate = string[..<colon].lowercased()
        guard let first = candidate.first, schemeLetters.contains(first),
              candidate.allSatisfy({ schemeCharacters.contains($0) }) else { return nil }
        return candidate
    }

    private static let schemeLetters = Set("abcdefghijklmnopqrstuvwxyz")
    private static let schemeCharacters = schemeLetters.union("0123456789+-.")

    /// True for `<scheme>://` followed by nothing, or directly by a path,
    /// query or fragment.
    private static func hasEmptyAuthority(_ string: String) -> Bool {
        guard let range = string.range(of: "://") else { return false }
        let rest = string[range.upperBound...]
        return rest.first.map { "/?#".contains($0) } ?? true
    }
}
