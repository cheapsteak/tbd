import Foundation
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "composer-draft")

/// What a park does with what the composer-draft feature knows about the
/// session. See `docs/specs/2026-10-19-tbd-session-mod-design.md`, "Parking".
enum ComposerDraftParkDecision: Equatable, Sendable {
    /// Spawned without the feature: today's rails decide, the pending-input
    /// scrape among them.
    case legacy
    /// The park goes on and the pending-input scrape never refuses it: the
    /// feature confirmed the draft is saved, or the park proceeds without that
    /// confirmation (a profile swap, or a manual park the person overrode).
    case proceed
    /// A manual park the feature cannot vouch for: the caller is asked, and a
    /// yes reissues the park with the override.
    case refuse(reason: String)
    /// An automatic park the feature cannot vouch for: the session is skipped.
    case skip(reason: String)
}

/// The park gate for sessions spawned with the composer-draft feature.
enum ComposerDraftParkGate {
    /// Legacy keeps the old path; confirmed proceeds; unknown proceeds for a
    /// profile swap or an overridden manual park, refuses any other manual
    /// park, and skips the merge-park and the idle sweep. The reason is the
    /// `UnknownReason` raw value.
    static func decide(
        status: ComposerDraftStatus,
        policy: HibernateEligibilityPolicy,
        overrideUnconfirmed: Bool
    ) -> ComposerDraftParkDecision {
        switch status {
        case .legacy:
            return .legacy
        case .confirmed:
            return .proceed
        case .unknown(let unknown):
            let reason = unknown.rawValue
            switch policy {
            case .profileSwap:
                return .proceed
            case .manual:
                return overrideUnconfirmed ? .proceed : .refuse(reason: reason)
            case .merge, .automatic:
                return .skip(reason: reason)
            }
        }
    }

    /// The log line for a park where the feature and the pending-input scrape
    /// disagree about whether the composer holds a draft, or nil when they
    /// agree.
    static func shadowDisagreement(
        terminalID: UUID, featureHasDraft: Bool, scrapeHasDraft: Bool
    ) -> String? {
        guard featureHasDraft != scrapeHasDraft else { return nil }
        return "composer-draft shadow disagreement terminal=\(terminalID.uuidString)"
            + " feature=\(word(featureHasDraft)) scrape=\(word(scrapeHasDraft))"
    }

    /// The refusal a person reads when TBD cannot confirm the draft is saved:
    /// the `terminal.hibernate` error, and the reason every other surface
    /// records for an unconfirmed or skipped park.
    static func unconfirmedRefusal(reason: String) -> String {
        "TBD can't confirm this session's draft is saved (\(reason))."
    }

    /// Logs a park the gate skipped. Automatic parks have no caller to tell,
    /// so the log is where the reason goes.
    static func logSkip(terminalID: UUID, reason: String) {
        logger.notice("composer-draft: skipped park of \(terminalID.uuidString, privacy: .public): \(reason, privacy: .public)")
    }

    private static func word(_ hasDraft: Bool) -> String {
        hasDraft ? "draft" : "empty"
    }
}

/// The gate's answer for one park, computed once in `performHibernate` and
/// carried down to the transport leg that carries the park out, where the
/// pending-input rails consult it and the ending reads its status.
struct ComposerDraftParkContext: Sendable {
    let status: ComposerDraftStatus
    let decision: ComposerDraftParkDecision

    /// Whether one pending-input scrape result refuses the park.
    ///
    /// Only a legacy session is refused on the scrape. For any other session
    /// the scrape never decides; while the flag exists, a confirmed session's
    /// result is still compared with the feature's answer and any
    /// disagreement logged at `.notice`.
    func scrapeRefuses(hasPendingInput: Bool, terminalID: UUID) -> Bool {
        if case .confirmed(let featureHasDraft) = status,
           let line = ComposerDraftParkGate.shadowDisagreement(
               terminalID: terminalID,
               featureHasDraft: featureHasDraft,
               scrapeHasDraft: hasPendingInput) {
            logger.notice("\(line, privacy: .public)")
        }
        return decision == .legacy && hasPendingInput
    }
}
