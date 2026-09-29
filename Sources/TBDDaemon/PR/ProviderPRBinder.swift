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
    let providerCapacity: @Sendable (_ worktreeID: UUID) async -> PRBindingStore.ProviderBindingCapacity

    init(findRow: @escaping @Sendable (_ provider: String, _ sessionID: String) async -> Worktree?,
         bind: @escaping @Sendable (_ worktreeID: UUID, _ parsed: ParsedPRURL) async
            -> PRBindingCoordinator.BindOutcome,
         providerCapacity: @escaping @Sendable (_ worktreeID: UUID) async
            -> PRBindingStore.ProviderBindingCapacity) {
        self.findRow = findRow
        self.bind = bind
        self.providerCapacity = providerCapacity
    }

    /// The production wiring: rows from the worktree store, binds through the
    /// coordinator's policy as `.provider`. A capacity read that fails to
    /// fetch reports full — the fail-closed reading, since binding is the
    /// action a corrupt read must not wave through unbounded.
    init(db: TBDDatabase, coordinator: PRBindingCoordinator) {
        self.init(
            findRow: { provider, sessionID in
                try? await db.worktrees.findRemote(provider: provider, sessionID: sessionID)
            },
            bind: { worktreeID, parsed in
                await coordinator.bind(worktreeID: worktreeID, parsed: parsed, source: .provider)
            },
            providerCapacity: { worktreeID in
                (try? await db.prBindings.providerBindingCapacity(worktreeID: worktreeID))
                    ?? PRBindingStore.ProviderBindingCapacity(
                        existingIdentityKeys: [], providerBindingCount: RemoteSessionPayload.maxProviderPRs)
            })
    }

    /// Bind every session's named PRs to its row. A session with no `prs` key
    /// costs nothing — no row lookup. A session with no row, or whose row is
    /// not remote (a landed lane is `.local`, though `findRemote` still
    /// returns it by its retained origin), gets nothing. Deferred or refused
    /// outcomes are logged and simply retried on the next snapshot.
    ///
    /// Two caps apply, and they guard different things. `metaPRs`'s `cap`
    /// bounds how many URLs one snapshot's `prs` value can make this method
    /// even look at — parse cost. This method separately bounds how many
    /// *new* `.provider` rows a worktree may ever accumulate, over every
    /// snapshot it has ever seen: a URL this worktree already has a row for
    /// (bound or tombstoned, by any source) is not new and costs nothing, so
    /// only a URL nobody has recorded here before spends from the cumulative
    /// allowance. Without this, a provider that rotates which PRs it names —
    /// closing old ones and naming fresh ones — could grow `.provider`
    /// bindings without bound: the per-snapshot cap resets every poll, and
    /// `PRBindingStore`'s own live-binding cap only counts undetached rows, so
    /// a closed or detached PR's slot looks free to it. Counting tombstoned
    /// `.provider` rows in the allowance closes that: a user's `tbd pr detach`
    /// does not hand the provider a slot back.
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

            let capacity = await providerCapacity(row.id)
            var knownKeys = capacity.existingIdentityKeys
            var remaining = max(0, RemoteSessionPayload.maxProviderPRs - capacity.providerBindingCount)
            var newURLsSkipped = 0

            for parsed in list.accepted {
                let key = Self.identityKey(parsed)
                if !knownKeys.contains(key) {
                    guard remaining > 0 else {
                        newURLsSkipped += 1
                        continue
                    }
                    remaining -= 1
                    knownKeys.insert(key)
                }
                let outcome = await bind(row.id, parsed)
                logger.debug("provider PR #\(parsed.number, privacy: .public) for worktree \(row.id.uuidString, privacy: .public): \(String(describing: outcome), privacy: .public)")
            }
            if newURLsSkipped > 0 {
                logger.info("ignoring \(newURLsSkipped, privacy: .public) new provider PR URLs past the cumulative cap of \(RemoteSessionPayload.maxProviderPRs, privacy: .public) for \(provider, privacy: .public)/\(session.id, privacy: .public)")
            }
        }
    }

    /// Matches `PRBinding.identityKey` and the table's UNIQUE constraint.
    private static func identityKey(_ parsed: ParsedPRURL) -> String {
        "\(parsed.host.lowercased())\u{1}\(parsed.owner.lowercased())\u{1}\(parsed.repo.lowercased())\u{1}\(parsed.number)"
    }
}
