import Foundation

/// Which emulator draws a terminal.
///
/// `swiftTerm` is the only engine the app builds today. `ghostty` names the
/// libghostty-vt engine that `docs/specs/2026-11-07-libghostty-terminal-engine-design.md`
/// adds behind a default-off flag; until that lands, `TerminalEngineFactory`
/// builds SwiftTerm for every kind.
enum TerminalEngineKind: String, Sendable, CaseIterable {
    case swiftTerm
    case ghostty
}

/// The facts a terminal view uses that its panel decides: who it is, where its
/// paths resolve, and how it routes the mouse.
///
/// Every field but `terminalID` can change under a live engine, and does:
/// `TerminalPanelRepresentable.updateNSView` re-applies `isCodexTerminal` and
/// the mouse routing on every update, because the transport can change once
/// AppState loads a terminal row the panel could not yet see. `terminalID` is
/// read once, at creation, to name the view in the Program Status Protocol
/// handshake records.
///
/// The defaults are a bare `TBDTerminalView`'s, so an engine built from
/// `TerminalEngineConfiguration()` behaves exactly like a view nobody
/// configured.
struct TerminalEngineConfiguration: Equatable, Sendable {
    /// The TBD terminal this engine shows. Nil for a view with no terminal row,
    /// such as a remote attach, whose handshake records say `terminal=unknown`.
    var terminalID: UUID?
    /// The directory a clicked relative path resolves against.
    var worktreePath: String
    /// The repository's remote, used to turn a clicked path into a link.
    var remoteURL: String?
    /// Whether the terminal runs Codex, whose image paste is a Ctrl-V.
    var isCodexTerminal: Bool
    /// Whether mouse events go to a program that has asked for them.
    var allowMouseReporting: Bool
    /// Whether an Option-drag selects locally even while a program holds the
    /// mouse.
    var optionBypassesMouseReporting: Bool

    init(
        terminalID: UUID? = nil,
        worktreePath: String = "",
        remoteURL: String? = nil,
        isCodexTerminal: Bool = false,
        allowMouseReporting: Bool = true,
        optionBypassesMouseReporting: Bool = false
    ) {
        self.terminalID = terminalID
        self.worktreePath = worktreePath
        self.remoteURL = remoteURL
        self.isCodexTerminal = isCodexTerminal
        self.allowMouseReporting = allowMouseReporting
        self.optionBypassesMouseReporting = optionBypassesMouseReporting
    }
}
