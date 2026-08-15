import Testing
import Foundation
@testable import TBDShared

/// Tier 1. Regression cover for the NSError bridge-string defect.
///
/// A Swift error that conforms only to `Error` bridges to `NSError`, and
/// `localizedDescription` on that bridge renders
/// "The operation couldn't be completed. (TBDShared.FDChannelError error 1.)" —
/// the case name is gone and every payload it carried (errno, path, UUID,
/// reason) is gone with it. That string is what reaches the os.Logger error
/// line and the user-facing alert, so the throw arrives carrying nothing.
///
/// `localizedDescription` consults `LocalizedError.errorDescription` and
/// nothing else — a `CustomStringConvertible` `description` is not consulted —
/// so these tests exercise the exact dynamic-dispatch path a logging call site
/// takes: every value is held as `any Error` and read through that existential.
/// Binding to the concrete type would let the compiler pick a different
/// overload and prove nothing about the call sites this defends.
///
/// The two assertions divide the work. `assertNotBridgeString` fails against
/// the pre-fix code for every value in the table. `assertRenders` is the one
/// that separates a real fix from an `errorDescription` that returns only the
/// case name: it pins distinctive payload components — an errno, a path, a
/// UUID, a reason string — inside the rendered text.
@Suite("LocalizedError payload rendering (TBDShared)")
struct LocalizedErrorPayloadTests {

    // MARK: - Assertions

    /// The NSError bridge's fixed prefix, in BOTH spellings.
    ///
    /// Foundation renders it with a typographic apostrophe (U+2019), not the
    /// ASCII one — so a check written the obvious way ("couldn't") silently
    /// never fires, and the suite passes against unconverted code on this
    /// assertion alone. Both forms are listed because the localized string is
    /// Foundation's to change, and a check that only ever matched the wrong
    /// one is worse than no check.
    private static let bridgePrefixes = [
        "The operation couldn\u{2019}t be completed",
        "The operation couldn't be completed",
    ]

    /// The bridge's parenthesised suffix, e.g. `(TBDShared.RPCError error 0.)`.
    /// Matched by shape rather than by literal so a renamed module or type
    /// cannot slip a bridge string past this suite.
    private static let bridgeShape =
        #"\([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+ error -?[0-9]+\.\)"#

    /// Reads `localizedDescription` off the existential — the call-site path.
    private func assertNotBridgeString(
        _ error: any Error,
        _ label: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let rendered = error.localizedDescription
        for prefix in Self.bridgePrefixes {
            #expect(
                !rendered.contains(prefix),
                "\(label) rendered the NSError bridge string: \(rendered)",
                sourceLocation: sourceLocation
            )
        }
        #expect(
            rendered.range(of: Self.bridgeShape, options: .regularExpression) == nil,
            "\(label) rendered the NSError bridge shape (Module.Type error N.): \(rendered)",
            sourceLocation: sourceLocation
        )
        #expect(
            !rendered.isEmpty,
            "\(label) rendered an empty description",
            sourceLocation: sourceLocation
        )
    }

    /// Asserts every payload component survives into the rendered text.
    private func assertRenders(
        _ error: any Error,
        _ components: [String],
        _ label: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let rendered = error.localizedDescription
        for component in components {
            #expect(
                rendered.contains(component),
                "\(label) dropped payload \"\(component)\" from: \(rendered)",
                sourceLocation: sourceLocation
            )
        }
    }

    // MARK: - The table

    /// Representative values across TBDShared's error types, held as
    /// `any Error` so the lookup goes through the bridge.
    private static let sampleErrors: [(String, any Error)] = {
        let panelID = PanelID()
        let splitID = SplitID()
        return [
            ("SidecarFramingError.truncatedPayload", SidecarFramingError.truncatedPayload),
            ("SidecarFramingError.undecodableHeader", SidecarFramingError.undecodableHeader),
            ("RPCError.noResultData", RPCError.noResultData),
            ("FDChannelError.sendFailed", FDChannelError.sendFailed(32)),
            ("FDChannelError.receiveFailed", FDChannelError.receiveFailed(54)),
            ("FDChannelError.peerClosed", FDChannelError.peerClosed),
            ("TmuxExecutableResolverError.pathMustBeAbsolute", TmuxExecutableResolverError.pathMustBeAbsolute),
            ("TmuxExecutableResolverError.pathIsNotExecutable", TmuxExecutableResolverError.pathIsNotExecutable),
            ("PanelOperationError.panelNotFound", PanelOperationError.panelNotFound(panelID)),
            ("PanelOperationError.splitNotFound", PanelOperationError.splitNotFound(splitID)),
            ("PanelOperationError.invalidRatios", PanelOperationError.invalidRatios(reason: "ratios must sum to 1")),
            ("PanelOperationError.historyUnavailable", PanelOperationError.historyUnavailable(panelID)),
            ("CLIInstallerError.linkCreationFailed", CLIInstallerError.linkCreationFailed("remove existing: EACCES")),
            (
                "CLIInstallerError.crossDeviceLink",
                CLIInstallerError.crossDeviceLink(
                    target: "/Volumes/acme-scratch/tbd/.build/debug/tbd",
                    installPath: "/private/tmp/acme/.local/bin/tbd"
                )
            ),
            ("RegistryError.invalidEntry", RemoteProviderRegistry.RegistryError.invalidEntry("acme-prod")),
            ("RegistryError.duplicateName", RemoteProviderRegistry.RegistryError.duplicateName("acme-prod")),
            ("SettingsJSONSafety.Error.backupFailed", SettingsJSONSafety.Error.backupFailed("copy refused")),
            ("SettingsJSONSafety.Error.writeFailed", SettingsJSONSafety.Error.writeFailed("atomic replace refused")),
            ("SettingsJSONSafety.Error.roundtripFailed", SettingsJSONSafety.Error.roundtripFailed("hooks key vanished")),
            ("SettingsJSONSafety.Error.invariantFailed", SettingsJSONSafety.Error.invariantFailed("permissions shrank")),
        ]
    }()

    // MARK: - Tests

    @Test("no TBDShared error renders the NSError bridge string")
    func noBridgeStringAnywhere() {
        for (label, error) in Self.sampleErrors {
            assertNotBridgeString(error, label)
        }
    }

    @Test("errno payloads reach the rendered description")
    func errnoPayloadsRender() {
        assertRenders(FDChannelError.sendFailed(32), ["32"], "FDChannelError.sendFailed")
        assertRenders(FDChannelError.receiveFailed(54), ["54"], "FDChannelError.receiveFailed")
    }

    @Test("path payloads reach the rendered description")
    func pathPayloadsRender() {
        let target = "/Volumes/acme-scratch/tbd/.build/debug/tbd"
        let installPath = "/private/tmp/acme/.local/bin/tbd"
        assertRenders(
            CLIInstallerError.crossDeviceLink(target: target, installPath: installPath),
            [target, installPath],
            "CLIInstallerError.crossDeviceLink"
        )
    }

    @Test("UUID payloads reach the rendered description")
    func uuidPayloadsRender() {
        let panelID = PanelID()
        let splitID = SplitID()
        assertRenders(
            PanelOperationError.panelNotFound(panelID),
            [panelID.uuidString],
            "PanelOperationError.panelNotFound"
        )
        assertRenders(
            PanelOperationError.splitNotFound(splitID),
            [splitID.uuidString],
            "PanelOperationError.splitNotFound"
        )
        assertRenders(
            PanelOperationError.historyUnavailable(panelID),
            [panelID.uuidString],
            "PanelOperationError.historyUnavailable"
        )
    }

    @Test("reason payloads reach the rendered description")
    func reasonPayloadsRender() {
        assertRenders(
            CLIInstallerError.linkCreationFailed("remove existing: EACCES"),
            ["remove existing: EACCES"],
            "CLIInstallerError.linkCreationFailed"
        )
        assertRenders(
            SettingsJSONSafety.Error.writeFailed("atomic replace refused"),
            ["atomic replace refused"],
            "SettingsJSONSafety.Error.writeFailed"
        )
        assertRenders(
            PanelOperationError.invalidRatios(reason: "ratios must sum to 1"),
            ["ratios must sum to 1"],
            "PanelOperationError.invalidRatios"
        )
        assertRenders(
            RemoteProviderRegistry.RegistryError.duplicateName("acme-prod"),
            ["acme-prod"],
            "RegistryError.duplicateName"
        )
    }

    /// Guards the guard: the bridge-shape regex must actually reject a real
    /// bridge string, or `noBridgeStringAnywhere` would pass against
    /// unconverted code and prove nothing.
    @Test("the bridge-shape matcher rejects a genuine bridge string")
    func bridgeShapeMatcherIsNotVacuous() {
        // Spelled with the typographic apostrophe Foundation actually emits.
        let genuine = "The operation couldn\u{2019}t be completed. (TBDShared.FDChannelError error 1.)"
        #expect(Self.bridgePrefixes.contains { genuine.contains($0) })
        #expect(genuine.range(of: Self.bridgeShape, options: .regularExpression) != nil)

        // …and must not fire on a legitimate rendered payload that happens to
        // carry parentheses and digits.
        let legitimate = FDChannelError.sendFailed(32).localizedDescription
        #expect(legitimate.range(of: Self.bridgeShape, options: .regularExpression) == nil)
    }
}
