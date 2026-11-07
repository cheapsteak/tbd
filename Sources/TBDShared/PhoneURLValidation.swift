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
/// the port. `relay` also drops trailing slashes, because the bridge appends
/// `/v1/...` to it, and `https://acme.example/` would otherwise become
/// `https://acme.example//v1/...`, which the relay answers with a 404.
public enum PhoneURLValidation {
    public enum Failure: Error, Equatable, LocalizedError {
        case notAURL
        case unsupportedScheme
        case noHost
        case hasQuery
        case hasFragment

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
            }
        }
    }

    /// The relay URL, normalized: no query, no fragment, no trailing slash.
    public static func relay(_ raw: String) throws -> URL {
        var parts = try checkedComponents(raw)
        guard parts.percentEncodedQuery == nil else { throw Failure.hasQuery }
        guard parts.percentEncodedFragment == nil else { throw Failure.hasFragment }
        var path = parts.percentEncodedPath
        while path.hasSuffix("/") {
            path.removeLast()
        }
        if path != parts.percentEncodedPath {
            parts.percentEncodedPath = path
        }
        guard let url = parts.url else { throw Failure.notAURL }
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
