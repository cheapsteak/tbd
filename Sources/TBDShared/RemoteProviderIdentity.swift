import Foundation

// MARK: - Lenient display scalars

/// One value from a provider-defined display map, decoded down to the string
/// a display map can show. `literal` is nil for anything with no unambiguous
/// literal form — an object, an array, or an explicit null.
///
/// Shared by the two flat string-to-string maps the provider contract
/// defines: the Session object's `meta` and `describe`'s `identity`. Both
/// carry provider-chosen display pairs, and both degrade the same way, so
/// they coerce the same way from one implementation rather than two that can
/// drift.
struct LenientDisplayScalar: Decodable {
    let literal: String?

    init(from decoder: any Decoder) throws {
        guard let c = try? decoder.singleValueContainer(), !c.decodeNil() else {
            literal = nil
            return
        }
        if let s = try? c.decode(String.self) { literal = s; return }
        if let b = try? c.decode(Bool.self) { literal = b ? "true" : "false"; return }
        // Int before Double so a whole number reads as `42`, not `42.0`.
        if let i = try? c.decode(Int.self) { literal = String(i); return }
        if let d = try? c.decode(Double.self) { literal = String(d); return }
        literal = nil
    }
}

// MARK: - Provider identity

/// `describe.identity` — the non-secret display identity of the BACKEND a
/// registry entry is pointed at (`docs/remote-provider-contract.md` §
/// `describe`).
///
/// TBD cannot derive this itself. A registry entry is an executable path and
/// a flag list, and the mapping from those flags to a control plane is the
/// provider's private business — which is exactly why two entries running the
/// same binary against different backends are indistinguishable to a caller
/// that only reads `describe.name`. This field is what closes that gap.
///
/// A flat string-to-string map with a well-known key ORDER, not a schema:
/// every vendor's notion of identity has a different shape, and a fixed set
/// of typed fields forces a provider to either leave them empty or stretch
/// them. TBD interprets nothing here beyond the ordering — the values are
/// display text, on the same terms as the Session object's `meta`.
public struct ProviderIdentity: Codable, Sendable, Equatable {
    /// Every pair the provider sent that survived decoding, unredacted and
    /// unordered. Callers that DISPLAY these must go through
    /// `displayPairs` rather than reading this directly — it applies the
    /// secret filter.
    public let pairs: [String: String]

    /// Keys TBD knows how to order, most identifying first. Everything else
    /// sorts alphabetically after them. Order only — no key here is
    /// interpreted, required, or given special rendering.
    public static let wellKnownKeyOrder: [String] = [
        "account", "environment", "region", "box", "host", "endpoint",
    ]

    public init(pairs: [String: String]) {
        self.pairs = pairs
    }

    /// Decoded leniently and never fatally, exactly like `meta`: a value with
    /// no literal form costs its own key and nothing else, and an `identity`
    /// that is not an object at all costs the whole map rather than the
    /// `describe` response that carries it. A provider's identity block is
    /// display sugar — it must never be able to stop TBD from registering the
    /// provider.
    public init(from decoder: any Decoder) throws {
        let raw = try [String: LenientDisplayScalar](from: decoder)
        var kept: [String: String] = [:]
        for (key, value) in raw {
            if let literal = value.literal { kept[key] = literal }
        }
        pairs = kept
    }

    public func encode(to encoder: any Encoder) throws {
        try pairs.encode(to: encoder)
    }

    /// The pairs as they may be shown: secret-looking keys dropped, values
    /// truncated, well-known keys first and the rest alphabetical.
    public var displayPairs: [ProviderIdentityPair] {
        let safe = ProviderIdentityRedaction.filter(pairs)
        let wellKnown = Self.wellKnownKeyOrder.compactMap { key -> ProviderIdentityPair? in
            guard let value = safe[key] else { return nil }
            return ProviderIdentityPair(key: key, value: value)
        }
        let rest = safe.keys
            .filter { !Self.wellKnownKeyOrder.contains($0) }
            .sorted()
            .map { ProviderIdentityPair(key: $0, value: safe[$0] ?? "") }
        return wellKnown + rest
    }

    /// Whether there is anything at all to show after redaction — the gate a
    /// view uses to decide between an identity block and nothing.
    public var hasDisplayablePairs: Bool { !displayPairs.isEmpty }
}

/// One identity pair as it reaches a view: already filtered and ordered by
/// `ProviderIdentity.displayPairs`. A named type rather than a tuple so a
/// `ForEach` can key on it directly.
public struct ProviderIdentityPair: Sendable, Equatable, Identifiable {
    public let key: String
    public let value: String
    public var id: String { key }

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// What TBD refuses to put on screen from provider- or user-authored text.
///
/// The contract already says `describe.identity` carries display identity and
/// never credential material, and this filter does not exist because that
/// rule is doubted — it exists because the rule cannot be enforced from
/// TBD's side of the process boundary, and because the SAME filter runs over
/// the registry entry's own argv, which is user-authored and outside the
/// contract's reach altogether.
///
/// Fail-safe by design: a key is dropped on a substring match, so `monkey`
/// loses to `key`. Losing a display pair costs one line of context; showing a
/// bearer token costs the token.
public enum ProviderIdentityRedaction {
    /// Substrings that make a key secret-bearing. Matched against the key
    /// lowercased and stripped of separators, so `AWS_Session-Token` and
    /// `awssessiontoken` are the same key to this check.
    public static let secretKeySubstrings: [String] = [
        "token", "secret", "password", "passwd", "credential", "cred",
        "signature", "cookie", "auth", "key",
    ]

    // `session` is deliberately NOT in that list, though `session_token` is a
    // real secret shape: this domain calls its ordinary, non-secret unit of
    // work a session, and a filter that drops every key containing the word
    // would redact the identity it exists to show. `token` already covers the
    // secret-bearing compound.

    /// The longest a rendered identity value may be. Identity values are
    /// account ids, region names, and box handles; anything longer is either
    /// not identity or not readable, and truncating bounds the damage from
    /// both.
    public static let maximumValueLength = 96

    /// What a redacted value renders as. Deliberately not the value's own
    /// prefix: a prefix of a secret is still a piece of a secret.
    public static let redactedPlaceholder = "‹redacted›"

    /// Single-letter short-flag aliases that conventionally take a credential
    /// as their value, matched EXACTLY (never as a substring — `t` alone
    /// would otherwise swallow every flag with a `t` anywhere in it, like
    /// `--format`). `secretKeySubstrings` above can never catch these: a
    /// one-letter flag can't contain a five-letter word. Deliberately short
    /// and reviewer-named rather than exhaustive — `-p` in particular
    /// collides with "port"/"profile" in plenty of real CLIs, but per this
    /// type's own bias (a lost display pair costs a line of context; a shown
    /// secret costs the secret), redacting an occasional port number is the
    /// correct side to be wrong on.
    public static let shortSecretFlagAliases: Set<String> = ["t", "p", "k"]

    public static func isSecretKey(_ key: String) -> Bool {
        let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
        if shortSecretFlagAliases.contains(normalized) { return true }
        return secretKeySubstrings.contains { normalized.contains($0) }
    }

    /// `value` bounded to `maximumValueLength`, with an ellipsis marking that
    /// it was cut. Never used to shorten a secret — a secret-keyed pair is
    /// dropped, not truncated.
    public static func truncated(_ value: String) -> String {
        guard value.count > maximumValueLength else { return value }
        return String(value.prefix(maximumValueLength)) + "…"
    }

    /// Display pairs with secret-keyed entries removed and the rest bounded.
    public static func filter(_ pairs: [String: String]) -> [String: String] {
        var kept: [String: String] = [:]
        for (key, value) in pairs where !isSecretKey(key) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            kept[key] = truncated(trimmed)
        }
        return kept
    }

    /// A registry entry's argv, safe to show.
    ///
    /// Three shapes carry a secret on a command line, and all are handled:
    /// `--token=abc` (the value rides the same argument as the flag),
    /// `--token abc` (the value is the NEXT argument), and a bare positional
    /// argument that looks like a secret (no preceding flag, but the argument
    /// itself has characteristics of a token or API key). The second and third
    /// are why this takes the whole list — an argument is only judged in the
    /// company of what precedes it and in its own characteristics.
    ///
    /// For bare positional arguments, detection is heuristic: well-known secret
    /// prefixes (e.g. `sk-`, `github_pat_`, `AKIA`) are redacted immediately,
    /// and other arguments are redacted if they are long and high-entropy
    /// enough to plausibly be a token. The heuristic is conservative (biased
    /// toward redacting) to avoid leaking real credentials. Ordinary short
    /// identifiers, paths, branch names, port numbers, and semver strings are
    /// not redacted.
    ///
    /// Never used to decide anything; the result is display text only.
    public static func redactArguments(_ args: [String]) -> [String] {
        var out: [String] = []
        var redactNext = false
        for arg in args {
            if redactNext {
                redactNext = false
                // A flag never counts as the previous flag's value: `--token
                // --verbose` means the token was simply not supplied here.
                if arg.hasPrefix("-") {
                    out.append(arg)
                    continue
                }
                out.append(redactedPlaceholder)
                continue
            }
            if let separator = arg.firstIndex(of: "="), arg.hasPrefix("-") {
                let flag = String(arg[arg.startIndex..<separator])
                if isSecretKey(flag) {
                    out.append("\(flag)=\(redactedPlaceholder)")
                    continue
                }
                // The flag name itself isn't a recognized secret key
                // (--bearer=…, --pat=…), but the bare-positional and
                // space-separated shapes below both still judge an
                // unrecognized value on its own merits — this shape must
                // too, or a secret-shaped value only ever escapes redaction
                // by riding an `=`. The flag name is never itself
                // secret-shaped, so only the value is checked.
                let value = String(arg[arg.index(after: separator)...])
                if looksLikeSecret(value) {
                    out.append("\(flag)=\(redactedPlaceholder)")
                    continue
                }
                out.append(arg)
                continue
            }
            if arg.hasPrefix("-"), isSecretKey(arg) {
                out.append(arg)
                redactNext = true
                continue
            }
            // Third shape: a BARE POSITIONAL argument that looks like a
            // secret — never one that starts with `-`. An argument this
            // point is reached for already failed the known-secret-flag
            // check above, so a dash-prefixed one here is an ordinary flag
            // this registry entry happens to pass (`--use-http2-multiplexing`
            // is exactly this shape: long, has a digit, no reason to hide
            // it). Excluding it is what keeps this heuristic scoped to
            // values, matching its own doc comment.
            if !arg.hasPrefix("-"), looksLikeSecret(arg) {
                out.append(redactedPlaceholder)
                continue
            }
            out.append(arg)
        }
        return out
    }

    /// Returns true if a bare positional argument has characteristics that
    /// suggest it is a secret (token, API key, etc.).
    ///
    /// Matches well-known secret prefixes (case-sensitive) first, then falls
    /// back to heuristics for unknown secrets: length, entropy, and character
    /// composition. Conservative (biased toward redacting) to avoid leaking
    /// real credentials; false positives cost only display clarity.
    ///
    /// Does not redact: short words, paths (starting with / or ~), pure
    /// lowercase alphabetic strings under ~20 characters, plain numbers,
    /// semver-looking strings, or UUIDs. UUIDs are not credentials by nature,
    /// so they are identified and skipped explicitly.
    private static func looksLikeSecret(_ arg: String) -> Bool {
        // Well-known secret prefixes (case-sensitive). These are strong signals
        // that an argument is a credential, regardless of length or composition.
        let knownSecretPrefixes = [
            "sk-",         // Stripe secret key
            "sk_live_",    // Stripe live secret
            "sk_test_",    // Stripe test secret
            "ghp_",        // GitHub personal access token
            "gho_",        // GitHub OAuth token
            "ghs_",        // GitHub server-to-server token
            "ghu_",        // GitHub user-to-server token
            "ghr_",        // GitHub refresh token
            "github_pat_", // GitHub PAT (alternative form)
            "xoxb-",       // Slack bot token
            "xoxp-",       // Slack user token
            "xoxa-",       // Slack app token
            "xoxr-",       // Slack refresh token
            "xoxs-",       // Slack xoxs token
            "AKIA",        // AWS access key ID
            "eyJ",         // JWT (base64url header typically starts with eyJ)
        ]

        for prefix in knownSecretPrefixes {
            if arg.hasPrefix(prefix) {
                return true
            }
        }

        // Fallback heuristic for unknown secrets. Be conservative.
        // A secret typically: is long, contains a mix of letters and digits,
        // and does not have excessive repetition or look like a normal identifier.

        // Skip short words and common short identifiers
        if arg.count < 20 {
            return false // Argument is too short to plausibly be a secret
        }

        // An implausibly long argument is more likely a path, a pasted
        // document, or free-form text than a token, so it skips the rest of
        // the heuristic entirely rather than being judged by it.
        if arg.count > 500 {
            return false // Likely a path or document, not a secret
        }

        // Paths should never be redacted
        if arg.hasPrefix("/") || arg.hasPrefix("~") {
            return false
        }

        // UUIDs are not credentials and should not be redacted. They have a
        // distinctive pattern: XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX where X is
        // a hex digit. While they satisfy the "high entropy" heuristic, they are
        // legitimate identifiers, not secrets. Identify via pattern: exactly 36
        // chars, 4 internal dashes at positions 8, 13, 18, 23, and all other
        // chars are hex digits.
        if arg.count == 36 && isUUIDPattern(arg) {
            return false
        }

        // Check for basic entropy: needs both letters and digits
        let hasLetter = arg.contains { $0.isLetter }
        let hasDigit = arg.contains { $0.isNumber }

        // At least one letter and one digit suggests random composition
        if !hasLetter || !hasDigit {
            return false
        }

        // Check for no excessive repetition of the same character
        // (tokens often have varied content; padding or repetition suggests otherwise)
        var maxConsecutive = 1
        var lastChar: Character? = nil
        var consecutiveCount = 1
        for char in arg {
            if char == lastChar {
                consecutiveCount += 1
                maxConsecutive = max(maxConsecutive, consecutiveCount)
            } else {
                consecutiveCount = 1
                lastChar = char
            }
        }

        // If more than 5 consecutive identical characters, probably not a secret
        // (e.g. "aaaaaaa" or "111111" looks more like padding or bad input)
        if maxConsecutive > 5 {
            return false
        }

        // Semver-style version strings (X.Y.Z) are the one common dotted,
        // long, letter-and-digit-bearing shape that isn't a secret — but
        // several real dot-segmented token formats are just as dotted and
        // must NOT get the same pass: a Discord bot token
        // (`id.timestamp.hmac`) and a PASETO token (`v2.local.payload`)
        // both carry 2+ dots with no known prefix. The distinguishing
        // property is that every segment of a real version string is
        // digits-only (optionally with a leading "v"); a token's segments
        // are base64/hex-ish and contain letters a version segment never
        // does. So the carve-out checks segment shape, not just dot count.
        if isVersionLike(arg) {
            return false
        }

        // At this point: 20+ chars, has letters and digits, no excessive repetition,
        // not a UUID, not a version string. Looks like a plausible secret.
        return true
    }

    /// Whether `arg` is shaped like a semantic-version string: at least two
    /// dot-separated segments, every one of them numeric once an optional
    /// leading `v`/`V` is stripped from the first. Deliberately stricter than
    /// "contains dots" — see the comment at its call site for the dotted
    /// secret formats that distinction exists to keep unredacted.
    private static func isVersionLike(_ arg: String) -> Bool {
        var segments = arg.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return false }
        if let first = segments.first, first.hasPrefix("v") || first.hasPrefix("V") {
            segments[0] = first.dropFirst()
        }
        return segments.allSatisfy { segment in
            !segment.isEmpty && segment.allSatisfy(\.isNumber)
        }
    }

    /// Returns true if the argument looks like a UUID pattern
    /// (XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX, where X is a hex digit).
    private static func isUUIDPattern(_ arg: String) -> Bool {
        let chars = Array(arg)
        guard chars.count == 36 else { return false }

        // Dashes at positions 8, 13, 18, 23 (0-indexed)
        let dashPositions = [8, 13, 18, 23]
        for pos in dashPositions {
            guard chars[pos] == "-" else { return false }
        }

        // All other characters must be hex digits (0-9, a-f, A-F)
        for (index, char) in chars.enumerated() {
            if dashPositions.contains(index) {
                continue // Already checked dashes
            }
            guard char.isHexDigit else { return false }
        }

        return true
    }
}
