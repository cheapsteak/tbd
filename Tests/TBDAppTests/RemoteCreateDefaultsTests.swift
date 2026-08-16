import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// Tier 1. The create-param precedence chain and the one-click launch decision
/// it feeds: repo map → ambient well-known prefill → global map → the field's
/// provider-declared `default` → blank. Pure logic, no SwiftUI and no daemon.
///
/// The chain mirrors the model-profile one (`ModelProfileResolver.resolve`:
/// repo override → global default → none); the ambient prefill sits inside the
/// repo tier because it too is a fact about the repo the `+` was clicked on.
@Suite("Remote create-param defaults — precedence and launch")
struct RemoteCreateDefaultsTests {

    private func permissionModeField(required: Bool = false) -> ProviderCreateParamField {
        ProviderCreateParamField(
            name: "permission_mode", type: "enum", label: "Permission mode",
            required: required, defaultValue: "default",
            values: ["skip_permissions", "accept_edits", "plan", "default"])
    }

    // MARK: - Precedence

    @Test func aRepoValueBeatsAGlobalOne() {
        let plan = RemoteCreateFormLogic.plan(
            fields: [permissionModeField()],
            repoPrefill: nil,
            repoDefaults: ["permission_mode": "plan"],
            globalDefaults: ["permission_mode": "skip_permissions"],
            generatedSlug: "20260816-consistent-reptile")
        #expect(plan.stringValues["permission_mode"] == "plan")
    }

    @Test func aGlobalValueAppliesWhenTheRepoDefers() {
        // "Absent at a level" is exactly the state a repo left on Auto is in.
        let plan = RemoteCreateFormLogic.plan(
            fields: [permissionModeField()],
            repoPrefill: nil,
            repoDefaults: [:],
            globalDefaults: ["permission_mode": "skip_permissions"],
            generatedSlug: "20260816-consistent-reptile")
        #expect(plan.stringValues["permission_mode"] == "skip_permissions")
    }

    @Test func theProviderDefaultAppliesWhenBothLevelsDefer() {
        let plan = RemoteCreateFormLogic.plan(
            fields: [permissionModeField()],
            repoPrefill: nil,
            repoDefaults: [:],
            globalDefaults: [:],
            generatedSlug: "20260816-consistent-reptile")
        #expect(plan.stringValues["permission_mode"] == "default")
    }

    @Test func aFieldWithNoStoredValueAndNoProviderDefaultLandsBlank() {
        let fields = [ProviderCreateParamField(name: "note", type: "string")]
        let plan = RemoteCreateFormLogic.plan(
            fields: fields, repoPrefill: nil, repoDefaults: [:], globalDefaults: [:],
            generatedSlug: "20260816-consistent-reptile")
        #expect(plan.stringValues["note"] == "")
    }

    @Test func aBlankStoredValueIsNoOpinionAndFallsThrough() {
        // Clearing a text control writes "" rather than removing the key on
        // some paths; an empty string must read as "no opinion" like an absent
        // key, not as a deliberate blank that shadows the level below.
        let plan = RemoteCreateFormLogic.plan(
            fields: [permissionModeField()],
            repoPrefill: nil,
            repoDefaults: ["permission_mode": "   "],
            globalDefaults: ["permission_mode": "plan"],
            generatedSlug: "20260816-consistent-reptile")
        #expect(plan.stringValues["permission_mode"] == "plan")
    }

    // MARK: - Validate on replay

    @Test func aStoredEnumValueNoLongerDeclaredIsDroppedAndFallsThrough() {
        // The provider renamed/retired the value between the setting being
        // stored and this create. Replaying it verbatim is what produced the
        // create failure this branch already fixed once, so it must degrade to
        // the next level instead.
        let field = ProviderCreateParamField(
            name: "permission_mode", type: "enum", defaultValue: "default",
            values: ["accept_edits", "plan", "default"])
        let plan = RemoteCreateFormLogic.plan(
            fields: [field],
            repoPrefill: nil,
            repoDefaults: ["permission_mode": "skip_permissions"],
            globalDefaults: ["permission_mode": "plan"],
            generatedSlug: "20260816-consistent-reptile")
        #expect(plan.stringValues["permission_mode"] == "plan")
    }

    @Test func aStoredEnumValueFallsAllTheWayToTheProviderDefault() {
        let field = ProviderCreateParamField(
            name: "permission_mode", type: "enum", defaultValue: "default",
            values: ["accept_edits", "plan", "default"])
        let plan = RemoteCreateFormLogic.plan(
            fields: [field],
            repoPrefill: nil,
            repoDefaults: ["permission_mode": "skip_permissions"],
            globalDefaults: ["permission_mode": "also_gone"],
            generatedSlug: "20260816-consistent-reptile")
        #expect(plan.stringValues["permission_mode"] == "default")
    }

    @Test func aStoredEnumValueIsProjectedOntoTheDeclaredSpelling() {
        // Same short ladder `matchAllowedValue` already applies to the repo
        // prefill — the provider validates against exactly what it declared.
        let field = ProviderCreateParamField(
            name: "permission_mode", type: "enum",
            values: ["Skip_Permissions", "plan"])
        let plan = RemoteCreateFormLogic.plan(
            fields: [field], repoPrefill: nil,
            repoDefaults: ["permission_mode": "skip_permissions"],
            globalDefaults: [:], generatedSlug: "s")
        #expect(plan.stringValues["permission_mode"] == "Skip_Permissions")
    }

    @Test func aStoredValueForANonEnumFieldIsReplayedVerbatim() {
        let fields = [ProviderCreateParamField(name: "cmd", type: "string", defaultValue: "claude")]
        let plan = RemoteCreateFormLogic.plan(
            fields: fields, repoPrefill: nil,
            repoDefaults: [:], globalDefaults: ["cmd": "claude --verbose"],
            generatedSlug: "s")
        #expect(plan.stringValues["cmd"] == "claude --verbose")
    }

    // MARK: - Bool fields

    @Test func aStoredBoolBeatsTheProviderDefaultAtEachLevel() {
        let field = ProviderCreateParamField(name: "verbose", type: "bool", defaultValue: "true")
        let repoWins = RemoteCreateFormLogic.plan(
            fields: [field], repoPrefill: nil,
            repoDefaults: ["verbose": "false"], globalDefaults: ["verbose": "true"],
            generatedSlug: "s")
        #expect(repoWins.boolValues["verbose"] == false)

        let globalWins = RemoteCreateFormLogic.plan(
            fields: [field], repoPrefill: nil,
            repoDefaults: [:], globalDefaults: ["verbose": "false"],
            generatedSlug: "s")
        #expect(globalWins.boolValues["verbose"] == false)

        let providerWins = RemoteCreateFormLogic.plan(
            fields: [field], repoPrefill: nil, repoDefaults: [:], globalDefaults: [:],
            generatedSlug: "s")
        #expect(providerWins.boolValues["verbose"] == true)
    }

    // MARK: - Well-known ambient prefills

    @Test func theGeneratedSlugFillsTheWellKnownSlugField() {
        let fields = [ProviderCreateParamField(name: "slug", type: "string", required: true)]
        let plan = RemoteCreateFormLogic.plan(
            fields: fields, repoPrefill: nil, repoDefaults: [:], globalDefaults: [:],
            generatedSlug: "20260816-consistent-reptile")
        #expect(plan.stringValues["slug"] == "20260816-consistent-reptile")
    }

    @Test func twoPlansTakeTheirOwnGeneratedSlugs() {
        let fields = [ProviderCreateParamField(name: "slug", type: "string", required: true)]
        let first = RemoteCreateFormLogic.plan(
            fields: fields, repoPrefill: nil, repoDefaults: [:], globalDefaults: [:],
            generatedSlug: NameGenerator.generate())
        let second = RemoteCreateFormLogic.plan(
            fields: fields, repoPrefill: nil, repoDefaults: [:], globalDefaults: [:],
            generatedSlug: NameGenerator.generate())
        #expect(first.stringValues["slug"]?.isEmpty == false)
        #expect(second.stringValues["slug"]?.isEmpty == false)
    }

    /// The uniqueness half of "unique-ish": the slug comes from the same
    /// generator that names local worktrees, whose adjective x animal space is
    /// ~16.7k, so 50 draws colliding more than a handful of times would mean
    /// the generator, not chance.
    @Test func theWorktreeNameGeneratorGivesDistinctSlugs() {
        let drawn = Set((0..<50).map { _ in NameGenerator.generate() })
        #expect(drawn.count >= 45)
    }

    @Test func theRepoPrefillStillFillsTheWellKnownRepoField() {
        let fields = [ProviderCreateParamField(name: "repo", type: "string", required: true)]
        let plan = RemoteCreateFormLogic.plan(
            fields: fields, repoPrefill: "acme/api", repoDefaults: [:], globalDefaults: [:],
            generatedSlug: "s")
        #expect(plan.stringValues["repo"] == "acme/api")
    }

    @Test func aRepoScopedStoredValueBeatsTheAmbientRepoPrefill() {
        let fields = [ProviderCreateParamField(name: "repo", type: "string", required: true)]
        let plan = RemoteCreateFormLogic.plan(
            fields: fields, repoPrefill: "acme/api",
            repoDefaults: ["repo": "acme/api-fork"], globalDefaults: [:],
            generatedSlug: "s")
        #expect(plan.stringValues["repo"] == "acme/api-fork")
    }

    /// The one deliberate departure from a flat repo → global → provider
    /// chain: the ambient prefill is repo-scoped evidence (the user clicked
    /// this repo's `+`), so it outranks a machine-wide value that cannot know
    /// which repo was clicked.
    @Test func theAmbientRepoPrefillBeatsAGlobalStoredValue() {
        let fields = [ProviderCreateParamField(name: "repo", type: "string", required: true)]
        let plan = RemoteCreateFormLogic.plan(
            fields: fields, repoPrefill: "acme/api",
            repoDefaults: [:], globalDefaults: ["repo": "acme/unrelated"],
            generatedSlug: "s")
        #expect(plan.stringValues["repo"] == "acme/api")
    }

    @Test func anAmbientPrefillIsProjectedOntoAnEnumFieldSValues() {
        let fields = [ProviderCreateParamField(
            name: "repo", type: "enum", required: true, values: ["acme-org/acme-api"])]
        let plan = RemoteCreateFormLogic.plan(
            fields: fields, repoPrefill: "acme/acme-api", repoDefaults: [:], globalDefaults: [:],
            generatedSlug: "s")
        #expect(plan.stringValues["repo"] == "acme-org/acme-api")
    }

    // MARK: - Missing required fields

    @Test func aRequiredFieldNoLevelAnswersIsReportedMissing() {
        let fields = [
            ProviderCreateParamField(name: "repo", type: "string", required: true),
            ProviderCreateParamField(name: "ticket", type: "string", required: true),
        ]
        let plan = RemoteCreateFormLogic.plan(
            fields: fields, repoPrefill: "acme/api", repoDefaults: [:], globalDefaults: [:],
            generatedSlug: "s")
        #expect(plan.missingRequired == ["ticket"])
        #expect(plan.isComplete == false)
    }

    @Test func aRequiredBoolIsNeverMissingBecauseFalseIsAnAnswer() {
        let fields = [ProviderCreateParamField(name: "confirm", type: "bool", required: true)]
        let plan = RemoteCreateFormLogic.plan(
            fields: fields, repoPrefill: nil, repoDefaults: [:], globalDefaults: [:],
            generatedSlug: "s")
        #expect(plan.missingRequired.isEmpty)
    }

    @Test func anOptionalUnanswerableFieldDoesNotBlockCompletion() {
        let fields = [ProviderCreateParamField(name: "prompt", type: "text")]
        let plan = RemoteCreateFormLogic.plan(
            fields: fields, repoPrefill: nil, repoDefaults: [:], globalDefaults: [:],
            generatedSlug: "s")
        #expect(plan.isComplete)
    }

    // MARK: - Launch decision

    /// The live provider's shape: `repo` (enum, one value, required, has a
    /// default), `slug` (string, required, no default), `branch`, `prompt`,
    /// `cmd`, `permission_mode`.
    private var providerShapedFields: [ProviderCreateParamField] {
        [
            ProviderCreateParamField(
                name: "repo", type: "enum", required: true,
                defaultValue: "acme-org/acme-api", values: ["acme-org/acme-api"]),
            ProviderCreateParamField(name: "slug", type: "string", required: true),
            ProviderCreateParamField(name: "branch", type: "string"),
            ProviderCreateParamField(name: "prompt", type: "text"),
            ProviderCreateParamField(name: "cmd", type: "string", defaultValue: "claude"),
            permissionModeField(),
        ]
    }

    @Test func oneClickFiresWhenEveryRequiredFieldResolves() throws {
        let describe = ProviderDescribe(name: "acme", createParams: providerShapedFields)
        let launch = RemoteCreateFormLogic.launch(
            describe: describe, repoPrefill: "acme-org/acme-api",
            repoDefaults: [:], globalDefaults: ["permission_mode": "skip_permissions"],
            generatedSlug: "20260816-consistent-reptile")
        guard case .createNow(let json) = launch else {
            Issue.record("expected .createNow, got \(launch)")
            return
        }
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["repo"] as? String == "acme-org/acme-api")
        #expect(object["slug"] as? String == "20260816-consistent-reptile")
        #expect(object["permission_mode"] as? String == "skip_permissions")
        #expect(object["cmd"] as? String == "claude")
        // Blank optionals are omitted, so the provider's own defaults apply.
        #expect(object["branch"] == nil)
        #expect(object["prompt"] == nil)
    }

    @Test func theFormOpensWhenARequiredFieldCannotBeResolved() {
        var fields = providerShapedFields
        fields.append(ProviderCreateParamField(name: "ticket", type: "string", required: true))
        let describe = ProviderDescribe(name: "acme", createParams: fields)
        let launch = RemoteCreateFormLogic.launch(
            describe: describe, repoPrefill: "acme-org/acme-api",
            repoDefaults: [:], globalDefaults: [:],
            generatedSlug: "20260816-consistent-reptile")
        guard case .openForm(let plan) = launch else {
            Issue.record("expected .openForm, got \(launch)")
            return
        }
        // Prefilled with everything that IS known — never a blank form.
        #expect(plan.stringValues["slug"] == "20260816-consistent-reptile")
        #expect(plan.stringValues["repo"] == "acme-org/acme-api")
        #expect(plan.missingRequired == ["ticket"])
    }

    @Test func theFormOpensWhenTheProviderHasNotReportedItsCreateForm() {
        let launch = RemoteCreateFormLogic.launch(
            describe: nil, repoPrefill: "acme-org/acme-api",
            repoDefaults: [:], globalDefaults: [:], generatedSlug: "s")
        guard case .openForm = launch else {
            Issue.record("expected .openForm, got \(launch)")
            return
        }
    }

    @Test func oneClickFiresForAProviderWithNoCreateParamsAtAll() {
        let describe = ProviderDescribe(name: "acme", createParams: [])
        let launch = RemoteCreateFormLogic.launch(
            describe: describe, repoPrefill: nil,
            repoDefaults: [:], globalDefaults: [:], generatedSlug: "s")
        #expect(launch == .createNow(paramsJSON: "{}"))
    }

    /// A required `int` whose only answer is a stored non-number would fail
    /// `buildParamsJSON`. Creating on a guess is the one outcome ruled out, so
    /// the form opens instead.
    @Test func theFormOpensWhenAResolvedValueFailsLocalValidation() {
        let fields = [ProviderCreateParamField(name: "size", type: "int", required: true)]
        let describe = ProviderDescribe(name: "acme", createParams: fields)
        let launch = RemoteCreateFormLogic.launch(
            describe: describe, repoPrefill: nil,
            repoDefaults: [:], globalDefaults: ["size": "not-a-number"], generatedSlug: "s")
        guard case .openForm(let plan) = launch else {
            Issue.record("expected .openForm, got \(launch)")
            return
        }
        #expect(plan.stringValues["size"] == "not-a-number")
    }
}
