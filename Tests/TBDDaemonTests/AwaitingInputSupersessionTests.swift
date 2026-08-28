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

/// Records every (path, offset) it was asked to read, so a test can assert the
/// delta was never opened — the steady state costs one stat and nothing more.
private final class DeltaSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    /// Each call rendered as `path@offset`, which is all any assertion here
    /// needs and keeps the expectations readable.
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
    let result: TranscriptDelta?

    init(result: TranscriptDelta?) { self.result = result }

    var inspector: TranscriptDeltaInspector {
        { [self] path, offset in
            lock.lock()
            _calls.append("\(path)@\(offset)")
            lock.unlock()
            return result
        }
    }
}

/// A temp directory that cleans itself up when the suite instance for one test
/// is released.
private final class TempDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-delta-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// The transcript superseder: it retracts a standing prompt when the SESSION
/// wrote to its own JSONL since the prompt was raised, and fails toward leaving
/// the hand up in every other case — a nested agent's sidechain writes
/// included.
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

    private func reconcile(_ spy: FingerprintSpy, _ delta: DeltaSpy) async throws -> Bool {
        let supersession = AwaitingInputSupersession(
            db: db, fingerprint: spy.fingerprinter, delta: delta.inspector)
        return await supersession.reconcile(terminal: try await terminal())
    }

    /// The session itself wrote since the prompt was raised, so it is not
    /// stopped on it. That is the whole mechanism.
    @Test func retractsWhenTheParentSessionWrote() async throws {
        try await setTranscriptPath(Self.pathA)
        try await record(type: "permission_prompt", fingerprint: Self.fingerprint(size: 10))
        let spy = FingerprintSpy(result: Self.fingerprint(size: 20))
        let delta = DeltaSpy(result: .containsParentContent)

        #expect(try await reconcile(spy, delta))

        let after = try await terminal()
        #expect(after.awaitingInputReason == nil)
        #expect(after.awaitingInputObservedAt == nil)
        #expect(spy.calls == [Self.pathA])
        // Read from the stored size, which is where the prompt was raised.
        #expect(delta.calls == ["\(Self.pathA)@10"])
    }

    /// The failure this exists to fix. A parallel `Task` subagent appends
    /// sidechain records to the parent's JSONL while the permission prompt is
    /// still on screen; growth alone would drop the hand on a blocked human.
    @Test func leavesTheHandUpWhenOnlyASubagentWrote() async throws {
        try await setTranscriptPath(Self.pathA)
        try await record(type: "permission_prompt", fingerprint: Self.fingerprint(size: 10))
        let spy = FingerprintSpy(result: Self.fingerprint(size: 20))
        let delta = DeltaSpy(result: .sidechainOnly)

        #expect(try await reconcile(spy, delta) == false)

        let standing = try #require(try await terminal().awaitingInputReason)
        #expect(standing.classification == .promptOnScreen)
        // The baseline moved forward, so the next pass is a stat again rather
        // than a re-read of records already attributed to the subagent.
        #expect(standing.transcriptFingerprint == Self.fingerprint(size: 20))
        #expect(delta.calls == ["\(Self.pathA)@10"])
    }

    /// A refreshed baseline is not a retraction in disguise: the very next pass
    /// against the same file still leaves the hand up, and reads nothing.
    @Test func aRefreshedBaselineMakesTheNextPassAStatAgain() async throws {
        try await setTranscriptPath(Self.pathA)
        try await record(type: "permission_prompt", fingerprint: Self.fingerprint(size: 10))
        _ = try await reconcile(
            FingerprintSpy(result: Self.fingerprint(size: 20)),
            DeltaSpy(result: .sidechainOnly))

        let second = DeltaSpy(result: .containsParentContent)
        #expect(try await reconcile(FingerprintSpy(result: Self.fingerprint(size: 20)), second)
                == false)

        #expect(try await terminal().awaitingInputReason != nil)
        #expect(second.calls.isEmpty)
    }

    /// Inability to read the delta is never evidence — and the baseline stays
    /// where it was, so nothing advances past bytes nobody ever read.
    @Test func changesNothingWhenTheDeltaCannotBeRead() async throws {
        try await setTranscriptPath(Self.pathA)
        try await record(type: "permission_prompt", fingerprint: Self.fingerprint(size: 10))
        let delta = DeltaSpy(result: nil)

        #expect(try await reconcile(FingerprintSpy(result: Self.fingerprint(size: 20)), delta)
                == false)

        let standing = try #require(try await terminal().awaitingInputReason)
        #expect(standing.transcriptFingerprint == Self.fingerprint(size: 10))
        #expect(delta.calls == ["\(Self.pathA)@10"])
    }

    /// A file that shrank was rotated or rewritten. The stored offset describes
    /// nothing in the file that is there now, so there is no delta to attribute.
    @Test func retractsWhenTheTranscriptWasTruncated() async throws {
        try await setTranscriptPath(Self.pathA)
        try await record(type: "permission_prompt", fingerprint: Self.fingerprint(size: 100))
        let delta = DeltaSpy(result: .sidechainOnly)

        #expect(try await reconcile(FingerprintSpy(result: Self.fingerprint(size: 20)), delta))

        #expect(try await terminal().awaitingInputReason == nil)
        #expect(delta.calls.isEmpty, "a truncated file is not a delta to read")
    }

    /// A `/clear`, a compaction or a resume retargeted the session. A
    /// fingerprint cannot describe a file it was not taken from.
    @Test func retractsWhenTheTranscriptWasRetargeted() async throws {
        try await setTranscriptPath(Self.pathB)
        try await record(
            type: "permission_prompt",
            fingerprint: Self.fingerprint(path: Self.pathA, size: 10))
        let spy = FingerprintSpy(result: Self.fingerprint(path: Self.pathB, size: 10))
        let delta = DeltaSpy(result: .sidechainOnly)

        #expect(try await reconcile(spy, delta))

        #expect(try await terminal().awaitingInputReason == nil)
        #expect(spy.calls == [Self.pathB])
        #expect(delta.calls.isEmpty, "an offset into the old file describes nothing in the new one")
    }

    /// A session sitting on a permission prompt writes nothing, so an unchanged
    /// file is the pending case — and it costs exactly one stat. The zero-call
    /// assertion is what pins that: no open, no read, no parse.
    @Test func leavesAPendingPromptAloneWithoutReadingTheFile() async throws {
        try await setTranscriptPath(Self.pathA)
        try await record(type: "permission_prompt", fingerprint: Self.fingerprint(size: 10))
        let spy = FingerprintSpy(result: Self.fingerprint(size: 10))
        let delta = DeltaSpy(result: .containsParentContent)

        #expect(try await reconcile(spy, delta) == false)

        let standing = try #require(try await terminal().awaitingInputReason)
        #expect(standing.transcriptFingerprint == Self.fingerprint(size: 10))
        #expect(spy.calls == [Self.pathA])
        #expect(delta.calls.isEmpty)
    }

    /// Inability to look is never evidence that a prompt was answered.
    @Test func leavesThePromptAloneWhenTheFileCannotBeRead() async throws {
        try await setTranscriptPath(Self.pathA)
        try await record(type: "permission_prompt", fingerprint: Self.fingerprint(size: 10))
        let spy = FingerprintSpy(result: nil)
        let delta = DeltaSpy(result: .containsParentContent)

        #expect(try await reconcile(spy, delta) == false)

        let standing = try #require(try await terminal().awaitingInputReason)
        #expect(standing.transcriptFingerprint == Self.fingerprint(size: 10))
        #expect(spy.calls == [Self.pathA])
        #expect(delta.calls.isEmpty)
    }

    @Test func leavesThePromptAloneWhenThereIsNoTranscriptPath() async throws {
        try await record(type: "permission_prompt", fingerprint: Self.fingerprint(size: 10))
        let spy = FingerprintSpy(result: Self.fingerprint(size: 20))
        let delta = DeltaSpy(result: .containsParentContent)

        #expect(try await terminal().transcriptPath == nil)
        #expect(try await reconcile(spy, delta) == false)

        #expect(try await terminal().awaitingInputReason != nil)
        #expect(spy.calls.isEmpty)
        #expect(delta.calls.isEmpty)
    }

    /// A row that predates fingerprints says nothing about whether its prompt
    /// was answered, so it is adopted rather than acted on — and self-heals on
    /// the transcript's next write.
    @Test func adoptsAFingerprintWhenTheReasonHasNone() async throws {
        try await setTranscriptPath(Self.pathA)
        try await record(type: "permission_prompt", fingerprint: nil)
        let spy = FingerprintSpy(result: Self.fingerprint(size: 10))
        let delta = DeltaSpy(result: .containsParentContent)

        #expect(try await reconcile(spy, delta) == false)

        let standing = try #require(try await terminal().awaitingInputReason)
        #expect(standing.transcriptFingerprint == Self.fingerprint(size: 10))
        #expect(standing.classification == .promptOnScreen)
        #expect(delta.calls.isEmpty, "there is no baseline to read a delta from")
    }

    @Test func ignoresAReasonThatIsNotPromptOnScreen() async throws {
        try await setTranscriptPath(Self.pathA)
        try await record(type: "idle_prompt", fingerprint: nil)
        let spy = FingerprintSpy(result: Self.fingerprint(size: 10))
        let delta = DeltaSpy(result: .containsParentContent)

        #expect(try await reconcile(spy, delta) == false)

        let standing = try #require(try await terminal().awaitingInputReason)
        #expect(standing.classification == .doneWaiting)
        #expect(standing.transcriptFingerprint == nil)
        #expect(spy.calls.isEmpty)
        #expect(delta.calls.isEmpty)
    }
}

/// The live delta inspector, against real files. What the superseder believes
/// about a transcript is only as good as this reader, so these exercise the
/// bytes rather than a stub.
@Suite struct TranscriptDeltaInspectionTests {
    private let temp: TempDirectory

    init() throws { temp = try TempDirectory() }

    private static let sidechain =
        #"{"type":"assistant","isSidechain":true,"message":{"role":"assistant"}}"#
    private static let parent =
        #"{"type":"user","isSidechain":false,"message":{"role":"user"}}"#

    /// Writes `contents` and answers with the path and the byte length.
    @discardableResult
    private func write(_ contents: String, name: String = "session.jsonl") throws
        -> (path: String, size: Int64) {
        let url = temp.url.appendingPathComponent(name)
        let data = Data(contents.utf8)
        try data.write(to: url)
        return (url.path, Int64(data.count))
    }

    /// A subagent's records are the parent's file growing without the parent
    /// writing. That distinction is the whole point of this reader.
    @Test func attributesSidechainRecordsToTheNestedAgent() async throws {
        let base = try write(Self.parent + "\n")
        let full = try write(Self.parent + "\n" + Self.sidechain + "\n" + Self.sidechain + "\n")

        #expect(TranscriptDeltaInspection.live(full.path, base.size) == .sidechainOnly)
    }

    @Test func seesARecordTheParentWrote() async throws {
        let base = try write(Self.sidechain + "\n")
        let full = try write(Self.sidechain + "\n" + Self.parent + "\n")

        #expect(TranscriptDeltaInspection.live(full.path, base.size) == .containsParentContent)
    }

    /// One parent record among a subagent's is still the parent writing.
    @Test func aMixedDeltaIsParentContent() async throws {
        let base = try write(Self.parent + "\n")
        let full = try write(
            Self.parent + "\n" + Self.sidechain + "\n" + Self.parent + "\n"
                + Self.sidechain + "\n")

        #expect(TranscriptDeltaInspection.live(full.path, base.size) == .containsParentContent)
    }

    /// A record with no `isSidechain` at all is the parent's — that is how
    /// Claude Code writes the parent conversation's own lines.
    @Test func aRecordWithoutTheFlagIsParentContent() async throws {
        let base = try write(Self.sidechain + "\n")
        let full = try write(Self.sidechain + "\n" + #"{"type":"user"}"# + "\n")

        #expect(TranscriptDeltaInspection.live(full.path, base.size) == .containsParentContent)
    }

    /// The offset is a stat-captured SIZE, so it lands mid-record whenever the
    /// fingerprint was taken while a line was being written. The record whose
    /// middle it points into must still be read whole, and both plausible ways
    /// of getting that wrong lose it: skipping forward to the next newline
    /// drops the record outright, and starting at the raw offset hands the
    /// parser a fragment that reads as no record at all. Either leaves a raised
    /// hand standing over a session that has moved on.
    @Test func aMidRecordOffsetStillSeesTheParentRecord() async throws {
        let full = try write(Self.sidechain + "\n" + Self.parent + "\n")
        let midRecord = Int64((Self.sidechain + "\n").utf8.count + 5)

        #expect(TranscriptDeltaInspection.live(full.path, midRecord) == .containsParentContent)
    }

    /// A line this build cannot read as a record decides nothing. It is not a
    /// parent record until it is read as one, so it may not take a hand down.
    @Test func anUnparseableRecordIsNotEvidence() async throws {
        let base = try write(Self.sidechain + "\n")
        let full = try write(Self.sidechain + "\n" + "}not json{" + "\n" + Self.sidechain + "\n")

        #expect(TranscriptDeltaInspection.live(full.path, base.size) == .sidechainOnly)
    }

    /// Passing over an unreadable line does not blind the reader to the records
    /// around it.
    @Test func aParentRecordBesideAnUnparseableOneStillRetracts() async throws {
        let base = try write(Self.sidechain + "\n")
        let full = try write(Self.sidechain + "\n" + "}not json{" + "\n" + Self.parent + "\n")

        #expect(TranscriptDeltaInspection.live(full.path, base.size) == .containsParentContent)
    }

    /// A delta larger than the cap is read from its END, and a window showing
    /// only sidechain records leaves the hand up. The parent record here sits
    /// far outside the window on purpose: failing toward a standing hand is the
    /// direction this rail chooses.
    @Test func aDeltaOverTheCapIsReadFromItsEnd() async throws {
        let padding = String(repeating: "x", count: 900)
        let padded = #"{"type":"assistant","isSidechain":true,"pad":"\#(padding)"}"#
        var contents = Self.parent + "\n"
        for _ in 0..<120 { contents += padded + "\n" }
        let full = try write(contents)
        #expect(full.size > Int64(TranscriptDeltaInspection.deltaByteLimit))

        #expect(TranscriptDeltaInspection.live(full.path, 0) == .sidechainOnly)
    }

    /// A record still being written is not yet evidence of anything.
    @Test func anIncompleteFinalRecordIsNotEvidence() async throws {
        let base = try write(Self.sidechain + "\n")
        let full = try write(Self.sidechain + "\n" + #"{"type":"user","mes"#)

        #expect(TranscriptDeltaInspection.live(full.path, base.size) == .sidechainOnly)
    }

    /// Same size, different modification time: the file was touched but gained
    /// no record, so the parent has not written.
    @Test func anEmptyDeltaIsNotParentContent() async throws {
        let full = try write(Self.parent + "\n")

        #expect(TranscriptDeltaInspection.live(full.path, full.size) == .sidechainOnly)
    }

    @Test func returnsNilWhenTheFileCannotBeOpened() async throws {
        let missing = temp.url.appendingPathComponent("absent.jsonl").path

        #expect(TranscriptDeltaInspection.live(missing, 0) == nil)
    }

    /// An offset past the end is a race, not a state to interpret.
    @Test func returnsNilWhenTheOffsetIsBeyondTheEnd() async throws {
        let full = try write(Self.parent + "\n")

        #expect(TranscriptDeltaInspection.live(full.path, full.size + 500) == nil)
    }

    @Test func returnsNilForAnEmptyPath() async throws {
        #expect(TranscriptDeltaInspection.live("", 0) == nil)
    }
}
