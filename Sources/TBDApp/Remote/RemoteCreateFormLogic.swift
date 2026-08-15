import Foundation
import TBDShared

/// Pure logic behind `RemoteCreateSheet`: prefilling the generic create-form
/// fields `describe.create_params` describes, and validating + assembling
/// them into the `paramsJSON` string `DaemonClient.remoteCreate` sends.
/// Deliberately dumb per the contract's own framing (`docs/remote-provider-contract.md`
/// § `describe`): "the caller renders this generically ... and only does
/// required/type checks client-side — the provider is the validator of
/// record". No SwiftUI here, so every branch is directly unit-testable.
enum RemoteCreateFormLogic {
    /// A field failed local validation. Carries the field's raw `name` (the
    /// key the provider knows it by), so the view can look up its `label`
    /// for display.
    enum FieldError: LocalizedError, Equatable {
        case missingRequired(fieldName: String)
        case invalidInt(fieldName: String)

        var errorDescription: String? {
            switch self {
            case .missingRequired(let fieldName):
                return "\(fieldName) is required"
            case .invalidInt(let fieldName):
                return "\(fieldName) must be a whole number"
            }
        }
    }

    /// Derives the `repo` create-param prefill from a repo's `remoteURL`,
    /// using `RemoteRepoMatching.displayKey` — the SAME segment parsing
    /// `normalizedKey` uses to resolve a session's `meta["repo"]` back to a
    /// local repo, so a session created with this prefill still round-trips
    /// into the very repo section its `+` button was clicked from (matching
    /// stays case-insensitive on both sides). Unlike `normalizedKey`,
    /// `displayKey` preserves the repo's original casing ("Acme/API" prefills
    /// as "Acme/API", not "acme/api") — a provider that clones against a
    /// case-sensitive host needs what's actually sent to be the real casing,
    /// not the lowercase comparison key. Returns nil when there's no ambient
    /// repo (the sheet was opened from the Remote section header, not a
    /// repo) or the repo has no parseable remote URL.
    static func repoPrefill(remoteURL: String?) -> String? {
        guard let remoteURL else { return nil }
        return RemoteRepoMatching.displayKey(remoteURL)
    }

    /// Seeds initial string-typed field values (every type except `bool`):
    /// the well-known `repo` field gets `repoPrefill` when present and
    /// non-blank (docs/remote-provider-contract.md § `describe` — `repo` is
    /// a well-known field name a caller may prefill from ambient context);
    /// every other field falls back to its own `default`; everything else
    /// (including `title`, which has no ambient source) starts blank.
    static func prefillStrings(fields: [ProviderCreateParamField], repoPrefill: String?) -> [String: String] {
        var values: [String: String] = [:]
        for field in fields where field.type != "bool" {
            if field.name == "repo", let repoPrefill, !repoPrefill.isEmpty {
                values[field.name] = repoPrefill
            } else {
                values[field.name] = field.defaultValue ?? ""
            }
        }
        return values
    }

    /// Seeds initial bool-typed field values from `default` ("true"/"false"
    /// as a string, matching how every other field's default is carried on
    /// the wire); any other/missing value defaults to `false`.
    static func prefillBools(fields: [ProviderCreateParamField]) -> [String: Bool] {
        var values: [String: Bool] = [:]
        for field in fields where field.type == "bool" {
            values[field.name] = field.defaultValue == "true"
        }
        return values
    }

    /// Validates and assembles the create-form values into the JSON object
    /// string `remote.create` expects as `paramsJSON`. Fields are checked in
    /// `fields` order, so the first offending field is the one reported.
    ///
    /// - `required` only applies to non-bool fields — a bool/checkbox always
    ///   has a value (`false` is a real, valid answer, not "missing").
    /// - A blank, non-required field (including a blank `int`) is OMITTED
    ///   from the object entirely — never sent as `""`/`0`/`null` — so the
    ///   provider's own default applies server-side.
    /// - An `int` field is parsed with `Int(_:)`; a non-blank value that
    ///   doesn't parse is `.invalidInt`, checked BEFORE the field is written,
    ///   so a bad value never reaches the request.
    static func buildParamsJSON(
        fields: [ProviderCreateParamField],
        stringValues: [String: String],
        boolValues: [String: Bool]
    ) -> Result<String, FieldError> {
        var object: [String: Any] = [:]
        for field in fields {
            if field.type == "bool" {
                object[field.name] = boolValues[field.name] ?? false
                continue
            }
            let raw = (stringValues[field.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty {
                if field.required { return .failure(.missingRequired(fieldName: field.name)) }
                continue
            }
            if field.type == "int" {
                guard let intValue = Int(raw) else { return .failure(.invalidInt(fieldName: field.name)) }
                object[field.name] = intValue
            } else {
                object[field.name] = raw
            }
        }
        // Every value placed into `object` above is a JSON-safe primitive
        // (String/Int/Bool), so `JSONSerialization` always emits valid UTF-8
        // — unlike `remote.log`'s raw provider bytes, there's no lossy
        // passthrough concern here, so the failable `String(data:encoding:)`
        // initializer (not `String(decoding:as:)`) is both correct and what
        // the lint rule wants. Either failure mode (bad object shape, or
        // somehow-non-UTF8 data) falls back to an empty object rather than
        // force-unwrapping.
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8) else {
            return .success("{}")
        }
        return .success(json)
    }
}
