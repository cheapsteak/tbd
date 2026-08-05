import Foundation

/// Who declared an actuation.
///
/// Identity here is **ambient declaration, never authentication** — any
/// process talking to the daemon socket can claim anything, and TBD
/// deliberately builds nothing stronger. The value of the declaration is that
/// the daemon writes it down at the moment it acts, so the record says plainly
/// which door an act came through, including "nobody said".
///
/// **Always a JSON object, never a bare string.** Several kinds inherently
/// carry fields (an identified session carries its coordinates; a supervisor
/// carries its project), so the object form is required anyway; keeping it
/// uniform means every consumer query reads `.actor.kind` and growing a kind
/// later never changes its JSON type.
///
/// `kind` is a `String` rather than an enum on purpose: kinds reserved for
/// later work (`supervisor`) must decode on a daemon that predates them
/// instead of failing the whole row. Use the static constructors and the
/// `Kind` namespace below rather than spelling literals at call sites.
public struct ActuationActor: Codable, Sendable, Equatable {
    /// Known kind names. Not an enum — see the type's doc comment.
    public enum Kind {
        public static let daemon = "daemon"
        public static let app = "app"
        public static let session = "session"
        public static let anonymous = "anonymous"
        /// Reserved for fleet supervisors; nothing writes it yet.
        public static let supervisor = "supervisor"
    }

    public var kind: String
    /// Names the daemon-internal subsystem for `kind == "daemon"` acts that a
    /// rail performed on its own schedule (`limit-resume`, `auto-hibernate`,
    /// `auto-hibernate-on-merge`, `nightwatch-desk`). Absent for daemon acts
    /// with no rail.
    public var rail: String?
    /// Uppercase worktree UUID string, for `kind == "session"`.
    public var worktree: String?
    /// Uppercase terminal UUID string, for `kind == "session"`.
    public var terminal: String?
    /// Reserved for `kind == "supervisor"`; nothing writes it yet.
    public var project: String?

    public init(
        kind: String,
        rail: String? = nil,
        worktree: String? = nil,
        terminal: String? = nil,
        project: String? = nil
    ) {
        self.kind = kind
        self.rail = rail
        self.worktree = worktree
        self.terminal = terminal
        self.project = project
    }

    /// The daemon acting on its own behalf, optionally naming the internal rail.
    public static func daemon(rail: String? = nil) -> ActuationActor {
        ActuationActor(kind: Kind.daemon, rail: rail)
    }

    /// The macOS app's RPC client — the operator's hand.
    public static let app = ActuationActor(kind: Kind.app)

    /// No identity was declared. Explicit rather than an absent field: the
    /// record must say plainly that the caller was anonymous.
    public static let anonymous = ActuationActor(kind: Kind.anonymous)

    /// An identified caller echoing the coordinates the daemon itself planted
    /// in its environment at spawn time. A partial declaration (only one
    /// variable set) carries just the declared field; declaring neither is
    /// anonymity, not a session, so this returns `nil` and the caller omits
    /// the field entirely.
    public static func session(worktree: String?, terminal: String?) -> ActuationActor? {
        let worktree = worktree.flatMap { $0.isEmpty ? nil : $0 }
        let terminal = terminal.flatMap { $0.isEmpty ? nil : $0 }
        if worktree == nil && terminal == nil { return nil }
        return ActuationActor(kind: Kind.session, worktree: worktree, terminal: terminal)
    }

    /// Reads a session declaration out of the ambient TBD environment.
    /// Returns `nil` when neither variable is set.
    public static func sessionFromEnvironment(_ environment: [String: String]) -> ActuationActor? {
        session(
            worktree: environment["TBD_WORKTREE_ID"],
            terminal: environment["TBD_TERMINAL_ID"])
    }
}
