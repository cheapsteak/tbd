import Foundation
import TBDShared

/// Pure logic behind starting a remote session: resolving the generic
/// create-form fields `describe.create_params` describes, deciding whether the
/// form needs to be shown at all, and validating + assembling the answers into
/// the `paramsJSON` string `DaemonClient.remoteCreate` sends.
///
/// Deliberately dumb per the contract's own framing (`docs/remote-provider-contract.md`
/// § `describe`): "the caller renders this generically ... and only does
/// required/type checks client-side — the provider is the validator of
/// record". No SwiftUI here, so every branch is directly unit-testable.
///
/// Three layers, each built on the one above it:
///
///  - `resolveString` / `prefillBools` — one field's value, resolved through
///    repo → ambient → global → the provider's own `default`.
///  - `plan` — every field resolved, plus which required ones are still
///    unanswered.
///  - `launch` — create outright, or open the form prefilled with what is
///    known. Creating on a guess is never an option.
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

    /// The well-known create-param naming the repository the session is
    /// created against (`docs/remote-provider-contract.md` § `describe`). It
    /// is the one field resolution treats as special — see `resolveString`.
    static let repoFieldName = "repo"

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

    /// Seeds initial string-typed field values (every type except `bool`) by
    /// walking the precedence chain in `resolveString(field:...)`. Every
    /// parameter past `repoPrefill` is defaulted, so a caller with no stored
    /// defaults and no generated slug gets exactly the ambient-prefill-only
    /// behavior this function has always had.
    static func prefillStrings(
        fields: [ProviderCreateParamField],
        repoPrefill: String?,
        repoDefaults: [String: String] = [:],
        globalDefaults: [String: String] = [:],
        generatedSlug: String? = nil
    ) -> [String: String] {
        var values: [String: String] = [:]
        for field in fields where field.type != "bool" {
            values[field.name] = resolveString(
                field: field, repoPrefill: repoPrefill, repoDefaults: repoDefaults,
                globalDefaults: globalDefaults, generatedSlug: generatedSlug)
        }
        return values
    }

    /// The value one non-bool field starts with, resolved through four levels
    /// and falling through wherever a level has no usable answer:
    ///
    ///  1. the repo's own stored default (`Repo.remoteCreateDefaults`)
    ///  2. an ambient **well-known** prefill (`ambientPrefill(for:...)`)
    ///  3. the machine-wide stored default (`Config.remoteCreateDefaults`)
    ///  4. the field's provider-declared `default`
    ///  5. blank
    ///
    /// The repo → global → provider spine mirrors the model-profile chain
    /// (`ModelProfileResolver.resolve`: repo override → global default →
    /// none). The ambient prefill sits INSIDE the repo tier rather than above
    /// or below the pair, because it is itself repo-scoped evidence — the user
    /// clicked this repo's `+` — so it must outrank a machine-wide value that
    /// cannot know which repo was clicked, while still yielding to a default
    /// stored against this very repo.
    ///
    /// **Blank is "no opinion", not an answer.** A whitespace-only value at any
    /// level falls through, so clearing a control (which writes `""` on some
    /// paths) reads the same as never having set it.
    ///
    /// **`repo` stops after level 2.** It is answered by repo-scoped evidence
    /// alone — this repo's own stored default, or the ambient prefill for the
    /// repo whose `+` was clicked — and by nothing else. Neither the
    /// machine-wide map nor the provider's declared `default` may answer it,
    /// and when neither repo-scoped level can, the field stays blank and
    /// `launch` refuses to create on it.
    ///
    /// That exception is narrow on purpose and must stay narrow. Falling
    /// through to a provider default is right for every other field: a
    /// `permission_mode` or `cmd` nobody chose is a preference, and the worst
    /// case is a session configured a way the user did not intend. `repo` is
    /// different in kind — it names a real repository on a real machine, so a
    /// wrong value silently starts work against a repository the user was not
    /// even looking at. Field evidence: a provider declaring `repo` as an enum
    /// whose only permitted value was another repository turned a one-click
    /// `+` on THIS repo into a live session on THAT one, adopted into that
    /// repo's section. There is no supported way to undo a remote create —
    /// archive and forget both refuse remote lanes — so the wrong value cannot
    /// be walked back the way a wrong `permission_mode` can.
    ///
    /// **An `enum` value is validated on replay, never replayed blindly.** It
    /// is the one type with a CLOSED value set, and a provider is free to
    /// retire a value between the setting being stored and this create. Every
    /// candidate — stored, ambient, and the provider's own `default` — is
    /// therefore projected onto `values` with `matchAllowedValue`, and a
    /// candidate that matches nothing is DROPPED so the next level gets its
    /// turn. A value outside `values` matches no `.tag(...)` in the sheet's
    /// `Picker` (the control renders blank even for a required field) and the
    /// provider rejects it at `create` time; degrading is strictly better than
    /// either. Never an invented selection.
    static func resolveString(
        field: ProviderCreateParamField,
        repoPrefill: String?,
        repoDefaults: [String: String],
        globalDefaults: [String: String],
        generatedSlug: String?
    ) -> String {
        let repoScoped: [String?] = [
            repoDefaults[field.name],
            ambientPrefill(for: field.name, repoPrefill: repoPrefill, generatedSlug: generatedSlug),
        ]
        // `repo` stops here; every other field carries on to the machine-wide
        // map and the provider's own default.
        let candidates: [String?] = field.name == repoFieldName
            ? repoScoped
            : repoScoped + [globalDefaults[field.name], field.defaultValue]
        for candidate in candidates {
            guard let candidate,
                  !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard field.type == "enum" else { return candidate }
            if let matched = matchAllowedValue(candidate, in: field.values ?? []) { return matched }
        }
        return ""
    }

    /// The ambient value for a **well-known** `create_params` field name
    /// (docs/remote-provider-contract.md § `describe`), or nil for a field TBD
    /// has no ambient source for.
    ///
    /// - `repo` — the repo whose `+` was clicked, normalized by
    ///   `repoPrefill(remoteURL:)`. For this one field the ambient value is the
    ///   LAST level: nothing below it may answer (see `resolveString`).
    /// - `slug` — a freshly generated lane identifier. It comes from
    ///   `NameGenerator`, the same generator that names local worktrees, so a
    ///   remote lane reads like every other lane in the sidebar instead of
    ///   introducing a second naming scheme.
    ///
    /// `branch` is deliberately NOT filled. It is optional, and a blank
    /// optional field is omitted from the params entirely, so the provider's
    /// own answer applies — which is the better one: TBD would be inventing a
    /// branch name that exists nowhere, while the provider knows what its
    /// backend does with an absent branch. `prompt` and `title` have no
    /// ambient source at all.
    static func ambientPrefill(
        for fieldName: String, repoPrefill: String?, generatedSlug: String?
    ) -> String? {
        switch fieldName {
        case "repo": return repoPrefill
        case "slug": return generatedSlug
        default: return nil
        }
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

    /// Seeds initial bool-typed field values through the same repo → global →
    /// provider chain as `resolveString`, reading "true"/"false" strings at
    /// every level (that is how a bool's `default` is carried on the wire, so
    /// the stored maps use the same spelling and stay a plain
    /// `[String: String]`). Anything else at a level — including a blank — is
    /// no opinion and falls through; nothing answers `false` by default.
    ///
    /// No `required` handling here on purpose: a checkbox always has a value,
    /// so `false` is a real answer rather than a missing one (same rule
    /// `buildParamsJSON` applies).
    static func prefillBools(
        fields: [ProviderCreateParamField],
        repoDefaults: [String: String] = [:],
        globalDefaults: [String: String] = [:]
    ) -> [String: Bool] {
        var values: [String: Bool] = [:]
        for field in fields where field.type == "bool" {
            values[field.name] = [
                repoDefaults[field.name], globalDefaults[field.name], field.defaultValue,
            ].compactMap { $0 }.compactMap(boolValue(of:)).first ?? false
        }
        return values
    }

    /// The wire spelling of a bool create-param value, or nil for anything
    /// that is not an answer (a blank, or a value from a provider that spells
    /// its booleans some other way — which falls through rather than being
    /// coerced to `false`).
    private static func boolValue(of raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    // MARK: - Prefilled state and the one-click decision

    /// The create form's fully prefilled starting state, plus what is still
    /// unanswered. Produced by `plan`, consumed both by `RemoteCreateSheet`
    /// (which renders it) and by `launch` (which decides whether the sheet
    /// needs to be rendered at all).
    struct Plan: Equatable {
        let stringValues: [String: String]
        let boolValues: [String: Bool]
        /// Required fields no level could answer, in `fields` order.
        let missingRequired: [String]
        /// The provider asks which repository to work in, and no repo-scoped
        /// level could say (see `resolveString`): either the `+` carried no
        /// repo at all, or the repo it carried matches nothing the provider
        /// declares.
        ///
        /// Tracked separately from `missingRequired` because it must block a
        /// one-click even when the provider marks `repo` OPTIONAL. A blank
        /// optional field is omitted from the params, and an omitted `repo` is
        /// answered by the provider's own default — the same wrong repository,
        /// reached by the other door.
        let repoUnanswered: Bool
        /// Every required field is answered, so nothing needs asking.
        var isComplete: Bool { missingRequired.isEmpty }
    }

    /// Resolve every field through the precedence chain and report which
    /// required ones are still unanswered.
    ///
    /// `required` is applied only to non-bool fields, matching
    /// `buildParamsJSON`: a checkbox always has a value.
    static func plan(
        fields: [ProviderCreateParamField],
        repoPrefill: String?,
        repoDefaults: [String: String],
        globalDefaults: [String: String],
        generatedSlug: String?
    ) -> Plan {
        let strings = prefillStrings(
            fields: fields, repoPrefill: repoPrefill, repoDefaults: repoDefaults,
            globalDefaults: globalDefaults, generatedSlug: generatedSlug)
        let bools = prefillBools(
            fields: fields, repoDefaults: repoDefaults, globalDefaults: globalDefaults)
        let missing = fields
            .filter { $0.required && $0.type != "bool" }
            .filter { (strings[$0.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(\.name)
        let repoUnanswered = fields.contains { $0.name == repoFieldName }
            && (strings[repoFieldName] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Plan(
            stringValues: strings, boolValues: bools, missingRequired: missing,
            repoUnanswered: repoUnanswered)
    }

    /// What selecting "New remote session…" should actually do.
    enum Launch: Equatable {
        /// Every required answer was already knowable — create straight away.
        case createNow(paramsJSON: String)
        /// Something still needs a human: render the form, prefilled with
        /// everything that IS known.
        case openForm(Plan)
    }

    /// Decide between creating immediately and opening the form.
    ///
    /// The form opens in exactly four cases, and creating on a guess is the
    /// one outcome ruled out entirely:
    ///
    ///  - the provider has not reported its `create_params` yet (`describe`
    ///    is nil), so TBD does not know what it would be answering;
    ///  - a required field no level could answer;
    ///  - the provider asks which repository to work in and no repo-scoped
    ///    level could say (`Plan.repoUnanswered`) — including when the field
    ///    is optional, since an omitted `repo` is answered by the provider's
    ///    own default;
    ///  - a resolved value that fails the same local validation the form
    ///    applies (an `int` field holding a stored non-number, say) — the
    ///    error belongs in front of the user, next to the field.
    ///
    /// Otherwise every answer is known and the session is created with no
    /// sheet. A provider with no create params at all lands here too: an empty
    /// form has nothing to ask.
    static func launch(
        describe: ProviderDescribe?,
        repoPrefill: String?,
        repoDefaults: [String: String],
        globalDefaults: [String: String],
        generatedSlug: String?
    ) -> Launch {
        guard let describe else {
            return .openForm(
                Plan(
                    stringValues: [:], boolValues: [:], missingRequired: [],
                    repoUnanswered: false))
        }
        let fields = describe.createParams
        let plan = plan(
            fields: fields, repoPrefill: repoPrefill, repoDefaults: repoDefaults,
            globalDefaults: globalDefaults, generatedSlug: generatedSlug)
        guard plan.isComplete, !plan.repoUnanswered,
              case .success(let json) = buildParamsJSON(
                fields: fields, stringValues: plan.stringValues, boolValues: plan.boolValues)
        else {
            return .openForm(plan)
        }
        return .createNow(paramsJSON: json)
    }

    /// Whether selecting the remote-lane row will create outright rather than
    /// open the form — the same decision `launch` makes, asked ahead of the
    /// click so the row can label itself honestly (a trailing ellipsis
    /// promises a dialog).
    ///
    /// It asks with a placeholder slug rather than minting a real lane name
    /// for a label, which changes no answer: what a `slug` field needs is a
    /// non-blank value, and both a placeholder and a generated name are that.
    static func willCreateImmediately(
        describe: ProviderDescribe?,
        repoPrefill: String?,
        repoDefaults: [String: String],
        globalDefaults: [String: String]
    ) -> Bool {
        if case .createNow = launch(
            describe: describe, repoPrefill: repoPrefill, repoDefaults: repoDefaults,
            globalDefaults: globalDefaults, generatedSlug: slugPreviewPlaceholder) {
            return true
        }
        return false
    }

    /// Stands in for a generated slug when only the DECISION is wanted, not a
    /// name anything will be created under.
    static let slugPreviewPlaceholder = "slug-preview"

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
