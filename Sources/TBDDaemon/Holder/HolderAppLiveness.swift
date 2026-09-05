import Foundation
import os

/// What the daemon has established about the app that was on the other end of a
/// sidecar connection.
///
/// Three values, and only one of them licenses the daemon to read a pty again.
/// Each carries the reason it reached, because the whole risk on this path is a
/// seizure — or a stall — nobody can explain afterwards.
enum AppLivenessVerdict: Sendable, Equatable {
    /// The recorded pid still names that same process. It is holding its
    /// `dup`s and may be reading them right now.
    case alive
    /// The recorded pid names nothing, or names a stranger. Its descriptors
    /// closed with it, so nothing it held can still be read by it.
    ///
    /// That implication is exact for the first case and holds for the second
    /// only under one qualification, which `execve` breaks: an exec preserves
    /// the pid *and* the start time while replacing the command line, and it
    /// does not close descriptors that lack `FD_CLOEXEC`. An app that exec'd
    /// itself in place, and whose sidecar connection had also dropped, would
    /// therefore be read as `pid-reused-executable` and have its sessions
    /// seized while its `dup`s were still live and readable. Left as it is
    /// because a macOS GUI app does not re-exec itself in place — but the whole
    /// design rests on "confirmed gone ⟹ descriptors closed", so the one shape
    /// that would falsify it is named here rather than left to be rediscovered.
    case confirmedGone(reason: String)
    /// Something could not be read. **Not** death: the failure direction on
    /// this path is always toward reading nothing until liveness says
    /// otherwise, so this is handled exactly as `alive` is.
    case undetermined(reason: String)

    /// Whether this verdict licenses taking sessions back from the app.
    var licensesSeizure: Bool {
        if case .confirmedGone = self { return true }
        return false
    }
}

/// Decides whether the app that owned a sidecar connection is gone.
///
/// **A sidecar disconnect is not death.** The sidecar reconnects — that is a
/// designed path, not a hope — so a socket drop can leave the app alive,
/// holding its `dup`s and still reading them. Seizing then puts the daemon's
/// drain on a pty another process is reading, which is the double-reader byte
/// theft this whole transport exists to prevent and the one failure it cannot
/// recover from.
///
/// So the drop is not the evidence. The evidence is the recorded identity of
/// the process that connected, re-verified through `ProcessIdentityCheck` —
/// **the same check `AgentReaper`'s holder leg uses before it signals
/// anything**, for the same reason: a pid the kernel has handed to somebody
/// else would otherwise report a dead app as running, and every session that
/// app was holding would stay unread, unwritable and un-reopenable for as long
/// as the stranger lives.
///
/// The tolerance is zero, and that differs from the reaper's five-minute window
/// deliberately. The reaper anchors on a session row's `createdAt`, which is a
/// *proxy* for when its job started; this anchors on the app's own start time,
/// read from the kernel at the moment the connection was adopted. When the
/// recorded fact is the fact itself, anything but equality is a different
/// process.
struct AppLivenessArbiter: Sendable {
    let signaller: any ProcessSignaller

    init(signaller: any ProcessSignaller) {
        self.signaller = signaller
    }

    /// The verdict for one recorded identity, or `undetermined` when there is
    /// none — an unidentified peer names no pid to ask about, and must never
    /// license a seizure.
    func verdict(for identity: ProcessIdentity?) -> AppLivenessVerdict {
        guard let identity else { return .undetermined(reason: "identity-unrecorded") }
        switch ProcessIdentityCheck.verify(
            pid: identity.pid,
            startedWithin: 0,
            of: identity.startedAt,
            executableIsAcceptable: { $0 == identity.commandLine },
            signaller: signaller
        ) {
        case .same:
            return .alive
        case .notRunning:
            return .confirmedGone(reason: "process-gone")
        case .startTimeMismatch:
            return .confirmedGone(reason: "pid-reused-start-time")
        case .foreignExecutable:
            return .confirmedGone(reason: "pid-reused-executable")
        case .startTimeUnreadable:
            return .undetermined(reason: "start-time-unreadable")
        case .commandUnreadable:
            return .undetermined(reason: "command-unreadable")
        }
    }
}

/// The arbitration itself: what the daemon does when the app's sidecar
/// connection goes away.
///
/// It is a value with one seam rather than a method on the daemon so that the
/// decision — which is the whole of this task — can be stated and tested
/// without a pty, a holder, or a process to kill. `reclaim` is the action a
/// confirmed death licenses, and nothing else in this type may take it.
struct SidecarDisconnectArbiter: Sendable {
    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "holder")

    let liveness: AppLivenessArbiter
    /// Reverts every session the app was holding to daemon-read, and answers
    /// with the ones it took back. Called **only** on a confirmed death.
    let reclaim: @Sendable () async -> [UUID]

    init(liveness: AppLivenessArbiter, reclaim: @escaping @Sendable () async -> [UUID]) {
        self.liveness = liveness
        self.reclaim = reclaim
    }

    /// Arbitrates one disconnect and answers what it concluded.
    ///
    /// The verdict is returned rather than merely logged because it is the
    /// thing under test: "the daemon stayed off the descriptors" and "the
    /// daemon never noticed the drop" are the same absence of action from
    /// outside, and only one of them is correct.
    @discardableResult
    func handleDisconnect(identity: ProcessIdentity?) async -> AppLivenessVerdict {
        let verdict = liveness.verdict(for: identity)
        guard verdict.licensesSeizure else {
            Self.logger.info(
                """
                the app's sidecar connection dropped and the app is \
                \(String(describing: verdict), privacy: .public); the daemon stays off every pty it \
                holds and awaits the reconnect and the re-claim
                """)
            return verdict
        }
        let reclaimed = await reclaim()
        Self.logger.info(
            """
            the app that held \(reclaimed.count, privacy: .public) session(s) is confirmed gone \
            (\(String(describing: verdict), privacy: .public)); every session it held has reverted \
            to daemon-read
            """)
        return verdict
    }
}
