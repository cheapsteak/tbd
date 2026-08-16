import Foundation

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
    static let dirtyWorkspaceMetaKey = "workspace_dirty"

    /// Reads the dirty-checkout claim out of a session's `meta`.
    ///
    /// `meta` is a flat string-to-string map, so the claim arrives as text.
    /// Only `"true"` and `"1"` (trimmed, case-insensitively) are read as a
    /// claim; an absent key, an empty value, and anything unrecognized all
    /// mean "no claim was made" and leave the guard inert. Deliberately not
    /// a permissive truthiness test: this value decides whether a user's
    /// archive is refused, and inventing a claim out of a value a provider
    /// meant for display would refuse a gesture nobody asked to block.
    static func metaReportsDirtyWorkspace(_ meta: [String: String]?) -> Bool {
        guard let raw = meta?[dirtyWorkspaceMetaKey] else { return false }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "1": return true
        default: return false
        }
    }

    /// The refusal for a lane whose agent is mid-task. Parallels how local
    /// archive refuses on uncommitted changes: do not retire a session
    /// mid-task by accident.
    static func workingGuardRefusal(_ name: String) -> String {
        "Cannot archive \(name): its agent is still working. Re-run with --force to retire it anyway."
    }

    /// The refusal for a lane whose provider reports an unclean checkout.
    static func dirtyWorkspaceGuardRefusal(_ name: String) -> String {
        "Cannot archive \(name): its provider reports the session's checkout has uncommitted work " +
        "(meta.\(dirtyWorkspaceMetaKey)). Re-run with --force to retire it anyway."
    }
}
