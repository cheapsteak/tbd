import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// Task 10: pure logic behind `RemoteCreateSheet` — prefill derivation and
/// create-form validation/assembly (`RemoteCreateFormLogic`). No SwiftUI
/// here, so every branch below is directly testable; the sheet's actual
/// rendering isn't unit-tested (view rendering isn't unit-testable in this
/// codebase — see the task report for the full list of what's covered by
/// review/manual verification instead).
@Suite("Remote create form logic — pure")
struct RemoteCreateFormLogicTests {

    // MARK: - repoPrefill (reuses RemoteRepoMatching.displayKey)

    @Test func repoPrefillNormalizesAnHTTPSRemoteURL() {
        #expect(RemoteCreateFormLogic.repoPrefill(remoteURL: "https://github.com/acme/api") == "acme/api")
    }

    @Test func repoPrefillNormalizesAnSCPStyleRemoteURL() {
        #expect(RemoteCreateFormLogic.repoPrefill(remoteURL: "git@github.com:acme/api.git") == "acme/api")
    }

    @Test func repoPrefillReturnsNilWhenNoRemoteURL() {
        #expect(RemoteCreateFormLogic.repoPrefill(remoteURL: nil) == nil)
    }

    @Test func repoPrefillReturnsNilForAnUnparseableRemoteURL() {
        #expect(RemoteCreateFormLogic.repoPrefill(remoteURL: "not-a-url") == nil)
    }

    @Test func repoPrefillPreservesTheRepoSDisplayCasing() {
        // Fix pass 1 (task-10 review finding 6): the prefill must NOT
        // lowercase — a provider that clones against a case-sensitive host
        // using this value verbatim needs the repo's real casing, not the
        // lowercase comparison key `RemoteRepoMatching.normalizedKey`
        // produces for matching. Round-tripping the created session back
        // into this repo's section still works because BOTH sides of that
        // match normalize.
        #expect(RemoteCreateFormLogic.repoPrefill(remoteURL: "https://github.com/Acme/API") == "Acme/API")
    }

    // MARK: - prefillStrings

    @Test func prefillStringsSeedsRepoFieldFromRepoPrefillWhenPresent() {
        let fields = [ProviderCreateParamField(name: "repo", type: "string", required: true)]
        let values = RemoteCreateFormLogic.prefillStrings(fields: fields, repoPrefill: "acme/api")
        #expect(values["repo"] == "acme/api")
    }

    @Test func prefillStringsLeavesRepoFieldBlankWhenNoRepoPrefill() {
        let fields = [ProviderCreateParamField(name: "repo", type: "string", required: true)]
        let values = RemoteCreateFormLogic.prefillStrings(fields: fields, repoPrefill: nil)
        #expect(values["repo"] == "")
    }

    @Test func prefillStringsFallsBackToFieldDefaultForNonRepoFields() {
        let fields = [ProviderCreateParamField(name: "branch", type: "string", defaultValue: "main")]
        let values = RemoteCreateFormLogic.prefillStrings(fields: fields, repoPrefill: "acme/api")
        #expect(values["branch"] == "main")
    }

    @Test func prefillStringsLeavesTitleBlankWithNoDefault() {
        let fields = [ProviderCreateParamField(name: "title", type: "string", required: true)]
        let values = RemoteCreateFormLogic.prefillStrings(fields: fields, repoPrefill: "acme/api")
        #expect(values["title"] == "")
    }

    @Test func prefillStringsExcludesBoolFields() {
        let fields = [ProviderCreateParamField(name: "verbose", type: "bool")]
        let values = RemoteCreateFormLogic.prefillStrings(fields: fields, repoPrefill: nil)
        #expect(values["verbose"] == nil)
    }

    @Test func prefillStringsIgnoresRepoPrefillWhenNoRepoFieldExists() {
        let fields = [ProviderCreateParamField(name: "title", type: "string")]
        let values = RemoteCreateFormLogic.prefillStrings(fields: fields, repoPrefill: "acme/api")
        #expect(values["repo"] == nil)
    }

    // MARK: - prefillStrings: an enum field's prefill is projected onto its allowed values

    /// The shape a real provider ships: `repo` is an enum whose only allowed
    /// value is the SHORT repo name, while `repoPrefill` is the
    /// owner-qualified `displayKey` (that qualified form is what matches
    /// `meta.repo` when a session is resolved back to a repo, so it can't
    /// simply be shortened at the source). Writing the qualified value into
    /// the enum left the Picker with a selection matching no `.tag(...)` —
    /// rendering blank — and `create` rejected it provider-side.
    @Test func prefillStringsProjectsAnOwnerQualifiedPrefillOntoTheEnumsShortValue() {
        let fields = [ProviderCreateParamField(
            name: "repo", type: "enum", required: true,
            defaultValue: "acme-app", values: ["acme-app"])]
        let values = RemoteCreateFormLogic.prefillStrings(fields: fields, repoPrefill: "acme-org/acme-app")
        #expect(values["repo"] == "acme-app")
    }

    /// The mirror direction: the provider declares the owner-qualified form
    /// and the prefill is bare. Comparing the last `/`-separated component on
    /// BOTH sides bridges it either way.
    @Test func prefillStringsProjectsABarePrefillOntoAnOwnerQualifiedAllowedValue() {
        let fields = [ProviderCreateParamField(
            name: "repo", type: "enum", required: true, values: ["acme-org/acme-app"])]
        let values = RemoteCreateFormLogic.prefillStrings(fields: fields, repoPrefill: "acme-app")
        #expect(values["repo"] == "acme-org/acme-app")
    }

    @Test func prefillStringsKeepsAnExactlyMatchingEnumPrefill() {
        let fields = [ProviderCreateParamField(
            name: "repo", type: "enum", required: true, values: ["acme-org/acme-app", "acme-org/other"])]
        let values = RemoteCreateFormLogic.prefillStrings(fields: fields, repoPrefill: "acme-org/acme-app")
        #expect(values["repo"] == "acme-org/acme-app")
    }

    /// Matching is case-insensitive, and the ALLOWED value's casing wins —
    /// the provider validates against exactly what it declared.
    @Test func prefillStringsMatchesAnEnumValueCaseInsensitivelyAndAdoptsItsCasing() {
        let fields = [ProviderCreateParamField(
            name: "repo", type: "enum", required: true, values: ["Acme-App"])]
        let values = RemoteCreateFormLogic.prefillStrings(fields: fields, repoPrefill: "acme-app")
        #expect(values["repo"] == "Acme-App")
    }

    @Test func prefillStringsMatchesAnOwnerQualifiedPrefillCaseInsensitivelyByLastComponent() {
        let fields = [ProviderCreateParamField(
            name: "repo", type: "enum", required: true, values: ["Acme-App"])]
        let values = RemoteCreateFormLogic.prefillStrings(fields: fields, repoPrefill: "Acme-Org/acme-app")
        #expect(values["repo"] == "Acme-App")
    }

    @Test func prefillStringsFallsBackToTheEnumsDefaultWhenThePrefillMatchesNothing() {
        let fields = [ProviderCreateParamField(
            name: "repo", type: "enum", required: true,
            defaultValue: "other-app", values: ["other-app"])]
        let values = RemoteCreateFormLogic.prefillStrings(fields: fields, repoPrefill: "acme-org/acme-app")
        #expect(values["repo"] == "other-app")
    }

    /// No match AND no declared default: the field must land exactly where a
    /// prefill-less field would (blank), never on an invented selection.
    @Test func prefillStringsLeavesAnUnmatchedEnumBlankWhenItDeclaresNoDefault() {
        let fields = [ProviderCreateParamField(
            name: "repo", type: "enum", required: true, values: ["other-app"])]
        let values = RemoteCreateFormLogic.prefillStrings(fields: fields, repoPrefill: "acme-org/acme-app")
        #expect(values["repo"] == "")
    }

    /// Two allowed values sharing a last component make the loose stage
    /// ambiguous — picking either could silently create the session in the
    /// wrong repo, so the field falls back to its declared default.
    @Test func prefillStringsRefusesAnAmbiguousLastComponentMatch() {
        let fields = [ProviderCreateParamField(
            name: "repo", type: "enum", required: true, defaultValue: "acme-org/acme-app",
            values: ["acme-org/acme-app", "other-org/acme-app"])]
        let values = RemoteCreateFormLogic.prefillStrings(fields: fields, repoPrefill: "acme-app")
        #expect(values["repo"] == "acme-org/acme-app")
    }

    /// Only enums carry a closed value set — a `string`/`text`/`int` repo
    /// field still takes the prefill verbatim, owner qualifier and all.
    @Test func prefillStringsGivesANonEnumRepoFieldThePrefillVerbatim() {
        let fields = [ProviderCreateParamField(name: "repo", type: "string", required: true)]
        let values = RemoteCreateFormLogic.prefillStrings(fields: fields, repoPrefill: "acme-org/acme-app")
        #expect(values["repo"] == "acme-org/acme-app")
    }

    @Test func prefillStringsSeedsAnEnumWithNoPrefillFromItsOwnDefault() {
        let fields = [ProviderCreateParamField(
            name: "permission_mode", type: "enum", required: true,
            defaultValue: "plan", values: ["plan", "default"])]
        let values = RemoteCreateFormLogic.prefillStrings(fields: fields, repoPrefill: "acme-org/acme-app")
        #expect(values["permission_mode"] == "plan")
    }

    // MARK: - prefillBools

    @Test func prefillBoolsDefaultsToFalseWithNoDefaultValue() {
        let fields = [ProviderCreateParamField(name: "verbose", type: "bool")]
        let values = RemoteCreateFormLogic.prefillBools(fields: fields)
        #expect(values["verbose"] == false)
    }

    @Test func prefillBoolsHonorsTrueStringDefault() {
        let fields = [ProviderCreateParamField(name: "verbose", type: "bool", defaultValue: "true")]
        let values = RemoteCreateFormLogic.prefillBools(fields: fields)
        #expect(values["verbose"] == true)
    }

    // MARK: - rendersCaptionLabel (which types need a caption above the control)

    /// A `TextField`'s title argument is only a PLACEHOLDER and macOS hides
    /// it once the field has content, so every text-shaped control needs a
    /// real caption above it — otherwise a form whose slug, branch and
    /// command are all prefilled renders as three unlabeled boxes. `text`
    /// already had one; `string`, `int` and any unrecognized future type
    /// (which the sheet renders as a `TextField`) need the same.
    @Test func rendersCaptionLabelForEveryTextShapedType() {
        #expect(RemoteCreateFormLogic.rendersCaptionLabel(forType: "string"))
        #expect(RemoteCreateFormLogic.rendersCaptionLabel(forType: "int"))
        #expect(RemoteCreateFormLogic.rendersCaptionLabel(forType: "text"))
        #expect(RemoteCreateFormLogic.rendersCaptionLabel(forType: "some-future-type"))
    }

    /// `Toggle` and `Picker` display the label they're handed, so a caption
    /// would render the label twice.
    @Test func rendersNoCaptionLabelForControlsThatCarryTheirOwn() {
        #expect(!RemoteCreateFormLogic.rendersCaptionLabel(forType: "bool"))
        #expect(!RemoteCreateFormLogic.rendersCaptionLabel(forType: "enum"))
    }

    // MARK: - buildParamsJSON: required-field gate (branch per field kind)

    @Test func buildParamsJSON_missingRequiredStringFails() {
        let fields = [ProviderCreateParamField(name: "title", type: "string", required: true)]
        let result = RemoteCreateFormLogic.buildParamsJSON(fields: fields, stringValues: [:], boolValues: [:])
        #expect(result == .failure(.missingRequired(fieldName: "title")))
    }

    @Test func buildParamsJSON_missingRequiredStringWhitespaceOnlyFails() {
        let fields = [ProviderCreateParamField(name: "title", type: "string", required: true)]
        let result = RemoteCreateFormLogic.buildParamsJSON(
            fields: fields, stringValues: ["title": "   "], boolValues: [:])
        #expect(result == .failure(.missingRequired(fieldName: "title")))
    }

    @Test func buildParamsJSON_blankNonRequiredFieldIsOmittedNotFailed() throws {
        let fields = [
            ProviderCreateParamField(name: "title", type: "string", required: true),
            ProviderCreateParamField(name: "branch", type: "string", required: false),
        ]
        let result = RemoteCreateFormLogic.buildParamsJSON(
            fields: fields, stringValues: ["title": "fix ci"], boolValues: [:])
        let json = try result.get()
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(obj["title"] as? String == "fix ci")
        #expect(obj["branch"] == nil, "a blank, non-required field must be omitted, not sent as an empty string")
    }

    // MARK: - buildParamsJSON: bool fields are never "missing"

    @Test func buildParamsJSON_boolFieldIsNeverMissingRequiredEvenWhenRequiredTrue() throws {
        // A provider marking a bool field `required` is unusual, but the
        // contract doesn't forbid it — either way, a bool always has a
        // value (false counts), so it must never fail as "missing".
        let fields = [ProviderCreateParamField(name: "verbose", type: "bool", required: true)]
        let result = RemoteCreateFormLogic.buildParamsJSON(fields: fields, stringValues: [:], boolValues: [:])
        let json = try result.get()
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(obj["verbose"] as? Bool == false)
    }

    @Test func buildParamsJSON_boolFieldTrueValueIsSent() throws {
        let fields = [ProviderCreateParamField(name: "verbose", type: "bool")]
        let result = RemoteCreateFormLogic.buildParamsJSON(
            fields: fields, stringValues: [:], boolValues: ["verbose": true])
        let json = try result.get()
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(obj["verbose"] as? Bool == true)
    }

    // MARK: - buildParamsJSON: int fields

    @Test func buildParamsJSON_validIntIsParsedAndSentAsNumber() throws {
        let fields = [ProviderCreateParamField(name: "size", type: "int")]
        let result = RemoteCreateFormLogic.buildParamsJSON(
            fields: fields, stringValues: ["size": "42"], boolValues: [:])
        let json = try result.get()
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(obj["size"] as? Int == 42)
    }

    @Test func buildParamsJSON_invalidIntFails() {
        let fields = [ProviderCreateParamField(name: "size", type: "int")]
        let result = RemoteCreateFormLogic.buildParamsJSON(
            fields: fields, stringValues: ["size": "not-a-number"], boolValues: [:])
        #expect(result == .failure(.invalidInt(fieldName: "size")))
    }

    @Test func buildParamsJSON_blankOptionalIntIsOmittedNotZero() throws {
        let fields = [ProviderCreateParamField(name: "size", type: "int", required: false)]
        let result = RemoteCreateFormLogic.buildParamsJSON(fields: fields, stringValues: [:], boolValues: [:])
        let json = try result.get()
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(obj["size"] == nil)
    }

    @Test func buildParamsJSON_blankRequiredIntFailsAsMissingNotInvalid() {
        let fields = [ProviderCreateParamField(name: "size", type: "int", required: true)]
        let result = RemoteCreateFormLogic.buildParamsJSON(fields: fields, stringValues: [:], boolValues: [:])
        #expect(result == .failure(.missingRequired(fieldName: "size")))
    }

    // MARK: - buildParamsJSON: enum / text / string are treated as plain strings

    @Test func buildParamsJSON_enumFieldSendsSelectedStringValue() throws {
        let fields = [ProviderCreateParamField(name: "size", type: "enum", values: ["small", "large"])]
        let result = RemoteCreateFormLogic.buildParamsJSON(
            fields: fields, stringValues: ["size": "large"], boolValues: [:])
        let json = try result.get()
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(obj["size"] as? String == "large")
    }

    @Test func buildParamsJSON_textFieldSendsMultilineStringAsIs() throws {
        let fields = [ProviderCreateParamField(name: "prompt", type: "text")]
        let result = RemoteCreateFormLogic.buildParamsJSON(
            fields: fields, stringValues: ["prompt": "line one\nline two"], boolValues: [:])
        let json = try result.get()
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(obj["prompt"] as? String == "line one\nline two")
    }

    // MARK: - buildParamsJSON: field order determines which error is reported

    @Test func buildParamsJSON_reportsTheFirstOffendingFieldInListOrder() {
        let fields = [
            ProviderCreateParamField(name: "title", type: "string", required: true),
            ProviderCreateParamField(name: "size", type: "int"),
        ]
        let result = RemoteCreateFormLogic.buildParamsJSON(
            fields: fields, stringValues: ["size": "nope"], boolValues: [:])
        // `title` (listed first, blank + required) must win over the later
        // `size` field's invalid-int problem.
        #expect(result == .failure(.missingRequired(fieldName: "title")))
    }
}
