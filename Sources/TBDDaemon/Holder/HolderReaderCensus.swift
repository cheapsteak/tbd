import Foundation
import os

/// Who may be reading one holder-backed session's pty master.
///
/// A viewer carries the attach generation it was vended under, because that is
/// the only thing that distinguishes one viewer's claim on a pty from its
/// successor's — and a departure that did not name the generation would let a
/// closing viewer's detach take its successor off the census.
enum PtyReaderRole: Sendable, Equatable, CustomStringConvertible {
    /// The daemon's own `HolderReader`, draining into its headless emulator.
    case daemon
    /// A viewer holding a `dup` of the master, read directly in the app.
    case viewer(attach: UInt64)

    var description: String {
        switch self {
        case .daemon: return "daemon"
        case .viewer(let attach): return "viewer-attach-\(attach)"
        }
    }
}

/// The daemon's explicit per-session reader state, and the always-on detector
/// built on it.
///
/// **The transport's central safety property is that exactly one process reads
/// a session's pty master at a time**, and the failure mode is silent: two
/// `read()`s on one master each take bytes the other never sees, and nothing in
/// the kernel, the holder, the daemon or the app reports it. So an absence of
/// corruption reports is not evidence of correctness, and "no double-reader
/// violations" is only evidence if something can see one. This is that
/// something.
///
/// It is a ledger rather than a counter: every transition into reading declares
/// who is entering and asserts the session's count was zero first, so the
/// detector sees the fault at the instant it is committed rather than inferring
/// it afterwards from a screen that went wrong. The arbitration in
/// `HolderRegistry` is what *keeps* the invariant; this is what reports the
/// arbitration being wrong.
///
/// **A violation is never fatal.** It increments a monotonic counter and logs
/// loudly, and the newcomer is recorded as the session's reader so the ledger
/// keeps tracking rather than wedging on one bad transition. A `precondition`
/// here would turn a benign ordering race into a daemon crash that takes every
/// other session's drain with it — strictly worse than the fault it would be
/// announcing.
///
/// Held by `HolderRegistry` and mutated only on that actor, which is what makes
/// a plain struct the right shape: the arbitration decisions and the ledger
/// writes land on the same isolation, so no transition can be recorded out of
/// order with the decision that made it.
struct HolderReaderCensus: Sendable {
    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "holder")

    /// One transition into reading that found the session already being read.
    ///
    /// It carries both roles and the site that made the transition, because the
    /// whole value of catching this is being able to say *which* two readers
    /// and *which* arbitration step put the second one on the pty — a bare
    /// count says only that the transport is unsafe, not where.
    struct Violation: Sendable, Equatable, CustomStringConvertible {
        /// The session whose master had two readers.
        let sessionID: UUID
        /// The reader this transition was putting on the pty.
        let entering: PtyReaderRole
        /// The reader the ledger already held for that session.
        let incumbent: PtyReaderRole
        /// The arbitration step that made the transition, as a short literal —
        /// `attach-vend`, `publish`, `handback-resume`.
        let site: String

        var description: String {
            "session=\(sessionID.uuidString) entering=\(entering) incumbent=\(incumbent) "
                + "site=\(site)"
        }
    }

    /// How many transitions into reading have found a reader already counted
    /// for that session. Monotonic for the daemon's life.
    ///
    /// **This is the number graduation reads.** Anything above zero is byte
    /// theft that happened, seen at the moment it happened.
    private(set) var violations = 0
    /// The most recent violation, kept so the periodic summary can name one
    /// without a reader having to go and find the `.error` line it came from.
    private(set) var lastViolation: Violation?

    /// Who is reading each session's master. Absent means nobody — which is a
    /// real and expected state (the attach liveness gate, a failed resume, a
    /// daemon outage) and costs queued output rather than correctness.
    private var readers: [UUID: PtyReaderRole] = [:]

    /// How many sessions are being read right now.
    var sessionsBeingRead: Int { readers.count }

    /// How many of those the daemon is reading itself.
    var sessionsReadByTheDaemon: Int {
        readers.values.filter { $0 == .daemon }.count
    }

    /// Who the ledger holds as a session's reader, or nil when nobody is.
    ///
    /// The honest instrument for "who is on this pty": `HolderRegistry.reader`
    /// answers for a suspended reader too, and `viewerAttachment` answers "a
    /// viewer *may* hold this" — neither is the same question.
    func reader(of sessionID: UUID) -> PtyReaderRole? { readers[sessionID] }

    /// Records a reader going onto a session's master, asserting first that
    /// nobody was on it.
    ///
    /// The returned violation is for a caller that wants to act on one; the
    /// counter and the log line happen either way, so no call site has to
    /// remember to report.
    @discardableResult
    mutating func beganReading(
        _ role: PtyReaderRole, session sessionID: UUID, at site: String
    ) -> Violation? {
        guard let incumbent = readers[sessionID] else {
            readers[sessionID] = role
            return nil
        }
        let violation = Violation(
            sessionID: sessionID, entering: role, incumbent: incumbent, site: site)
        violations += 1
        lastViolation = violation
        // Recorded anyway: the ledger's job from here is to keep describing the
        // newest claim, not to freeze on the first disagreement. A ledger that
        // stopped tracking would hide every later transition behind one fault.
        readers[sessionID] = role
        // Both values are copied into locals first. `Logger`'s interpolations
        // are escaping autoclosures, and a mutating method may not let one
        // capture `self` — so interpolating `violations` or `violation` through
        // a property read here does not compile.
        let detail = violation.description
        let count = violations
        Self.logger.error(
            """
            holder-reader-violation \(detail, privacy: .public) \
            violations=\(count, privacy: .public) — two readers on one pty master steal each \
            other's bytes silently; this session's output is unreliable from here
            """)
        return violation
    }

    /// Records a reader leaving a session's master.
    ///
    /// **Generation-checked, like every other "still mine?" on this transport.**
    /// A departure that does not match the recorded reader is ignored rather
    /// than applied: a closing viewer's detach can arrive after a successor's
    /// attach owns the pty, and clearing the successor would make the next
    /// transition into reading look clean when it is the second reader.
    ///
    /// Leaving is never a violation — two readers leaving is one reader leaving
    /// twice — so this neither counts nor logs.
    mutating func stoppedReading(_ role: PtyReaderRole, session sessionID: UUID) {
        guard readers[sessionID] == role else { return }
        readers[sessionID] = nil
    }

    /// Drops a session from the ledger entirely, for a session that no longer
    /// exists.
    ///
    /// A hygiene sweep on the teardown path, not an arbitration step: every
    /// reader a released session had is recorded as leaving by the step that
    /// stopped it, so this should normally find nothing. It exists so a
    /// long-lived daemon's ledger cannot grow an entry per session it has ever
    /// torn down.
    mutating func forget(session sessionID: UUID) {
        readers[sessionID] = nil
    }

    /// The one line a human reads weeks later to answer "did the soak see any
    /// double-reader violations?".
    ///
    /// `key=value` per `docs/diagnostics-strategy.md`, and it always names the
    /// count — including when it is zero, which is the whole point. Absence of
    /// an `.error` line is the unaided observation this detector exists to
    /// replace; a periodic line that says `violations=0` is positive evidence
    /// that something was watching and saw nothing.
    var summary: String {
        let viewers = sessionsBeingRead - sessionsReadByTheDaemon
        return """
            holder-reader-census violations=\(violations) sessions-read=\(sessionsBeingRead) \
            daemon-read=\(sessionsReadByTheDaemon) viewer-read=\(viewers) \
            last-violation=\(lastViolation?.description ?? "none")
            """
    }
}
