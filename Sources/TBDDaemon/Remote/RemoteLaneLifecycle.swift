import Foundation
import TBDShared

/// The remote half of retiring and reviving a lane
/// (`docs/specs/2026-08-16-remote-lane-archive-design.md`, "Archive",
/// "Revive", and "Where the branches live"). Two layers, deliberately split:
///
/// - The **static** members below are pure decisions. No I/O, no actor, no
///   provider calls, no DB access — they only turn a provider's declared
///   capabilities (and the row's current status) into a plan, so the routing
///   rules are testable without a provider process.
/// - The **instance** members, in `RemoteLaneLifecycle+Actuate.swift`, hold
///   the provider manager and the worktree store and carry a plan out. The
///   archive and revive handlers and the merge rail branch into them on
///   location; the local path beneath `getLocal` is untouched.
struct RemoteLaneLifecycle: Sendable {
    let db: TBDDatabase
    let subscriptions: StateSubscriptionManager
    let manager: RemoteProviderManager

    init(db: TBDDatabase, subscriptions: StateSubscriptionManager, manager: RemoteProviderManager) {
        self.db = db
        self.subscriptions = subscriptions
        self.manager = manager
    }

    /// What `worktree.archive` should do with a remote row, decided purely
    /// from the provider's declared capabilities and whether the row is
    /// currently `gone`.
    enum RemoteLaneArchivePlan: Equatable {
        /// The provider declares `archive`: call it, then mark the row
        /// archived. Wins even when the row is `gone` — a `not_found` from
        /// the provider is handled at the call site, not here.
        case invokeVerb
        /// The provider declares no `archive`, but the row is `gone`: mark
        /// it archived and call nothing. There is no live session to
        /// misdescribe and no verb that could reach it.
        case rowOnlyGone
        /// The provider declares no `archive`, and the row is not `gone`:
        /// refuse. The message names `archive` as the missing capability.
        case refused(String)
    }

    /// What `worktree.revive` should do with a remote row, decided purely
    /// from the provider's declared capabilities and what the provider
    /// currently reports about `archived`.
    enum RemoteLaneRevivePlan: Equatable {
        /// The provider declares `unarchive`: call it, then flip the row to
        /// active.
        case invokeUnarchive
        /// The provider declares no `unarchive`, and no `archive` decision
        /// TBD made stands to be reversed by anything but TBD itself: flip
        /// the row, call nothing. Only reachable for a lane TBD filed under
        /// the `gone` exemption — the provider never claimed it archived.
        case rowOnly
        /// The provider declares no `unarchive`, and currently reports the
        /// session archived: refuse rather than flip a row the provider
        /// will keep asserting is archived on the next snapshot. The
        /// message names `unarchive` and says the retirement stands on the
        /// backend until it exists.
        case refusedNoUnarchive(String)
    }

    /// What Revive means for an archived remote lane once the question "is
    /// there still a session to unarchive?" has been asked
    /// (`docs/specs/2026-09-02-remote-session-delete-and-transcript-exchange-design.md`,
    /// "A deleted lane keeps its place").
    ///
    /// A deleted lane is archived like any other, and the row is deliberately
    /// kept — with its branch, its PR context, and its place in the repo's
    /// Archived tab. What it no longer has is a session: `delete` destroyed it
    /// and the mirror row went with it. So Revive on such a row cannot mean
    /// `unarchive`; it means creating a new session seeded from the transcript
    /// the delete retained. The gesture, the place and the word already mean
    /// this, which is why it is not a second button.
    enum RemoteLaneReseedPlan: Equatable {
        /// Create a new session seeded from this key, and rebind the row to it.
        case reseed(key: String)
        /// The provider's stated expiry has passed. Refuse, naming the date.
        /// The row stays as history — a lane whose conversation lapsed is
        /// still a record of work that happened.
        case expired(String)
        /// A receipt survives, but this provider cannot begin a session from
        /// one. Refuse naming `seed` rather than sending it and hoping: the
        /// contract has providers ignore stdin fields they do not recognize,
        /// so an unchecked reseed would produce an empty session wearing a
        /// revived lane's name.
        case refusedNoSeed(String)
        /// Nothing about this lane calls for a reseed — take the ordinary
        /// archive/unarchive path, unchanged.
        case unarchive
    }

    /// Decides whether `worktree.revive` on a remote lane means reseeding.
    ///
    /// `sessionStillListed` is the discriminator, and it is the mirror row's
    /// existence rather than anything about the receipt. A receipt on its own
    /// proves only that somebody retained a transcript — `tbd remote retain`
    /// is an ordinary thing to do to a session that is alive and well, and
    /// reviving *that* lane must still be an `unarchive`. `remote.delete` drops
    /// the mirror row the instant the provider confirms the destruction, so an
    /// archived lane with a receipt and no row is the deleted one.
    ///
    /// `now` is passed rather than read: `expiresAt` is a persisted timestamp
    /// compared against the present, which is the date seam and not the clock
    /// seam (`Duration` is behavior; `Date` is data).
    ///
    /// Messages come back bare, as `archivePlan`'s and `revivePlan`'s do, and
    /// the caller prefixes them with the lane's name.
    static func reseedPlan(
        receipt: RetainedTranscript?, sessionStillListed: Bool,
        capabilities: Set<String>, now: Date
    ) -> RemoteLaneReseedPlan {
        guard !sessionStillListed else { return .unarchive }
        guard let receipt else { return .unarchive }
        if receipt.hasExpired(asOf: now), let expiresAt = receipt.expiresAt {
            return .expired(
                "the transcript retained from its session expired on " +
                "\(RetainReceipt.formatTimestamp(expiresAt)), so there is nothing left to " +
                "recreate the conversation from. The row stays as a record of the work."
            )
        }
        guard capabilities.contains("seed") else {
            return .refusedNoSeed(
                "its session was destroyed, so reviving it means creating a new one seeded " +
                "from the retained transcript — and this provider does not declare the " +
                "\"seed\" capability. See docs/remote-provider-contract.md"
            )
        }
        return .reseed(key: receipt.key)
    }

    /// Decides how `worktree.archive` should treat a remote row.
    ///
    /// Order matters: a provider that declares `archive` takes the verb
    /// path even for a `gone` lane (rule 1 checked before `isGone`). This
    /// function never inspects `"stop"` — ending compute and retiring a
    /// record are different acts, and a provider declaring only `stop` must
    /// fall through to `.refused`.
    static func archivePlan(capabilities: Set<String>, isGone: Bool) -> RemoteLaneArchivePlan {
        if capabilities.contains("archive") {
            return .invokeVerb
        }
        if isGone {
            return .rowOnlyGone
        }
        return .refused(
            "this provider does not declare the \"archive\" capability, so this session " +
            "cannot be retired from its working inventory; see docs/remote-provider-contract.md"
        )
    }

    /// Decides how `worktree.revive` should treat a remote row.
    ///
    /// `providerReportsArchived` is the provider's *current* report, not
    /// how the row came to be archived — that is the discriminator the
    /// spec calls for, since no provenance is persisted. This function
    /// never inspects `"stop"`.
    static func revivePlan(capabilities: Set<String>, providerReportsArchived: Bool) -> RemoteLaneRevivePlan {
        if capabilities.contains("unarchive") {
            return .invokeUnarchive
        }
        if providerReportsArchived {
            return .refusedNoUnarchive(
                "this provider does not declare the \"unarchive\" capability, so this session " +
                "cannot be returned to its working inventory; the retirement stands on the " +
                "backend until it does. See docs/remote-provider-contract.md"
            )
        }
        return .rowOnly
    }

    // MARK: - Guards on the verb path

    /// The optional well-known `meta` key through which a provider reports
    /// that the session's checkout has work that is not committed or not
    /// pushed (`docs/remote-provider-contract.md` § Session object).
    ///
    /// TBD cannot see a remote working tree, and the `working` guard does
    /// not cover this case: an idle agent sitting on unpushed work looks
    /// safe to retire. A provider that knows its checkout is dirty says so
    /// here; one that says nothing degrades to the `working` guard alone.
    /// **The guard is therefore inert until a provider adopts the key, and
    /// TBD never fabricates the fact.**
    static let dirtyWorkspaceMetaKey = RemoteSessionPayload.dirtyWorkspaceMetaKey

    /// Reads the dirty-checkout claim out of a session's `meta`.
    ///
    /// The reading itself lives on `RemoteSessionPayload` in `TBDShared`,
    /// because the app's delete confirmation asks the same question of the same
    /// key and two copies of a rule this sharp would drift. This name stays as
    /// the daemon's way in.
    static func metaReportsDirtyWorkspace(_ meta: [String: String]?) -> Bool {
        RemoteSessionPayload.metaReportsDirtyWorkspace(meta)
    }

    /// The refusal for a lane whose agent is mid-task. Parallels how local
    /// archive refuses on uncommitted changes: do not retire a session
    /// mid-task by accident.
    static func workingGuardRefusal(_ name: String) -> String {
        "Cannot archive \(name): its agent is still working. Re-run with --force to retire it anyway."
    }

    /// The refusal for a lane whose provider's cached inventory has gone
    /// stale — the same gate every `remote.*` mutation passes, and load
    /// bearing here for a sharper reason than elsewhere.
    ///
    /// Both of archive's guards are read out of the mirror (`agentState`, and
    /// `meta.workspace_dirty`). On a stale mirror a session that was idle at
    /// the last good poll and is working now reads as safe, the guards pass,
    /// and a mid-task session is retired — exactly what the guards exist to
    /// prevent. Refusing keeps a *provider call* from resting on an inventory
    /// TBD already knows it cannot trust.
    ///
    /// **It therefore covers the verb paths and nothing else.** The row-only
    /// paths make no provider call and read nothing out of the mirror they
    /// could be wrong about; gating them would strand the `gone` exemption —
    /// the only route out for a lane whose provider cannot archive — behind a
    /// `--force` that revive does not have and the row menu never sends.
    static func staleSnapshotRefusal(_ name: String, provider: String) -> String {
        "Cannot act on \(name): provider '\(provider)' inventory is stale; refresh must recover " +
        "before changing remote sessions."
    }

    /// The refusal for a lane whose provider reports an unclean checkout.
    static func dirtyWorkspaceGuardRefusal(_ name: String) -> String {
        "Cannot archive \(name): its provider reports the session's checkout has uncommitted work " +
        "(meta.\(dirtyWorkspaceMetaKey)). Re-run with --force to retire it anyway."
    }
}
