import Foundation

/// Pure decision functions for retiring and reviving a remote lane
/// (`docs/specs/2026-08-16-remote-lane-archive-design.md`, "Archive" and
/// "Revive"). No I/O, no actor, no provider calls, no DB access — this type
/// only turns a provider's declared capabilities (and the row's current
/// status) into a plan. Callers wire the plan to an actuation.
enum RemoteLaneLifecycle {
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
}
