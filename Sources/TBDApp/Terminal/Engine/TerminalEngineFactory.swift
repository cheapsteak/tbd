import AppKit
import os

private let engineLogger = Logger(subsystem: "com.tbd.app", category: "terminalEngine")

/// Builds the terminal engine a coordinator runs.
///
/// Every kind builds `SwiftTermEngine` for now. The libghostty engine, and the
/// default-off `useGhosttyTerminalEngine` flag that chooses it, arrive with
/// their own branch here. Until then a request for `.ghostty` falls back to
/// SwiftTerm and logs the fallback the spec names, so the engine's `kind` and
/// the log both say which engine a terminal really got.
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
        case .swiftTerm:
            return SwiftTermEngine(font: font, appearance: appearance, configuration: configuration)
        case .ghostty:
            let reason = "not built in this version"
            engineLogger.notice(
                "libghostty engine unavailable, fell back to SwiftTerm: \(reason, privacy: .public)")
            return SwiftTermEngine(font: font, appearance: appearance, configuration: configuration)
        }
    }
}
