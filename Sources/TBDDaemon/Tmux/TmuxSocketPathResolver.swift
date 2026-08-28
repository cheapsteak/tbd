import Foundation

/// Where a tmux server's socket file actually lives: `tmux -L <name>` resolves
/// `${TMUX_TMPDIR:-/tmp}/tmux-<uid>/<name>`, and this reproduces that rule.
///
/// The daemon has to answer this, not the caller. A CLI running in the user's
/// shell may hold a different `TMUX_TMPDIR` than the process that created the
/// server, so a shell-side `tmux -L <name> display-message -p '#{socket_path}'`
/// would answer for the wrong path — or start a fresh empty server in order to
/// answer at all. Nothing under `Sources/` sets the variable, so the daemon's
/// own environment is the one the servers it spawned were created under.
///
/// Both inputs are injected with production defaults, so the resolution is
/// unit-testable without `setenv` — see `Tests/CLAUDE.md`, which forbids
/// `setenv` outside `TBDHomeSerialized`.
public struct TmuxSocketPathResolver: Sendable {
    private let environment: [String: String]
    private let uid: uid_t

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        uid: uid_t = getuid()
    ) {
        self.environment = environment
        self.uid = uid
    }

    /// The absolute socket path for a server addressed by name.
    public func socketPath(server: String) -> String {
        "\(socketDirectory)/\(server)"
    }

    /// `${TMUX_TMPDIR:-/tmp}/tmux-<uid>` — the directory tmux keeps one socket
    /// per server in.
    public var socketDirectory: String {
        let base = temporaryDirectory
        // `/` is the one base that already ends in a separator after
        // normalization, so it composes by hand rather than by interpolation.
        return base == "/" ? "/tmux-\(uid)" : "\(base)/tmux-\(uid)"
    }

    /// `${TMUX_TMPDIR:-/tmp}`, with the shell's `:-` semantics: an *empty*
    /// value falls back exactly as an unset one does, which is what tmux itself
    /// does with the variable.
    private var temporaryDirectory: String {
        guard let value = environment["TMUX_TMPDIR"], !value.isEmpty else { return "/tmp" }
        // A trailing slash would compose `/tmp//tmux-501`. Harmless to the
        // kernel, but the path is shown to a human and pasted into a command,
        // so normalize it — while never letting a bare `/` normalize to "".
        var trimmed = value
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }
}
