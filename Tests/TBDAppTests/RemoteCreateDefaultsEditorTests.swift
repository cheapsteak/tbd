import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// Tier 1. The pure half of `RemoteCreateDefaultsEditor` — how a control's
/// value becomes a map entry, and how the unset choice reads. The rendering
/// itself is not unit-testable in this codebase (no SwiftUI view harness), so
/// these cover the two behaviors a reviewer could not otherwise check.
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

    // MARK: - Captions

    @Test func eachScopeSCaptionNamesItsOwnFallThrough() {
        #expect(RemoteCreateDefaultsEditor.caption(scope: .repo).contains("global"))
        #expect(RemoteCreateDefaultsEditor.caption(scope: .global).contains("provider"))
    }
}
