import Foundation
import TBDShared

/// How a transcript is measured. Injected so tests drive fingerprints without
/// a filesystem, and so the daemon's one real measurement lives in one place.
public typealias TranscriptFingerprinter = @Sendable (String) -> TranscriptFingerprint?

public enum TranscriptFingerprinting {
    /// One `stat`: no open, no read, no parse. Cheap enough to run on every
    /// pass that reports a terminal, and it runs only for the rows holding a
    /// standing prompt.
    public static let live: TranscriptFingerprinter = { path in
        guard !path.isEmpty,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let modifiedAt = attrs[.modificationDate] as? Date,
              let size = (attrs[.size] as? NSNumber)?.int64Value
        else { return nil }
        return TranscriptFingerprint(path: path, modifiedAt: modifiedAt, size: size)
    }
}

/// The second superseder of an awaiting-input reason.
///
/// The activity rail retracts a reason when a hook reports the session moved.
/// This one retracts it when the session's TRANSCRIPT moved, which is the only
/// evidence available when no hook arrives — and none does: Claude Code fires
/// nothing when a human answers a permission prompt, and a session whose hook
/// rail has gone quiet produces no activity observation at all.
///
/// Every branch fails toward leaving the prompt raised. A lingering hand is the
/// defect this exists to fix; a hand dropped while a human is still being asked
/// hides the one row that needs attention.
///
/// See `docs/specs/2026-08-27-awaiting-input-transcript-supersession-design.md`.
struct AwaitingInputSupersession: Sendable {
    let db: TBDDatabase
    let fingerprint: TranscriptFingerprinter

    /// Reconcile one terminal against its transcript. Returns whether a
    /// standing prompt was retracted, so a caller entitled to announce the
    /// retraction can do so from what the write actually did.
    func reconcile(terminal: Terminal) async -> Bool {
        guard let reason = terminal.awaitingInputReason,
              reason.classification == .promptOnScreen else { return false }
        guard let path = terminal.transcriptPath, !path.isEmpty else { return false }
        // Inability to look is never evidence that a prompt was answered.
        guard let observed = fingerprint(path) else { return false }
        guard let stored = reason.transcriptFingerprint else {
            _ = try? await db.terminals.adoptTranscriptFingerprint(
                id: terminal.id, fingerprint: observed)
            return false
        }
        guard stored != observed else { return false }
        return (try? await db.terminals.clearAwaitingInputReasonIfFingerprintMatches(
            id: terminal.id, expected: stored)) ?? false
    }
}
