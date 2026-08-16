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
    ///
    /// An `enum` field is the one type with a CLOSED value set, so a prefill
    /// is projected onto that set with `matchAllowedValue` rather than
    /// written in verbatim — a value outside `values` matches no `.tag(...)`
    /// in the sheet's `Picker` (the control renders blank even for a required
    /// field with a default) and the provider rejects it at `create` time.
    /// When nothing matches, the field falls back to its own `default`, and
    /// with no default it lands exactly where a prefill-less field would:
    /// blank. Never an invented selection.
    static func prefillStrings(fields: [ProviderCreateParamField], repoPrefill: String?) -> [String: String] {
        var values: [String: String] = [:]
        for field in fields where field.type != "bool" {
            guard field.name == "repo", let repoPrefill, !repoPrefill.isEmpty else {
                values[field.name] = field.defaultValue ?? ""
                continue
            }
            if field.type == "enum" {
                values[field.name] = matchAllowedValue(repoPrefill, in: field.values ?? [])
                    ?? field.defaultValue ?? ""
            } else {
                values[field.name] = repoPrefill
            }
        }
        return values
    }

    /// Projects `candidate` onto a field's declared `allowed` values, so a
    /// prefill derived from one naming convention can select the equivalent
    /// value declared in another. Returns the ALLOWED spelling (the provider
    /// validates against exactly what it declared), or nil when nothing
    /// matches.
    ///
    /// A deliberately short ladder — exact, then case-insensitive, then the
    /// last `/`-separated component of both sides. That third rung exists
    /// because the owner-qualified form is forced on the prefill side:
    /// `repoPrefill` is `RemoteRepoMatching.displayKey`, which is what a
    /// created session's `meta["repo"]` must match to resolve back into the
    /// repo section its `+` was clicked from — while a provider is free to
    /// declare its repos by short name. Comparing last components bridges it
    /// in both directions ("acme-org/acme-app" ↔ "acme-app").
    ///
    /// It stops there on purpose: no substring, prefix, or fuzzy rung, since
    /// a wrong guess silently creates the session in the wrong repo. For the
    /// same reason the last-component rung requires a UNIQUE hit — two
    /// allowed values sharing a last component are ambiguous, and ambiguity
    /// resolves to "no match" (the caller then falls back to the declared
    /// default) rather than to whichever happened to be listed first.
    static func matchAllowedValue(_ candidate: String, in allowed: [String]) -> String? {
        if allowed.contains(candidate) { return candidate }
        if let caseInsensitive = allowed.first(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
            return caseInsensitive
        }
        let candidateTail = lastPathComponent(candidate)
        guard !candidateTail.isEmpty else { return nil }
        let tailMatches = allowed.filter {
            lastPathComponent($0).caseInsensitiveCompare(candidateTail) == .orderedSame
        }
        return tailMatches.count == 1 ? tailMatches[0] : nil
    }

    /// The segment after the final `/` — "acme-org/acme-app" → "acme-app",
    /// "acme-app" → "acme-app".
    private static func lastPathComponent(_ value: String) -> String {
        value.split(separator: "/").last.map(String.init) ?? ""
    }

    /// Whether `RemoteCreateSheet` must render a standalone caption above a
    /// field of this type. `bool` and `enum` lower to a `Toggle`/`Picker`,
    /// which take a label and display it beside the control; every other
    /// type lowers to a `TextField`/`TextEditor`, which does not — a
    /// `TextField`'s title is only its PLACEHOLDER, and macOS hides that the
    /// moment the field has content. A prefilled `string`/`int` field
    /// therefore showed no label at all: three identical unlabeled boxes for
    /// "Session slug", "Branch" and "Command". `text` already had the
    /// caption; this generalizes it to the other text-shaped types instead
    /// of leaving it special-cased in one switch arm.
    static func rendersCaptionLabel(forType type: String) -> Bool {
        type != "bool" && type != "enum"
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
