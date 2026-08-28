import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// The two writers that let a read path correct a standing awaiting-input
/// prompt from the transcript rather than from a hook.
///
/// Both re-read the standing reason inside their own transaction, so the
/// interesting assertions are the refusals: a prompt raised between a caller's
/// stat and its write must survive, and a reason that already carries a
/// fingerprint must not have it overwritten.
@Suite struct AwaitingInputFingerprintStoreTests {
    let db: TBDDatabase
    let terminalID: UUID

    static let observedAt = Date(timeIntervalSince1970: 1_780_000_000)
    static let modifiedAt = Date(timeIntervalSince1970: 1_779_900_000)
    static let transcriptPath = "/tmp/awaiting-input-fingerprint.jsonl"

    init() async throws {
        let db = try TBDDatabase(inMemory: true)
        self.db = db
        let repo = try await db.repos.create(
            path: "/tmp/fp-repo-\(UUID().uuidString)", displayName: "F", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/fp-wt-\(UUID().uuidString)", tmuxServer: "tbd-fp")
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "claude", claudeSessionID: "s-1", kind: .claude)
        terminalID = terminal.id
        try await db.terminals.updateSession(
            id: terminal.id, sessionID: "s-1", transcriptPath: Self.transcriptPath)
    }

    private static func fingerprint(size: Int64) -> TranscriptFingerprint {
        TranscriptFingerprint(path: transcriptPath, modifiedAt: modifiedAt, size: size)
    }

    /// Install a standing reason exactly as the notification hook would.
    private func record(
        type: String?,
        message: String = "Claude needs your permission to use Bash",
        fingerprint: TranscriptFingerprint?
    ) async throws {
        _ = try await db.terminals.recordAwaitingInputReason(
            id: terminalID,
            reason: AwaitingInputReason(
                message: message,
                hookEventName: "Notification",
                raw: "{}",
                notificationType: type,
                transcriptFingerprint: fingerprint),
            observedAt: Self.observedAt)
    }

    private func terminal() async throws -> Terminal {
        try #require(try await db.terminals.get(id: terminalID))
    }

    // MARK: - Conditional clear

    @Test func clearsWhenTheStoredFingerprintStillMatches() async throws {
        try await record(type: "permission_prompt", fingerprint: Self.fingerprint(size: 10))

        let cleared = try await db.terminals.clearAwaitingInputReasonIfFingerprintMatches(
            id: terminalID, expected: Self.fingerprint(size: 10))

        #expect(cleared)
        let after = try await terminal()
        #expect(after.awaitingInputReason == nil)
        #expect(after.awaitingInputObservedAt == nil)
    }

    /// A fresh prompt raised between the caller's stat and this write carries a
    /// fingerprint of its own. Clearing on the stale comparison would drop a
    /// prompt nobody has answered.
    @Test func refusesWhenTheStandingFingerprintChangedUnderneath() async throws {
        try await record(type: "permission_prompt", fingerprint: Self.fingerprint(size: 10))
        try await record(
            type: "permission_prompt", message: "A newer prompt",
            fingerprint: Self.fingerprint(size: 20))

        let cleared = try await db.terminals.clearAwaitingInputReasonIfFingerprintMatches(
            id: terminalID, expected: Self.fingerprint(size: 10))

        #expect(cleared == false)
        let after = try await terminal()
        let standing = try #require(after.awaitingInputReason)
        #expect(standing.message == "A newer prompt")
        #expect(standing.transcriptFingerprint == Self.fingerprint(size: 20))
        #expect(after.awaitingInputObservedAt == Self.observedAt)
    }

    /// The callers are read paths, so a row that vanished under them reports
    /// `false` rather than throwing.
    @Test func refusesOnAMissingTerminal() async throws {
        let cleared = try await db.terminals.clearAwaitingInputReasonIfFingerprintMatches(
            id: UUID(), expected: Self.fingerprint(size: 10))
        #expect(cleared == false)
    }

    // MARK: - Adoption

    @Test func adoptsAFingerprintOntoAReasonThatHasNone() async throws {
        try await record(type: "permission_prompt", fingerprint: nil)

        let adopted = try await db.terminals.adoptTranscriptFingerprint(
            id: terminalID, fingerprint: Self.fingerprint(size: 10))

        #expect(adopted)
        let standing = try #require(try await terminal().awaitingInputReason)
        #expect(standing.transcriptFingerprint == Self.fingerprint(size: 10))
        // Adoption attaches; it must not rewrite what the hook reported.
        #expect(standing.message == "Claude needs your permission to use Bash")
        #expect(standing.hookEventName == "Notification")
        #expect(standing.raw == "{}")
        #expect(standing.notificationType == "permission_prompt")
        #expect(standing.classification == .promptOnScreen)
    }

    @Test func adoptionLeavesAReasonThatAlreadyHasOneAlone() async throws {
        try await record(type: "permission_prompt", fingerprint: Self.fingerprint(size: 10))

        let adopted = try await db.terminals.adoptTranscriptFingerprint(
            id: terminalID, fingerprint: Self.fingerprint(size: 20))

        #expect(adopted == false)
        let standing = try #require(try await terminal().awaitingInputReason)
        #expect(standing.transcriptFingerprint == Self.fingerprint(size: 10))
    }

    /// Only a raised hand is worth making answerable to the transcript. No
    /// other class has anything to take down.
    @Test func adoptionIgnoresAReasonThatIsNotPromptOnScreen() async throws {
        try await record(type: "idle_prompt", fingerprint: nil)

        let adopted = try await db.terminals.adoptTranscriptFingerprint(
            id: terminalID, fingerprint: Self.fingerprint(size: 10))

        #expect(adopted == false)
        let standing = try #require(try await terminal().awaitingInputReason)
        #expect(standing.classification == .doneWaiting)
        #expect(standing.transcriptFingerprint == nil)
    }
}
