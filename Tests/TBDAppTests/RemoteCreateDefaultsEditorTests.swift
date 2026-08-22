import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// Tier 1. The pure half of `RemoteCreateDefaultsEditor` — how a control's
/// value becomes a map entry, how the unset choice reads, and which fields a
/// level is allowed to answer at all. The rendering itself is not
/// unit-testable in this codebase (no SwiftUI view harness), so these cover
/// the behaviors a reviewer could not otherwise check.
@Suite("Remote create-defaults editor — pure")
struct RemoteCreateDefaultsEditorTests {

    private let permissionMode = ProviderCreateParamField(
        name: "permission_mode", type: "enum", label: "Permission mode",
        defaultValue: "default", values: ["skip_permissions", "plan", "default"])

    // MARK: - Committing a value

    @Test func choosingAValueStoresItUnderTheProviderSFieldName() {
        let next = RemoteCreateDefaultsEditor.updating(
            [:], field: "permission_mode", to: "skip_permissions")
        #expect(next == ["permission_mode": "skip_permissions"])
    }

    /// Choosing Auto must REMOVE the key. An entry holding `""` would be a
    /// second spelling of "no opinion" that every reader has to know to
    /// collapse — and one that reads as a deliberate blank if anybody forgets.
    @Test func choosingAutoRemovesTheKeyRatherThanStoringABlank() {
        let next = RemoteCreateDefaultsEditor.updating(
            ["permission_mode": "plan", "cmd": "claude"], field: "permission_mode", to: "")
        #expect(next == ["cmd": "claude"])
    }

    @Test func aWhitespaceOnlyEntryIsAlsoAuto() {
        let next = RemoteCreateDefaultsEditor.updating(
            ["cmd": "claude"], field: "cmd", to: "   ")
        #expect(next.isEmpty)
    }

    @Test func otherFieldsAreUntouched() {
        let next = RemoteCreateDefaultsEditor.updating(
            ["cmd": "claude"], field: "permission_mode", to: "plan")
        #expect(next == ["cmd": "claude", "permission_mode": "plan"])
    }

    // MARK: - How "unset" reads

    @Test func aRepoSAutoEntrySaysItDefersToGlobal() {
        let label = RemoteCreateDefaultsEditor.autoLabel(
            field: permissionMode, scope: .repo,
            inheritedDefaults: ["permission_mode": "skip_permissions"])
        #expect(label.hasPrefix("Auto (use global)"))
        // And says what that actually resolves to, so Auto is never a blank
        // the user has to go and look up.
        #expect(label.contains("skip_permissions"))
    }

    @Test func aRepoSAutoEntryFallsThroughToTheProviderDefaultWhenGlobalIsUnsetToo() {
        let label = RemoteCreateDefaultsEditor.autoLabel(
            field: permissionMode, scope: .repo, inheritedDefaults: [:])
        #expect(label == "Auto (use global) — default")
    }

    /// `repo` does not fall through to the global map — `resolveString`
    /// refuses to read it from there — so its label must not promise one. What
    /// answers it when the repo has stored nothing is the repo the session is
    /// started in.
    @Test func aRepoSAutoEntryForRepoDoesNotClaimTheGlobalFallThrough() {
        let field = ProviderCreateParamField(name: "repo", type: "string")
        let label = RemoteCreateDefaultsEditor.autoLabel(
            field: field, scope: .repo, inheritedDefaults: ["repo": "acme/unrelated"])
        #expect(label == "Auto (use this repository)")
    }

    /// And the exception stays one field wide: everything else at a repo still
    /// says it defers to the global map, because it does.
    @Test func anyOtherFieldAtRepoScopeStillDefersToGlobal() {
        let field = ProviderCreateParamField(name: "slug", type: "string")
        #expect(RemoteCreateDefaultsEditor.autoLabel(
            field: field, scope: .repo, inheritedDefaults: [:]) == "Auto (use global)")
    }

    @Test func theGlobalAutoEntrySaysItDefersToTheProvider() {
        let label = RemoteCreateDefaultsEditor.autoLabel(
            field: permissionMode, scope: .global, inheritedDefaults: [:])
        #expect(label == "Auto (provider default) — default")
    }

    @Test func anAutoEntryWithNothingBeneathItNamesNoValue() {
        let field = ProviderCreateParamField(name: "ticket", type: "string")
        #expect(RemoteCreateDefaultsEditor.autoLabel(
            field: field, scope: .global, inheritedDefaults: [:]) == "Auto (provider default)")
    }

    /// An inherited value the provider no longer declares is dropped on the
    /// way to the label too — the label must not advertise a value the create
    /// would refuse to send.
    @Test func anInheritedEnumValueNoLongerDeclaredIsNotAdvertised() {
        let field = ProviderCreateParamField(
            name: "permission_mode", type: "enum", values: ["plan"])
        let label = RemoteCreateDefaultsEditor.autoLabel(
            field: field, scope: .repo, inheritedDefaults: ["permission_mode": "skip_permissions"])
        #expect(label == "Auto (use global)")
    }

    // MARK: - Which fields a level may answer

    /// The machine-wide map is not in `repo`'s candidate chain
    /// (`RemoteCreateFormLogic.resolveString`), so an editable control there
    /// would persist a value no create path ever reads.
    @Test func theGlobalLevelMayNotAnswerRepo() {
        #expect(!RemoteCreateDefaultsEditor.isEditable(
            fieldName: RemoteCreateFormLogic.repoFieldName, scope: .global))
    }

    /// A repo's own map IS the level `repo` is answered at, so the control
    /// stays exactly as it was there.
    @Test func aRepoSOwnLevelStillAnswersRepo() {
        #expect(RemoteCreateDefaultsEditor.isEditable(
            fieldName: RemoteCreateFormLogic.repoFieldName, scope: .repo))
    }

    /// The exception is `repo` and nothing else — every other field, well-known
    /// or provider-invented, is editable at both levels.
    @Test func everyOtherFieldIsEditableAtBothLevels() {
        for field in ["permission_mode", "slug", "branch", "cmd", "some_future_field"] {
            #expect(RemoteCreateDefaultsEditor.isEditable(fieldName: field, scope: .global))
            #expect(RemoteCreateDefaultsEditor.isEditable(fieldName: field, scope: .repo))
        }
    }

    /// A `repo` stored machine-wide before the control was withdrawn is read by
    /// nothing; saving must not carry it forward either.
    @Test func savingGloballyDoesNotCarryAStoredRepoForward() {
        let next = RemoteCreateDefaultsEditor.sanitized(
            ["repo": "acme/api", "cmd": "claude"], scope: .global)
        #expect(next == ["cmd": "claude"])
    }

    @Test func aRepoSOwnStoredRepoValueSurvives() {
        let next = RemoteCreateDefaultsEditor.sanitized(
            ["repo": "acme/api", "cmd": "claude"], scope: .repo)
        #expect(next == ["repo": "acme/api", "cmd": "claude"])
    }

    // MARK: - Captions

    @Test func eachScopeSCaptionNamesItsOwnFallThrough() {
        #expect(RemoteCreateDefaultsEditor.caption(scope: .repo).contains("global"))
        #expect(RemoteCreateDefaultsEditor.caption(scope: .global).contains("provider"))
    }

    /// The rule about `repo` is stated once, on the row it belongs to. The
    /// caption must not repeat it — two copies drift apart.
    @Test func theRepoRuleIsStatedOnTheRowAndNotAlsoInTheCaption() {
        #expect(RemoteCreateDefaultsEditor.fixedFieldNote.contains("repository"))
        #expect(!RemoteCreateDefaultsEditor.caption(scope: .global).contains("repository"))
    }
}
