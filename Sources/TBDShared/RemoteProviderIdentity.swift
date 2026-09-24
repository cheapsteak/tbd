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
/// TBD's side of the process boundary. The registry entry's own argv is
/// user-authored and outside the contract's reach altogether, so it gets the
/// stricter positional rule in `redactArguments` instead of this key filter.
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

    public static func isSecretKey(_ key: String) -> Bool {
        let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
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

    /// A registry entry's argv, safe to show: the first argument, and one
    /// `redactedPlaceholder` for every argument after it.
    ///
    /// Positional, not a judgement of what a secret looks like. No argv rule
    /// can decide in general whether `--env x` or `-Xk3mZ9…` is a value or a
    /// credential, and every heuristic that tried was one argument shape away
    /// from a leak. What this line is for — telling two registrations apart —
    /// the registry key already does, and "which backend is this pointed at"
    /// is `describe.identity`'s job, so the argv display is a convenience and
    /// a leak is its only real cost. `TmuxManager.redactedArguments` takes the
    /// same stance for tmux argv: a structural rule, never a scan for shapes.
    ///
    /// The first argument is judged by one exhaustive rule, never by what
    /// its content looks like:
    ///
    /// - With an `=` (`--token=abc`, `-Dkey=value`, `TOKEN=abc`), the part
    ///   before the first `=` is kept and everything after it is redacted.
    /// - Otherwise, starting with `-`, it is redacted whole — `--verbose`,
    ///   `-t`, and `--tokenSECRET` alike, since a value can be glued onto a
    ///   flag of any length and hiding a harmless flag costs only context.
    /// - Otherwise it is shown verbatim: a subcommand or a path.
    ///
    /// The one residual is a bare credential in first position with no flag
    /// or `=` before it.
    ///
    /// Never used to decide anything; the result is display text only.
    public static func redactArguments(_ args: [String]) -> [String] {
        guard let first = args.first else { return [] }
        let rest = Array(repeating: redactedPlaceholder, count: args.count - 1)
        return [redactedFirstArgument(first)] + rest
    }

    /// `arg` as the first argument renders; see `redactArguments` for the
    /// rule.
    private static func redactedFirstArgument(_ arg: String) -> String {
        if let separator = arg.firstIndex(of: "=") {
            return "\(arg[arg.startIndex..<separator])=\(redactedPlaceholder)"
        }
        if arg.hasPrefix("-") { return redactedPlaceholder }
        return arg
    }
}
