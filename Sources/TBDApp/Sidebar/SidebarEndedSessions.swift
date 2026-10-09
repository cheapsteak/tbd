import Foundation
import TBDShared

/// An ordered session list split into live and ended halves, for the
/// "Collapse ended remote sessions" sidebar option.
///
/// A session is ended when it is `gone` (its provider no longer reports it) or
/// its recorded process state is `.exited`. That decision reads the recorded
/// facts only, never provider freshness: unlike `SidebarRemoteGroups.state`,
/// which reports `.unknown` for a stale provider, a stale provider here does
/// not move a recorded-exited row back inline. Running, starting and unknown
/// sessions stay live.
///
/// Both halves keep the input order. Pure, so it is directly testable without
/// an `AppState` or a view.
struct SidebarEndedSessions {
    let live: [RemoteSessionInfo]
    let ended: [RemoteSessionInfo]
    let endedIDs: Set<UUID>
    /// `counts[.gone]` holds gone sessions; `counts[.exited]` holds
    /// exited-but-not-gone ones. `attention` is the most severe unread type
    /// over the ended sessions, ignoring routine completions.
    let summary: SidebarRemoteGroups.Summary

    var hasEnded: Bool { !ended.isEmpty }

    nonisolated static func isEnded(_ session: RemoteSessionInfo) -> Bool {
        session.gone || session.payload.state == .exited
    }

    init(sessions: [RemoteSessionInfo], unread: [RemoteSessionSelection: UnreadSummary]) {
        var live: [RemoteSessionInfo] = [], ended: [RemoteSessionInfo] = []
        var summary = SidebarRemoteGroups.Summary()
        for session in sessions {
            guard Self.isEnded(session) else { live.append(session); continue }
            ended.append(session)
            summary.counts[session.gone ? .gone : .exited, default: 0] += 1
            let key = RemoteSessionSelection(provider: session.provider, sessionID: session.payload.id)
            let candidates = [summary.attention, unread[key]?.type].compactMap { $0 }
                .filter { $0 != .responseComplete && $0 != .taskComplete }
            summary.attention = candidates.max { $0.severity < $1.severity }
        }
        self.live = live
        self.ended = ended
        self.endedIDs = Set(ended.map(\.id))
        self.summary = summary
    }
}
