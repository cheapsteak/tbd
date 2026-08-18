import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("Codex transcript activity tracker")
struct CodexTranscriptActivityTrackerTests {
    @Test func taskStartedProducesWorking() {
        var reducer = CodexTurnLifecycleReducer()

        reducer.consume(line: event(type: "task_started", turnID: "a"))

        #expect(reducer.activityState == .working)
    }

    @Test func matchingTaskCompleteProducesIdle() {
        var reducer = CodexTurnLifecycleReducer()
        reducer.consume(line: event(type: "task_started", turnID: "a"))

        reducer.consume(line: event(type: "task_complete", turnID: "a"))

        #expect(reducer.activityState == .idle)
    }

    @Test func matchingTurnAbortedProducesIdle() {
        var reducer = CodexTurnLifecycleReducer()
        reducer.consume(line: event(type: "task_started", turnID: "a"))

        reducer.consume(line: event(type: "turn_aborted", turnID: "a"))

        #expect(reducer.activityState == .idle)
    }

    @Test func completionForUnknownTurnDoesNotCloseOpenTurn() {
        var reducer = CodexTurnLifecycleReducer()
        reducer.consume(line: event(type: "task_started", turnID: "a"))

        reducer.consume(line: event(type: "task_complete", turnID: "b"))

        #expect(reducer.activityState == .working)
    }

    @Test func duplicateStartsAreIdempotent() {
        var reducer = CodexTurnLifecycleReducer()
        reducer.consume(line: event(type: "task_started", turnID: "a"))
        reducer.consume(line: event(type: "task_started", turnID: "a"))

        reducer.consume(line: event(type: "task_complete", turnID: "a"))

        #expect(reducer.activityState == .idle)
    }

    @Test func laterTurnSupersedesUnmatchedHistoricalTurn() {
        var reducer = CodexTurnLifecycleReducer()
        reducer.consume(line: event(type: "task_started", turnID: "a"))
        reducer.consume(line: event(type: "task_started", turnID: "b"))

        reducer.consume(line: event(type: "task_complete", turnID: "b"))

        #expect(reducer.activityState == .idle)
    }

    @Test func lateCloseForSupersededTurnDoesNotCloseCurrentTurn() {
        var reducer = CodexTurnLifecycleReducer()
        reducer.consume(line: event(type: "task_started", turnID: "a"))
        reducer.consume(line: event(type: "task_started", turnID: "b"))

        reducer.consume(line: event(type: "task_complete", turnID: "a"))
        #expect(reducer.activityState == .working)

        reducer.consume(line: event(type: "task_complete", turnID: "b"))
        #expect(reducer.activityState == .idle)
    }

    @Test func malformedUnrelatedAndWrongOuterRecordsAreIgnored() {
        var reducer = CodexTurnLifecycleReducer()

        reducer.consume(line: Data("not json\n".utf8))
        reducer.consume(line: Data(#"{"type":"response_item","payload":{"type":"task_started","turn_id":"a"}}"#.utf8))
        reducer.consume(line: event(type: "agent_message", turnID: "a"))

        #expect(reducer.activityState == nil)
    }

    @Test func noLifecycleEvidenceProducesNil() {
        let reducer = CodexTurnLifecycleReducer()

        #expect(reducer.activityState == nil)
    }

    @Test func firstObservationRebuildsPreExistingOpenTurn() async throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        try fixture.write(event(type: "task_started", turnID: "a"))
        let tracker = CodexTranscriptActivityTracker()

        let state = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: UUID())

        #expect(state == .working)
    }

    @Test func secondObservationReadsAppendedCompletion() async throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        try fixture.write(event(type: "task_started", turnID: "a"))
        let tracker = CodexTranscriptActivityTracker()
        let worktreeID = UUID()
        _ = await tracker.observe(transcriptPath: fixture.path, worktreeID: worktreeID)

        try fixture.append(event(type: "task_complete", turnID: "a"))
        let state = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: worktreeID)

        #expect(state == .idle)
    }

    @Test func laterObservationsDoNotRescanAlreadyConsumedBytes() async throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        let initial = event(type: "task_started", turnID: "a")
        let replacement = event(type: "task_started", turnID: "b")
        #expect(initial.count == replacement.count)
        try fixture.write(initial)
        let tracker = CodexTranscriptActivityTracker()
        let worktreeID = UUID()
        let firstState = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: worktreeID)

        try fixture.overwriteBeginning(with: replacement)
        try fixture.append(event(type: "task_complete", turnID: "a"))
        let appendedState = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: worktreeID)

        #expect(firstState == .working)
        #expect(appendedState == .idle)
    }

    @Test func unterminatedRecordWaitsForNewline() async throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        let record = event(type: "task_started", turnID: "a", terminated: false)
        try fixture.write(record)
        let tracker = CodexTranscriptActivityTracker()
        let worktreeID = UUID()

        let beforeNewline = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: worktreeID)
        try fixture.append(Data([0x0A]))
        let afterNewline = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: worktreeID)

        #expect(beforeNewline == nil)
        #expect(afterNewline == .working)
    }

    @Test func lifecycleRecordCrossingReadChunkBoundaryIsReassembled() async throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        let record = event(
            type: "task_started", turnID: "a",
            padding: String(repeating: "x", count: 64 * 1024))
        #expect(record.count > 64 * 1024)
        try fixture.write(record)
        let tracker = CodexTranscriptActivityTracker()

        let state = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: UUID())

        #expect(state == .working)
    }

    @Test func truncationResetsAndRebuildsFromByteZero() async throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        try fixture.write(
            event(type: "task_started", turnID: "a")
                + event(type: "agent_message", turnID: "padding"))
        let tracker = CodexTranscriptActivityTracker()
        let worktreeID = UUID()
        let initial = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: worktreeID)

        try fixture.write(event(type: "task_complete", turnID: "replacement"))
        let rebuilt = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: worktreeID)

        #expect(initial == .working)
        #expect(rebuilt == .idle)
    }

    @Test func transcriptPathsHaveIndependentBaselines() async throws {
        let first = try TranscriptFixture()
        let second = try TranscriptFixture()
        defer {
            first.remove()
            second.remove()
        }
        try first.write(event(type: "task_started", turnID: "a"))
        try second.write(event(type: "task_complete", turnID: "b"))
        let tracker = CodexTranscriptActivityTracker()
        let worktreeID = UUID()

        let firstState = await tracker.observe(
            transcriptPath: first.path, worktreeID: worktreeID)
        let secondState = await tracker.observe(
            transcriptPath: second.path, worktreeID: worktreeID)
        let firstAgain = await tracker.observe(
            transcriptPath: first.path, worktreeID: worktreeID)

        #expect(firstState == .working)
        #expect(secondState == .idle)
        #expect(firstAgain == .working)
    }

    @Test func unreadablePathReturnsNilInsteadOfCachedWorking() async throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        try fixture.write(
            event(type: "task_started", turnID: "a", padding: String(repeating: "x", count: 256)))
        let tracker = CodexTranscriptActivityTracker()
        let worktreeID = UUID()
        let initial = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: worktreeID)
        try fixture.replaceFileWithDirectory()

        let unreadable = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: worktreeID)
        try fixture.replaceDirectoryWithFile(event(type: "task_complete", turnID: "replacement"))
        let recovered = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: worktreeID)

        #expect(initial == .working)
        #expect(unreadable == nil)
        #expect(recovered == .idle)
    }

    @Test func fleetWideRetainPrunesEveryMissingTranscript() async throws {
        let first = try TranscriptFixture()
        let second = try TranscriptFixture()
        defer {
            first.remove()
            second.remove()
        }
        try first.write(event(type: "task_started", turnID: "a"))
        try second.write(event(type: "task_started", turnID: "b"))
        let tracker = CodexTranscriptActivityTracker()
        _ = await tracker.observe(transcriptPath: first.path, worktreeID: UUID())
        _ = await tracker.observe(transcriptPath: second.path, worktreeID: UUID())

        await tracker.retain(transcriptPaths: [first.path], scope: nil)

        #expect(await tracker.baselineCount == 1)
    }

    @Test func worktreeScopedRetainDoesNotPruneAnotherWorktree() async throws {
        let keptHere = try TranscriptFixture()
        let prunedHere = try TranscriptFixture()
        let keptThere = try TranscriptFixture()
        defer {
            keptHere.remove()
            prunedHere.remove()
            keptThere.remove()
        }
        for fixture in [keptHere, prunedHere, keptThere] {
            try fixture.write(event(type: "task_started", turnID: fixture.path))
        }
        let tracker = CodexTranscriptActivityTracker()
        let here = UUID()
        let there = UUID()
        _ = await tracker.observe(transcriptPath: keptHere.path, worktreeID: here)
        _ = await tracker.observe(transcriptPath: prunedHere.path, worktreeID: here)
        _ = await tracker.observe(transcriptPath: keptThere.path, worktreeID: there)

        await tracker.retain(transcriptPaths: [keptHere.path], scope: here)

        #expect(await tracker.baselineCount == 2)
        #expect(await tracker.hasBaseline(transcriptPath: keptHere.path))
        #expect(!(await tracker.hasBaseline(transcriptPath: prunedHere.path)))
        #expect(await tracker.hasBaseline(transcriptPath: keptThere.path))
    }

    private func event(
        type: String,
        turnID: String,
        terminated: Bool = true,
        padding: String? = nil
    ) -> Data {
        let newline = terminated ? "\n" : ""
        let paddingField = padding.map { #", "padding":"\#($0)""# } ?? ""
        return Data((
            #"{"type":"event_msg","payload":{"type":"\#(type)","turn_id":"\#(turnID)"\#(paddingField)}}"#
                + newline).utf8)
    }
}

private final class TranscriptFixture: @unchecked Sendable {
    private let directory: URL
    private let file: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-transcript-activity-\(UUID().uuidString)")
        file = directory.appendingPathComponent("rollout.jsonl")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var path: String { file.path }

    func write(_ data: Data) throws {
        try data.write(to: file)
    }

    func append(_ data: Data) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    func overwriteBeginning(with data: Data) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: data)
    }

    func replaceFileWithDirectory() throws {
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    }

    func replaceDirectoryWithFile(_ data: Data) throws {
        try FileManager.default.removeItem(at: file)
        try data.write(to: file)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
