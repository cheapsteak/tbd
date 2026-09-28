import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "prBinding")

/// Binds the PRs a provider names in a session's `meta.prs` to that session's
/// worktree row, as `.provider`
/// (`docs/specs/2026-09-26-remote-session-status-bar-design.md`).
///
/// The list is a pointer, never a status, and never an unbind: status comes
/// from TBD's own forge lookup, and only the user's detach removes a binding,
/// so a URL dropping out of `prs` changes nothing. Tombstone refusal and dedupe
/// are the coordinator's; this type adds only "adopted remote rows only" and
/// the per-session cap (`RemoteSessionPayload.maxProviderPRs`, applied by the
/// parser).
///
/// No new durable resource: bindings are rows in the existing binding store
/// and follow their worktree row's lifecycle.
struct ProviderPRBinder: Sendable {
    let findRow: @Sendable (_ provider: String, _ sessionID: String) async -> Worktree?
    let bind: @Sendable (_ worktreeID: UUID, _ parsed: ParsedPRURL) async -> PRBindingCoordinator.BindOutcome

    init(findRow: @escaping @Sendable (_ provider: String, _ sessionID: String) async -> Worktree?,
         bind: @escaping @Sendable (_ worktreeID: UUID, _ parsed: ParsedPRURL) async
            -> PRBindingCoordinator.BindOutcome) {
        self.findRow = findRow
        self.bind = bind
    }

    /// The production wiring: rows from the worktree store, binds through the
    /// coordinator's policy as `.provider`.
    init(db: TBDDatabase, coordinator: PRBindingCoordinator) {
        self.init(
            findRow: { provider, sessionID in
                try? await db.worktrees.findRemote(provider: provider, sessionID: sessionID)
            },
            bind: { worktreeID, parsed in
                await coordinator.bind(worktreeID: worktreeID, parsed: parsed, source: .provider)
            })
    }

    /// Bind every session's named PRs to its row. A session with no `prs` key
    /// costs nothing — no row lookup. A session with no row, or whose row is
    /// not remote (a landed lane is `.local`, though `findRemote` still
    /// returns it by its retained origin), gets nothing. Deferred or refused
    /// outcomes are logged and simply retried on the next snapshot.
    func bindNamedPRs(sessions: [RemoteSessionPayload], provider: String) async {
        for session in sessions {
            guard let list = RemoteSessionPayload.metaPRs(session.meta) else { continue }
            for entry in list.rejected {
                logger.info("ignoring unparseable prs entry for \(provider, privacy: .public)/\(session.id, privacy: .public): \(entry, privacy: .public)")
            }
            if !list.overflow.isEmpty {
                logger.info("ignoring \(list.overflow.count, privacy: .public) prs entries past the cap of \(RemoteSessionPayload.maxProviderPRs, privacy: .public) for \(provider, privacy: .public)/\(session.id, privacy: .public)")
            }
            guard !list.accepted.isEmpty,
                  let row = await findRow(provider, session.id),
                  case .remote = row.location else { continue }
            for parsed in list.accepted {
                let outcome = await bind(row.id, parsed)
                logger.debug("provider PR #\(parsed.number, privacy: .public) for worktree \(row.id.uuidString, privacy: .public): \(String(describing: outcome), privacy: .public)")
            }
        }
    }
}
