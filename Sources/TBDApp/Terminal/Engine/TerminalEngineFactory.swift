import AppKit
import Metal
import os

private let engineLogger = Logger(subsystem: "com.tbd.app", category: "terminalEngine")

/// Builds the terminal engine a coordinator runs.
///
/// `.swiftTerm` always builds `SwiftTermEngine`. `.ghostty` builds
/// `GhosttyEngine`, and falls back to SwiftTerm, logging the fallback the spec
/// names, when libghostty cannot start: no Metal device, or a renderer or
/// terminal that fails to build. The engine's `kind` and the log both say which
/// engine a terminal really got.
@MainActor
enum TerminalEngineFactory {
    /// The kinds the engine contract suite runs over: every kind this build can
    /// actually make on this machine. libghostty draws only with Metal, so on a
    /// machine with no Metal device the suite runs SwiftTerm alone, where every
    /// `.ghostty` request would fall back to it anyway. `nonisolated` so a
    /// test's `arguments:` can read it.
    nonisolated static var availableKinds: [TerminalEngineKind] {
        MTLCreateSystemDefaultDevice() == nil ? [.swiftTerm] : [.swiftTerm, .ghostty]
    }

    /// - Parameter onFallback: told the kind that was asked for and why it
    ///   could not be built, once per fallback. Defaults to the `.notice` log
    ///   line; a test passes its own to observe the fallback.
    static func make(
        kind: TerminalEngineKind,
        font: NSFont,
        appearance: AppearanceSettings,
        configuration: TerminalEngineConfiguration,
        onFallback: (_ requested: TerminalEngineKind, _ reason: String) -> Void = TerminalEngineFactory.logFallback
    ) -> any TerminalEngine {
        switch kind {
        case .swiftTerm:
            return SwiftTermEngine(font: font, appearance: appearance, configuration: configuration)
        case .ghostty:
            do {
                return try GhosttyEngine(font: font, appearance: appearance, configuration: configuration)
            } catch {
                onFallback(.ghostty, String(describing: error))
                return SwiftTermEngine(font: font, appearance: appearance, configuration: configuration)
            }
        }
    }

    /// The fallback notice the spec names. `.ghostty` is the only kind that
    /// falls back, so the line names libghostty.
    nonisolated static func logFallback(requested: TerminalEngineKind, reason: String) {
        engineLogger.notice(
            "libghostty engine unavailable, fell back to SwiftTerm: \(reason, privacy: .public)")
    }
}
