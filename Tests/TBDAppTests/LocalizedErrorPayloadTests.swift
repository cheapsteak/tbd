import Testing
import Foundation
@testable import TBDApp

/// Tier 1. Regression cover for the NSError bridge-string defect.
///
/// A Swift error that conforms only to `Error` bridges to `NSError`, and
/// `localizedDescription` on that bridge renders
/// "The operation couldn't be completed. (TBDApp.FDSidecarError error 1.)" —
/// the case name is gone and every payload it carried (errno, stage, hex
/// value, theme id) is gone with it. In this module that string is what the
/// user reads in an alert sheet, so the defect is directly user-visible.
///
/// `localizedDescription` consults `LocalizedError.errorDescription` and
/// nothing else — a `CustomStringConvertible` `description` is not consulted —
/// so every value here is held as `any Error` and read through that
/// existential, exercising the same dynamic-dispatch path an alert or a
/// logging call site takes. Binding to the concrete type would let the
/// compiler pick a different overload and prove nothing.
///
/// The suite is `@MainActor` because `ThemeStore` is, and its nested
/// `SaveError` / `DeleteError` inherit that isolation.
@MainActor
@Suite("LocalizedError payload rendering (TBDApp)")
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

    /// The bridge's parenthesised suffix, e.g. `(TBDApp.FDSidecarError error 0.)`.
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

    /// Representative values across TBDApp's error types, held as `any Error`
    /// so the lookup goes through the bridge.
    private func sampleErrors() -> [(String, any Error)] {
        [
            ("DaemonClientError.daemonNotRunning", DaemonClientError.daemonNotRunning),
            ("DaemonClientError.connectionFailed", DaemonClientError.connectionFailed("ECONNREFUSED on the daemon socket")),
            ("DaemonClientError.sendFailed", DaemonClientError.sendFailed("short write of 12 bytes")),
            ("DaemonClientError.receiveFailed", DaemonClientError.receiveFailed("EOF before the frame header")),
            ("DaemonClientError.invalidResponse", DaemonClientError.invalidResponse),
            ("DaemonClientError.rpcError", DaemonClientError.rpcError("worktree.wake refused", code: "terminalSessionGone")),
            ("DaemonClientError.attachUnavailable", DaemonClientError.attachUnavailable("controlModeDisabled")),
            (
                "AttachFDVendError",
                AttachFDVendError(generation: 4207, underlying: FDSidecarError.timedOut)
            ),
            ("FDSidecarError.connectFailed", FDSidecarError.connectFailed(61)),
            ("FDSidecarError.notConnected", FDSidecarError.notConnected),
            ("FDSidecarError.timedOut", FDSidecarError.timedOut),
            ("FDSidecarError.superseded", FDSidecarError.superseded),
            ("FDSidecarError.disconnected", FDSidecarError.disconnected),
            (
                "TmuxPreparationFailure.windowMissing",
                TmuxPreparationFailure.windowMissing(failedStage: .linkWindow)
            ),
            (
                "TmuxPreparationFailure.commandFailed",
                TmuxPreparationFailure.commandFailed(stage: .verifySelection, output: "can't find window @91")
            ),
            (
                "UserTerminalTheme.ValidationError.wrongAnsiCount",
                UserTerminalTheme.ValidationError.wrongAnsiCount(9)
            ),
            (
                "UserTerminalTheme.ValidationError.invalidHex",
                UserTerminalTheme.ValidationError.invalidHex(field: "ansi[7]", value: "#zzzz")
            ),
            (
                "UserTerminalTheme.ValidationError.invalidID",
                UserTerminalTheme.ValidationError.invalidID("Acme Theme!")
            ),
            (
                "UserTerminalTheme.ValidationError.unsupportedSchemaVersion",
                UserTerminalTheme.ValidationError.unsupportedSchemaVersion(7)
            ),
            (
                "AlacrittyImporter.ImportError.missingKey",
                AlacrittyImporter.ImportError.missingKey(section: "colors.primary", key: "background")
            ),
            (
                "AlacrittyImporter.ImportError.invalidHex",
                AlacrittyImporter.ImportError.invalidHex(section: "colors.normal", key: "magenta", value: "not-a-color")
            ),
            (
                "AlacrittyImporter.ImportError.tomlParseFailed",
                AlacrittyImporter.ImportError.tomlParseFailed("unexpected ] at line 12")
            ),
            ("ThemeStore.SaveError.bundledIDCollision", ThemeStore.SaveError.bundledIDCollision("tokyo-night")),
            ("ThemeStore.SaveError.ioFailed", ThemeStore.SaveError.ioFailed("themes dir is read-only")),
            ("ThemeStore.DeleteError.notFound", ThemeStore.DeleteError.notFound("acme-dark")),
            (
                "RemoteCreateFormLogic.FieldError.missingRequired",
                RemoteCreateFormLogic.FieldError.missingRequired(fieldName: "Branch")
            ),
            (
                "RemoteCreateFormLogic.FieldError.invalidInt",
                RemoteCreateFormLogic.FieldError.invalidInt(fieldName: "Idle timeout")
            ),
        ]
    }

    // MARK: - Tests

    @Test("no TBDApp error renders the NSError bridge string")
    func noBridgeStringAnywhere() {
        for (label, error) in sampleErrors() {
            assertNotBridgeString(error, label)
        }
    }

    @Test("errno payloads reach the rendered description")
    func errnoPayloadsRender() {
        assertRenders(FDSidecarError.connectFailed(61), ["61"], "FDSidecarError.connectFailed")
    }

    @Test("command and stage payloads reach the rendered description")
    func commandPayloadsRender() {
        assertRenders(
            TmuxPreparationFailure.commandFailed(stage: .verifySelection, output: "can't find window @91"),
            ["verifySelection", "can't find window @91"],
            "TmuxPreparationFailure.commandFailed"
        )
        assertRenders(
            TmuxPreparationFailure.windowMissing(failedStage: .linkWindow),
            ["linkWindow"],
            "TmuxPreparationFailure.windowMissing"
        )
        assertRenders(
            DaemonClientError.rpcError("worktree.wake refused", code: "terminalSessionGone"),
            ["worktree.wake refused"],
            "DaemonClientError.rpcError"
        )
    }

    @Test("multi-component payloads reach the rendered description")
    func multiComponentPayloadsRender() {
        assertRenders(
            UserTerminalTheme.ValidationError.invalidHex(field: "ansi[7]", value: "#zzzz"),
            ["ansi[7]", "#zzzz"],
            "UserTerminalTheme.ValidationError.invalidHex"
        )
        assertRenders(
            AlacrittyImporter.ImportError.invalidHex(
                section: "colors.normal", key: "magenta", value: "not-a-color"
            ),
            ["colors.normal", "magenta", "not-a-color"],
            "AlacrittyImporter.ImportError.invalidHex"
        )
        assertRenders(
            AlacrittyImporter.ImportError.missingKey(section: "colors.primary", key: "background"),
            ["colors.primary", "background"],
            "AlacrittyImporter.ImportError.missingKey"
        )
        assertRenders(
            UserTerminalTheme.ValidationError.wrongAnsiCount(9),
            ["9"],
            "UserTerminalTheme.ValidationError.wrongAnsiCount"
        )
        assertRenders(
            ThemeStore.SaveError.bundledIDCollision("tokyo-night"),
            ["tokyo-night"],
            "ThemeStore.SaveError.bundledIDCollision"
        )
        assertRenders(
            RemoteCreateFormLogic.FieldError.missingRequired(fieldName: "Branch"),
            ["Branch"],
            "RemoteCreateFormLogic.FieldError.missingRequired"
        )
    }

    /// The nested case: `AttachFDVendError` wraps another error and renders it
    /// through `localizedDescription`. If the wrapped type ever loses its
    /// conformance, the bridge string appears *inside* an otherwise-correct
    /// message — the shape a whole-string check would miss.
    @Test("a wrapping error renders both its own payload and the wrapped one")
    func wrappedErrorPayloadRenders() {
        let wrapper = AttachFDVendError(generation: 4207, underlying: FDSidecarError.connectFailed(61))
        assertNotBridgeString(wrapper, "AttachFDVendError")
        assertRenders(wrapper, ["4207", "61"], "AttachFDVendError")

        let noGeneration = AttachFDVendError(generation: nil, underlying: FDSidecarError.superseded)
        assertNotBridgeString(noGeneration, "AttachFDVendError(generation: nil)")
        assertRenders(noGeneration, ["none", "superseded"], "AttachFDVendError(generation: nil)")
    }

    /// Guards the guard: the bridge-shape regex must actually reject a real
    /// bridge string, or `noBridgeStringAnywhere` would pass against
    /// unconverted code and prove nothing.
    @Test("the bridge-shape matcher rejects a genuine bridge string")
    func bridgeShapeMatcherIsNotVacuous() {
        // Spelled with the typographic apostrophe Foundation actually emits.
        let genuine = "The operation couldn\u{2019}t be completed. (TBDApp.FDSidecarError error 1.)"
        #expect(Self.bridgePrefixes.contains { genuine.contains($0) })
        #expect(genuine.range(of: Self.bridgeShape, options: .regularExpression) != nil)

        // …and must not fire on a legitimate rendered payload that happens to
        // carry parentheses and digits.
        let legitimate = FDSidecarError.connectFailed(61).localizedDescription
        #expect(legitimate.range(of: Self.bridgeShape, options: .regularExpression) == nil)
    }
}
