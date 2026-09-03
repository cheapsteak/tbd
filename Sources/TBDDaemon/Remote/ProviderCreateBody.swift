import Foundation

/// Composes the JSON body TBD writes to a provider's `create` stdin
/// (`docs/remote-provider-contract.md` § `create`).
///
/// One composer, two callers: `remote.create` and the seeded create behind
/// Revive-as-reseed (`RemoteLaneLifecycle+Actuate`). They must agree about
/// where `seed` sits and about how an opaque key is escaped, and the way to
/// make two callers agree is to give them one function rather than two
/// implementations that look alike today.
///
/// The body is assembled as **text rather than encoded**, deliberately.
/// `paramsJSON` is a caller-supplied JSON object that the contract has TBD pass
/// through verbatim: decoding and re-encoding it would rewrite the caller's own
/// object — key order, number spelling, whitespace — for no gain, and would
/// give TBD an opinion about a structure it is explicitly not supposed to
/// interpret. Everything else in the body is escaped properly on the way in.
enum ProviderCreateBody {
    /// `create`'s stdin.
    ///
    /// - Parameters:
    ///   - paramsJSON: the provider-defined `params` object, already validated
    ///     as a JSON object by the caller and spliced through untouched.
    ///   - seedRetainedKey: the retained transcript the new session begins
    ///     with, or nil to send no `seed` field at all. **Nil omits the key
    ///     rather than emitting `null`** — a provider reading `"seed": null`
    ///     would have to decide what an explicit nothing means, and the
    ///     contract never asks it to.
    ///   - idempotencyKey: the dedupe token, minted by the caller so a retry
    ///     can reuse the same one.
    ///
    /// `seed` is a top-level sibling of `params` and `idempotency_key`, never a
    /// member of `params` — `params` is the provider's own free-form set, where
    /// a contract field would be indistinguishable from a provider-defined one.
    static func compose(
        paramsJSON: String, seedRetainedKey: String?, idempotencyKey: String
    ) -> String {
        var seedField = ""
        if let seedRetainedKey {
            seedField = #", "seed": {"retained_key": \#(jsonStringLiteral(seedRetainedKey))}"#
        }
        return #"{"params": \#(paramsJSON)\#(seedField), "idempotency_key": \#(jsonStringLiteral(idempotencyKey))}"#
    }

    /// A JSON string literal — quotes and escaping included — for a value
    /// spliced into the hand-composed body above.
    ///
    /// Load-bearing for the seed key specifically. A retained key is opaque:
    /// the contract forbids a caller from parsing, constructing or
    /// pattern-matching one, so it may perfectly well contain a quote, a
    /// backslash or a newline. Interpolated raw, such a key produces a
    /// malformed request the provider rejects with no indication of why.
    ///
    /// `JSONSerialization` needs a top-level container, so the value goes in as
    /// a one-element array and the brackets come off. The fallback is an empty
    /// literal, which the provider rejects as an unknown key — a failure a
    /// caller can act on, rather than a broken body.
    static func jsonStringLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let text = String(bytes: data, encoding: .utf8),
              text.count >= 2 else {
            return "\"\""
        }
        return String(text.dropFirst().dropLast())
    }

    /// A `params` object built from a `[String: String]` map of provider field
    /// names to values — the shape TBD's stored create-param defaults take
    /// (`Config.remoteCreateDefaults`, `Repo.remoteCreateDefaults`).
    ///
    /// Blank values are dropped rather than sent as empty strings: an omitted
    /// optional field lets the provider apply its own answer, while an empty
    /// string is a value, and a provider that validates its fields would
    /// reject one. Keys are sorted so the same map always composes the same
    /// body, which is what makes a composed body assertable in a test.
    static func paramsJSON(from values: [String: String]) -> String {
        let filtered = values.filter {
            !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard let data = try? JSONSerialization.data(
                withJSONObject: filtered, options: [.sortedKeys]),
              let text = String(bytes: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
