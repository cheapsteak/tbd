import AppKit
import Metal
import os
import TBDShared

private let engineLogger = Logger(subsystem: "com.tbd.app", category: "terminalEngine")

/// A `.notice` line on `com.tbd.app` / `terminalEngine`: which engine a
/// terminal was built on, or that the libghostty experiment's flag changed.
///
/// `message` is the one place these words live.
/// `scripts/diag/terminal-latency-probe.py` matches them word for word to
/// confirm each arm of an engine A/B, and `TerminalEngineFactoryTests` pins
/// them, so a change here must change the probe's patterns too.
enum TerminalEngineNotice: Equatable, Sendable {
    /// A terminal built on `kind`. `terminal` is its id, or "a local PTY".
    case active(TerminalEngineKind, terminal: String)
    /// A libghostty build that could not start, so the terminal got SwiftTerm.
    case fallback(terminal: String, reason: String)
    /// `useGhosttyTerminalEngine` now reads `enabled`.
    case experiment(enabled: Bool)

    var message: String {
        switch self {
        case .active(let kind, let terminal):
            return "\(Self.name(of: kind)) engine active for \(terminal)"
        case .fallback(let terminal, let reason):
            return "libghostty engine unavailable for \(terminal), fell back to SwiftTerm: \(reason)"
        case .experiment(let enabled):
            return "libghostty engine experiment turned \(enabled ? "on" : "off")"
        }
    }

    /// Logs the notice at `.notice`. Every part of the message is the app's
    /// own words, a terminal id or an error's description.
    static func log(_ notice: TerminalEngineNotice) {
        engineLogger.notice("\(notice.message, privacy: .public)")
    }

    // Exhaustive, so a new kind cannot be logged under another's name.
    private static func name(of kind: TerminalEngineKind) -> String {
        switch kind {
        case .swiftTerm: return "SwiftTerm"
        case .ghostty: return "libghostty"
        }
    }
}

/// Where a terminal engine is being built, which decides the kinds it may be.
enum TerminalEngineHost: Equatable, Sendable {
    /// A panel in the main area or the dock, on this transport.
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
    /// panels and local PTYs. A tmux panel stays on SwiftTerm,
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

    /// - Parameter experimentEnabled: whether `useGhosttyTerminalEngine` is
    ///   on. It decides only whether a SwiftTerm build sends
    ///   `.active(.swiftTerm, ...)`. A libghostty build always sends its
    ///   notices, `.active(.ghostty, ...)` or, on a fallback, `.fallback` and
    ///   then `.active(.swiftTerm, ...)`, since only a libghostty request
    ///   makes such a build, and a copy of the flag that briefly disagrees
    ///   with the store must not hide which engine a terminal got. Required,
    ///   so no caller can leave the notices off by omission.
    /// - Parameter makeGhostty: builds the libghostty engine; the default is
    ///   `GhosttyEngine`'s initializer.
    /// - Parameter onFallback: told the kind that was asked for and why it
    ///   could not be built, once per fallback. A test passes its own to
    ///   observe the fallback.
    /// - Parameter onNotice: where the notices go; the default logs them. A
    ///   test passes its own to read them.
    static func make(
        kind: TerminalEngineKind,
        font: NSFont,
        appearance: AppearanceSettings,
        configuration: TerminalEngineConfiguration,
        experimentEnabled: Bool,
        makeGhostty: GhosttyMaker = TerminalEngineFactory.makeGhosttyEngine,
        onFallback: (_ requested: TerminalEngineKind, _ reason: String) -> Void = { _, _ in },
        onNotice: (TerminalEngineNotice) -> Void = TerminalEngineNotice.log
    ) -> any TerminalEngine {
        let terminal = describe(configuration)
        switch kind {
        case .swiftTerm:
            if experimentEnabled { onNotice(.active(.swiftTerm, terminal: terminal)) }
            return SwiftTermEngine(font: font, appearance: appearance, configuration: configuration)
        case .ghostty:
            do {
                let engine = try makeGhostty(font, appearance, configuration)
                onNotice(.active(.ghostty, terminal: terminal))
                return engine
            } catch {
                let reason = Self.reason(for: error)
                onFallback(.ghostty, reason)
                onNotice(.fallback(terminal: terminal, reason: reason))
                onNotice(.active(.swiftTerm, terminal: terminal))
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

    /// How a notice names the terminal: its id, or "a local PTY", which has
    /// none.
    nonisolated static func describe(_ configuration: TerminalEngineConfiguration) -> String {
        configuration.terminalID?.uuidString ?? "a local PTY"
    }
}
