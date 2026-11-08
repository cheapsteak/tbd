import AppKit
import Metal
import os
import TBDShared

private let engineLogger = Logger(subsystem: "com.tbd.app", category: "terminalEngine")

/// Where a terminal engine is being built, which decides the kinds it may be.
enum TerminalEngineHost: Equatable, Sendable {
    /// A panel in the main area or the dock, on this transport. Control mode is
    /// a tmux panel.
    case panel(TerminalTransport)
    /// A local PTY: the remote attach pane and the remote sign-in sheet.
    case localPTY
}

/// Builds the terminal engine a coordinator runs.
///
/// `.swiftTerm` always builds `SwiftTermEngine`. `.ghostty` builds
/// `GhosttyEngine`, and falls back to SwiftTerm, logging the fallback the spec
/// names, when libghostty cannot start: no Metal device, or a renderer or
/// terminal that fails to build. The engine's `kind` and the log both say which
/// engine a terminal really got.
@MainActor
enum TerminalEngineFactory {
    /// What builds a libghostty engine. A seam: a test passes one that throws,
    /// to reach the fallback on a machine where libghostty would start.
    typealias GhosttyMaker = @MainActor (
        _ font: NSFont, _ appearance: AppearanceSettings, _ configuration: TerminalEngineConfiguration
    ) throws -> any TerminalEngine

    /// The kinds the engine contract suite runs over: every kind this build can
    /// actually make on this machine. libghostty draws only with Metal, so on a
    /// machine with no Metal device the suite runs SwiftTerm alone, where every
    /// `.ghostty` request would fall back to it anyway. `nonisolated` so a
    /// test's `arguments:` can read it.
    nonisolated static var availableKinds: [TerminalEngineKind] {
        MTLCreateSystemDefaultDevice() == nil ? [.swiftTerm] : [.swiftTerm, .ghostty]
    }

    /// The kind a terminal at `host` asks for.
    ///
    /// libghostty only while `useGhosttyTerminalEngine` resolves to true, and
    /// only where the program's own mouse modes reach the terminal: holder
    /// panels and local PTYs. A tmux or control-mode panel stays on SwiftTerm,
    /// because tmux holds a mouse mode of its own there and SwiftTerm is what
    /// keeps local selection working under it.
    ///
    /// `override` is a holder panel's choice from Switch Terminal Engine. It
    /// counts only while the flag is on, so turning the flag off puts every
    /// terminal opened afterwards back on SwiftTerm.
    nonisolated static func requestedKind(
        flagEnabled: Bool,
        host: TerminalEngineHost,
        override: TerminalEngineKind? = nil
    ) -> TerminalEngineKind {
        guard flagEnabled else { return .swiftTerm }
        switch host {
        case .panel(.holder):
            return override ?? .ghostty
        case .panel(.tmux):
            return .swiftTerm
        case .localPTY:
            return .ghostty
        }
    }

    /// - Parameter makeGhostty: builds the libghostty engine; the default is
    ///   `GhosttyEngine`'s initializer.
    /// - Parameter onFallback: told the kind that was asked for and why it
    ///   could not be built, once per fallback. Defaults to the `.notice` log
    ///   line; a test passes its own to observe the fallback.
    static func make(
        kind: TerminalEngineKind,
        font: NSFont,
        appearance: AppearanceSettings,
        configuration: TerminalEngineConfiguration,
        makeGhostty: GhosttyMaker = TerminalEngineFactory.makeGhosttyEngine,
        onFallback: (_ requested: TerminalEngineKind, _ reason: String) -> Void = TerminalEngineFactory.logFallback
    ) -> any TerminalEngine {
        switch kind {
        case .swiftTerm:
            return SwiftTermEngine(font: font, appearance: appearance, configuration: configuration)
        case .ghostty:
            do {
                let engine = try makeGhostty(font, appearance, configuration)
                logActive(configuration: configuration)
                return engine
            } catch {
                onFallback(.ghostty, Self.reason(for: error))
                return SwiftTermEngine(font: font, appearance: appearance, configuration: configuration)
            }
        }
    }

    static func makeGhosttyEngine(
        font: NSFont, appearance: AppearanceSettings, configuration: TerminalEngineConfiguration
    ) throws -> any TerminalEngine {
        try GhosttyEngine(font: font, appearance: appearance, configuration: configuration)
    }

    /// An error's own words: `GhosttyError` describes itself, payload
    /// included, where the NSError bridge would drop the payload.
    nonisolated static func reason(for error: any Error) -> String {
        String(describing: error)
    }

    /// The fallback notice the spec names. `.ghostty` is the only kind that
    /// falls back, so the line names libghostty.
    nonisolated static func logFallback(requested: TerminalEngineKind, reason: String) {
        engineLogger.notice(
            "libghostty engine unavailable, fell back to SwiftTerm: \(reason, privacy: .public)")
    }

    /// The success notice the spec names, so a log shows which terminals the
    /// experiment really reached.
    nonisolated static func logActive(configuration: TerminalEngineConfiguration) {
        let terminal = configuration.terminalID?.uuidString ?? "a local PTY"
        engineLogger.notice("libghostty engine active for \(terminal, privacy: .public)")
    }
}
