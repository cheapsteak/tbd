import AppKit

/// Builds the terminal engine a coordinator runs.
///
/// Every kind builds `SwiftTermEngine` for now. The libghostty engine, and the
/// default-off `useGhosttyTerminalEngine` flag that chooses it, arrive with
/// their own branch here.
@MainActor
enum TerminalEngineFactory {
    /// The kinds the engine contract suite runs over: every kind this build can
    /// actually make. `nonisolated` so a test's `arguments:` can read it.
    nonisolated static var availableKinds: [TerminalEngineKind] { [.swiftTerm] }

    static func make(
        kind: TerminalEngineKind,
        font: NSFont,
        appearance: AppearanceSettings,
        configuration: TerminalEngineConfiguration
    ) -> any TerminalEngine {
        switch kind {
        case .swiftTerm, .ghostty:
            return SwiftTermEngine(font: font, appearance: appearance, configuration: configuration)
        }
    }
}
