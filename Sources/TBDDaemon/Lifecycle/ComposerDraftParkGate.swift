import Foundation
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "composer-draft")

/// What a park does with what the composer-draft feature knows about the
/// session. The session mod is the park's only guard for an unsent draft.
/// See `docs/specs/2026-10-24-mod-only-park-guard-design.md`, "Which parks go
/// ahead".
enum ComposerDraftParkDecision: Equatable, Sendable {
    /// The park goes on and ends Claude by signal.
    case proceed
    /// An automatic park the feature cannot vouch for: the session is skipped.
    /// `reason` is the `SessionModLiveness.UnknownReason` raw value.
    case skip(reason: String)
}

/// The park gate the session mod answers.
enum ComposerDraftParkGate {
    /// Every park of a session spawned without the feature, or one whose mod
    /// confirmed the draft, proceeds: the first has saved nothing and nothing
    /// can see its draft, the second has saved it. A session spawned with the
    /// feature whose mod is not confirmed proceeds for a manual park and a
    /// profile swap, which are gestures, and is skipped by the merge-park and
    /// the idle sweep, which nobody asked for: on a machine where the mod never
    /// loads, that condition never clears at a respawn.
    static func decide(
        status: ComposerDraftStatus,
        policy: HibernateEligibilityPolicy
    ) -> ComposerDraftParkDecision {
        switch status {
        case .legacy, .confirmed:
            return .proceed
        case .unknown(let unknown):
            switch policy {
            case .manual, .profileSwap:
                return .proceed
            case .merge, .automatic:
                return .skip(reason: unknown.rawValue)
            }
        }
    }

    /// The reason a skipped park records: the `.notEligible` reason the merge
    /// fan-out and the idle sweep's actuation row carry.
    static func skipReason(_ reason: String) -> String {
        "TBD can't confirm this session's draft is saved (\(reason))."
    }

    /// Logs a park the gate skipped. Automatic parks have no caller to tell,
    /// so the log is where the reason goes.
    static func logSkip(terminalID: UUID, reason: String) {
        logger.notice("composer-draft: skipped park of \(terminalID.uuidString, privacy: .public): \(reason, privacy: .public)")
    }
}
