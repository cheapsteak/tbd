import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Records every path it was asked to measure, so a test can assert the stat
/// never happened at all — the cheap-path claim this helper rests on.
private final class FingerprintSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
    let result: TranscriptFingerprint?

    init(result: TranscriptFingerprint?) { self.result = result }

    var fingerprinter: TranscriptFingerprinter {
        { [self] path in
            lock.lock()
            _calls.append(path)
            lock.unlock()
            return result
        }
    }
}

/// The transcript superseder: it retracts a standing prompt when the session's
/// JSONL moved since the prompt was raised, and fails toward leaving the hand
/// up in every other case.
@Suite struct AwaitingInputSupersessionTests {
    let db: TBDDatabase
    let terminalID: UUID

    static let observedAt = Date(timeIntervalSince1970: 1_780_000_000)
    static let modifiedAt = Date(timeIntervalSince1970: 1_779_900_000)
    static let pathA = "/tmp/supersession-a.jsonl"
    static let pathB = "/tmp/supersession-b.jsonl"

    init() async throws {
        let db = try TBDDatabase(inMemory: true)
        self.db = db
        let repo = try await db.repos.create(
            path: "/tmp/sup-repo-\(UUID().uuidString)", displayName: "S", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/sup-wt-\(UUID().uuidString)", tmuxServer: "tbd-sup")
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "claude", claudeSessionID: "s-1", kind: .claude)
        terminalID = terminal.id
    }

    private static func fingerprint(
        path: String = pathA, size: Int64
    ) -> TranscriptFingerprint {
        TranscriptFingerprint(path: path, modifiedAt: modifiedAt, size: size)
    }

    private func setTranscriptPath(_ path: String) async throws {
        try await db.terminals.updateSession(
            id: terminalID, sessionID: "s-1", transcriptPath: path)
    }

    private func record(
        type: String?, fingerprint: TranscriptFingerprint?
    ) async throws {
        _ = try await db.terminals.recordAwaitingInputReason(
            id: terminalID,
            reason: AwaitingInputReason(
                message: "Claude needs your permission to use Bash",
                hookEventName: "Notification",
                raw: "{}",
                notificationType: type,
                transcriptFingerprint: fingerprint),
            observedAt: Self.observedAt)
    }

    private func terminal() async throws -> Terminal {
        try #require(try await db.terminals.get(id: terminalID))
    }

    private func reconcile(_ spy: FingerprintSpy) async throws -> Bool {
        let supersession = AwaitingInputSupersession(db: db, fingerprint: spy.fingerprinter)
        return await supersession.reconcile(terminal: try await terminal())
    }

    /// The file moved since the prompt was raised, so the session is not
    /// stopped on it. That is the whole mechanism.
    @Test func retractsWhenTheTranscriptChanged() async throws {
        try await setTranscriptPath(Self.pathA)
        try await record(type: "permission_prompt", fingerprint: Self.fingerprint(size: 10))
        let spy = FingerprintSpy(result: Self.fingerprint(size: 20))

        #expect(try await reconcile(spy))

        let after = try await terminal()
        #expect(after.awaitingInputReason == nil)
        #expect(after.awaitingInputObservedAt == nil)
        #expect(spy.calls == [Self.pathA])
    }

    /// A `/clear`, a compaction or a resume retargeted the session. A
    /// fingerprint cannot describe a file it was not taken from.
    @Test func retractsWhenTheTranscriptWasRetargeted() async throws {
        try await setTranscriptPath(Self.pathB)
        try await record(
            type: "permission_prompt",
            fingerprint: Self.fingerprint(path: Self.pathA, size: 10))
        let spy = FingerprintSpy(result: Self.fingerprint(path: Self.pathB, size: 10))

        #expect(try await reconcile(spy))

        #expect(try await terminal().awaitingInputReason == nil)
        #expect(spy.calls == [Self.pathB])
    }

    /// A session sitting on a permission prompt writes nothing, so an unchanged
    /// file is the pending case.
    @Test func leavesAPendingPromptAlone() async throws {
        try await setTranscriptPath(Self.pathA)
        try await record(type: "permission_prompt", fingerprint: Self.fingerprint(size: 10))
        let spy = FingerprintSpy(result: Self.fingerprint(size: 10))

        #expect(try await reconcile(spy) == false)

        let standing = try #require(try await terminal().awaitingInputReason)
        #expect(standing.transcriptFingerprint == Self.fingerprint(size: 10))
    }

    /// Inability to look is never evidence that a prompt was answered.
    @Test func leavesThePromptAloneWhenTheFileCannotBeRead() async throws {
        try await setTranscriptPath(Self.pathA)
        try await record(type: "permission_prompt", fingerprint: Self.fingerprint(size: 10))
        let spy = FingerprintSpy(result: nil)

        #expect(try await reconcile(spy) == false)

        let standing = try #require(try await terminal().awaitingInputReason)
        #expect(standing.transcriptFingerprint == Self.fingerprint(size: 10))
        #expect(spy.calls == [Self.pathA])
    }

    @Test func leavesThePromptAloneWhenThereIsNoTranscriptPath() async throws {
        try await record(type: "permission_prompt", fingerprint: Self.fingerprint(size: 10))
        let spy = FingerprintSpy(result: Self.fingerprint(size: 20))

        #expect(try await terminal().transcriptPath == nil)
        #expect(try await reconcile(spy) == false)

        #expect(try await terminal().awaitingInputReason != nil)
        #expect(spy.calls.isEmpty)
    }

    /// A row that predates fingerprints says nothing about whether its prompt
    /// was answered, so it is adopted rather than acted on — and self-heals on
    /// the transcript's next write.
    @Test func adoptsAFingerprintWhenTheReasonHasNone() async throws {
        try await setTranscriptPath(Self.pathA)
        try await record(type: "permission_prompt", fingerprint: nil)
        let spy = FingerprintSpy(result: Self.fingerprint(size: 10))

        #expect(try await reconcile(spy) == false)

        let standing = try #require(try await terminal().awaitingInputReason)
        #expect(standing.transcriptFingerprint == Self.fingerprint(size: 10))
        #expect(standing.classification == .promptOnScreen)
    }

    @Test func ignoresAReasonThatIsNotPromptOnScreen() async throws {
        try await setTranscriptPath(Self.pathA)
        try await record(type: "idle_prompt", fingerprint: nil)
        let spy = FingerprintSpy(result: Self.fingerprint(size: 10))

        #expect(try await reconcile(spy) == false)

        let standing = try #require(try await terminal().awaitingInputReason)
        #expect(standing.classification == .doneWaiting)
        #expect(standing.transcriptFingerprint == nil)
        #expect(spy.calls.isEmpty)
    }
}
