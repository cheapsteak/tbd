import Foundation
import TBDShared

/// Whether deleting a remote session should ask first, and what to say when it
/// does (`docs/specs/2026-09-02-remote-session-delete-and-transcript-exchange-design.md`,
/// "App").
///
/// **Confirmation fires unless nothing is at stake.** It is skipped in exactly
/// one situation: the session has exited, it claims no uncommitted work, and a
/// receipt is coming. Anything running is compute a user may still want;
/// anything claiming `meta.workspace_dirty` has work on another machine that
/// goes with the session; and any delete keeping no record leaves nothing to
/// recover, which is why an exited, clean session still confirms when no
/// transcript is being retained. That last one is the branch a reader skips
/// past — "it already exited and the workspace is clean, what is there to
/// warn about" — and it is the branch where the whole conversation is lost.
///
/// A pure function with no AppKit or SwiftUI, mirroring the split
/// `RemoteSessionActionMenu` keeps, so every branch is unit-testable without an
/// `AppState`.
enum RemoteDeleteConfirmation {
    enum Decision: Equatable {
        case proceed
        case confirm(message: String)
    }

    /// - Parameters:
    ///   - state: the provider's process-liveness axis for this session. Only
    ///     `.exited` earns the skip: `.starting` and `.unknown` are not
    ///     statements that the session is finished, and a state TBD could not
    ///     read is the last one to wave a destruction through.
    ///   - workspaceDirty: whether the session's `meta` claims uncommitted work.
    ///   - willRetain: whether this delete is passing `--retain`, so a
    ///     transcript survives it.
    ///   - sessionTitle: what the human calls this conversation. Blank titles
    ///     are common on providers that do not name sessions, so an empty one
    ///     reads as a phrase rather than as empty quotes.
    ///   - expiresAt: the expiry that can be stated in advance, if any. **Nil
    ///     means the provider has made no claim, never that the transcript is
    ///     kept forever** — the contract makes rendering absence as permanence
    ///     a MUST NOT, so the wording says the provider stated nothing.
    static func decide(
        state: RemoteProcessState,
        workspaceDirty: Bool,
        willRetain: Bool,
        sessionTitle: String,
        expiresAt: Date?
    ) -> Decision {
        let live = state != .exited
        guard live || workspaceDirty || !willRetain else { return .proceed }

        let name = displayName(sessionTitle)
        var sentences: [String] = []
        if live {
            sentences.append(
                "Delete \(name)? It is \(liveDescription(state)), and deleting it ends its "
                + "compute and removes it from the provider permanently.")
        } else {
            sentences.append(
                "Delete \(name)? This removes it from the provider permanently.")
        }
        if workspaceDirty {
            sentences.append(
                "It reports uncommitted work, which lives on the provider's machine and goes "
                + "with it.")
        }
        sentences.append(retentionClause(willRetain: willRetain, expiresAt: expiresAt))
        return .confirm(message: sentences.joined(separator: " "))
    }

    /// What the dialog says about the conversation itself — the half a user
    /// weighs the gesture against.
    ///
    /// The `expiresAt` value is used **only** on the retaining branch: an
    /// expiry is meaningless when nothing is being kept, and printing one there
    /// would suggest a record exists.
    private static func retentionClause(willRetain: Bool, expiresAt: Date?) -> String {
        guard willRetain else {
            return "No transcript will be kept: once this is gone there is nothing to recall."
        }
        guard let expiresAt else {
            // Deliberately not "kept forever", "never expires", or
            // "indefinitely". The provider said nothing, and saying nothing is
            // not a promise.
            return "Its transcript will be kept, and the provider states no expiry for it."
        }
        return "Its transcript will be kept, and the provider says it expires "
            + "\(expiryDescription(expiresAt))."
    }

    /// The stated expiry, rendered for a human. A `FormatStyle` rather than a
    /// shared `DateFormatter`, so there is no mutable static to reason about
    /// from several actors.
    static func expiryDescription(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    /// A session with no title still has to be named in a sentence, and empty
    /// quotation marks name nothing.
    private static func displayName(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "this remote session" }
        return "\u{201C}\(trimmed)\u{201D}"
    }

    /// How a non-exited state reads in the sentence. `.exited` never reaches
    /// here — it is the branch that took the other sentence — so it falls
    /// through to the same cautious wording `.unknown` gets rather than
    /// claiming a liveness this function was not asked about.
    private static func liveDescription(_ state: RemoteProcessState) -> String {
        switch state {
        case .running: return "still running"
        case .starting: return "still starting up"
        case .unknown, .exited: return "in a state the provider did not describe"
        }
    }
}
