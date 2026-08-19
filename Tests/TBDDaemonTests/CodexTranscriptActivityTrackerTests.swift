import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("Codex transcript activity tracker")
struct CodexTranscriptActivityTrackerTests {
    private static let initialTailByteLimit = Int(CodexTranscriptActivityTracker.initialTailByteLimit)
    private static let incrementalReadByteLimit =
        Int(CodexTranscriptActivityTracker.incrementalReadByteLimit)
    private static let maxBufferedRecordByteCount =
        CodexTranscriptActivityTracker.maxBufferedRecordByteCount

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

    @Test func rewrittenCompletionIDClosesTurnWithMatchingStartTime() {
        var reducer = CodexTurnLifecycleReducer()
        reducer.consume(line: event(
            type: "task_started", turnID: "started-id", startedAt: 1_785_908_531))

        reducer.consume(line: event(
            type: "task_complete", turnID: "completed-id", startedAt: 1_785_908_531,
            completedAt: 1_785_908_636))

        #expect(reducer.activityState == .idle)
    }

    @Test func rewrittenAbortIDClosesTurnWithMatchingStartTime() {
        var reducer = CodexTurnLifecycleReducer()
        reducer.consume(line: event(
            type: "task_started", turnID: "started-id", startedAt: 1_785_898_845))

        reducer.consume(line: event(
            type: "turn_aborted", turnID: "aborted-id", startedAt: 1_785_898_845,
            completedAt: 1_785_898_898))

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

    @Test func lateRewrittenCloseForOlderStartTimeDoesNotCloseCurrentTurn() {
        var reducer = CodexTurnLifecycleReducer()
        reducer.consume(line: event(
            type: "task_started", turnID: "older-start", startedAt: 100))
        reducer.consume(line: event(
            type: "task_started", turnID: "current-start", startedAt: 200))

        reducer.consume(line: event(
            type: "task_complete", turnID: "older-complete", startedAt: 100,
            completedAt: 250))
        #expect(reducer.activityState == .working)

        reducer.consume(line: event(
            type: "task_complete", turnID: "current-complete", startedAt: 200,
            completedAt: 300))
        #expect(reducer.activityState == .idle)
    }

    @Test func subagentRolloutUsesTheSameLifecycleCorrelation() {
        var reducer = CodexTurnLifecycleReducer()
        reducer.consume(line: Data(#"{"type":"session_meta","payload":{"source":{"subagent":{"thread_spawn":{"depth":2}}}}}"#.utf8))
        reducer.consume(line: event(
            type: "task_started", turnID: "nested-start", startedAt: 300))

        reducer.consume(line: event(
            type: "task_complete", turnID: "nested-complete", startedAt: 300,
            completedAt: 400))

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

    @Test func firstObservationDoesNotDecodeLifecycleOlderThanTailLimit() async throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        let oldStart = event(type: "task_started", turnID: "old")
        let tail = event(
            type: "agent_message", turnID: "padding",
            exactByteCount: Self.initialTailByteLimit)
        try fixture.write(oldStart + tail)
        let tracker = CodexTranscriptActivityTracker()

        let state = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: UUID())

        #expect(state == nil)
    }

    @Test func firstObservationReconstructsLifecycleInsideOversizedTranscriptTail() async throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        let prefix = event(
            type: "agent_message", turnID: "padding",
            exactByteCount: Self.initialTailByteLimit + 128)
        try fixture.write(prefix + event(type: "task_started", turnID: "latest"))
        let tracker = CodexTranscriptActivityTracker()

        let firstSlice = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: UUID())
        let state = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: UUID())

        #expect(firstSlice == nil)
        #expect(state == .working)
    }

    @Test func tailStartingOnRecordBoundaryRetainsFirstRecord() async throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        let prefix = event(type: "agent_message", turnID: "prefix")
        let start = event(type: "task_started", turnID: "boundary")
        let tailPadding = event(
            type: "agent_message", turnID: "padding",
            exactByteCount: Self.initialTailByteLimit - start.count)
        try fixture.write(prefix + start + tailPadding)
        let tracker = CodexTranscriptActivityTracker()

        let firstSlice = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: UUID())
        let state = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: UUID())

        #expect(firstSlice == nil)
        #expect(state == .working)
    }

    @Test func tailStartingMidRecordDiscardsOnlyLeadingPartialRecord() async throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        let partialStart = event(
            type: "task_started", turnID: "old",
            exactByteCount: Self.initialTailByteLimit + 128)
        try fixture.write(partialStart + event(type: "task_complete", turnID: "other"))
        let tracker = CodexTranscriptActivityTracker()

        let firstSlice = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: UUID())
        let state = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: UUID())

        #expect(firstSlice == nil)
        #expect(state == .idle)
    }

    @Test func appendedCompletionAfterTailBootstrapDoesNotRescanHistory() async throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        let prefix = event(
            type: "agent_message", turnID: "padding",
            exactByteCount: Self.initialTailByteLimit + 128)
        let initialStart = event(type: "task_started", turnID: "a")
        let replacementStart = event(type: "task_started", turnID: "b")
        #expect(initialStart.count == replacementStart.count)
        try fixture.write(prefix + initialStart)
        let tracker = CodexTranscriptActivityTracker()
        let worktreeID = UUID()
        let initialSlice = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: worktreeID)
        let initial = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: worktreeID)

        try fixture.overwrite(at: UInt64(prefix.count), with: replacementStart)
        try fixture.append(event(type: "task_complete", turnID: "a"))
        let completed = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: worktreeID)

        #expect(initialSlice == nil)
        #expect(initial == .working)
        #expect(completed == .idle)
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

    @Test func incrementalBacklogDoesNotPublishIntermediateLifecycleState() async throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        try fixture.write(event(type: "task_complete", turnID: "seed"))
        let tracker = CodexTranscriptActivityTracker()
        let worktreeID = UUID()
        _ = await tracker.observe(transcriptPath: fixture.path, worktreeID: worktreeID)

        try fixture.append(
            event(type: "task_started", turnID: "a")
                + event(
                    type: "agent_message", turnID: "padding",
                    exactByteCount: Self.incrementalReadByteLimit)
                + event(type: "task_complete", turnID: "a"))

        let catchingUp = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: worktreeID)
        let caughtUp = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: worktreeID)

        #expect(catchingUp == nil)
        #expect(caughtUp == .idle)
    }

    @Test func incrementalBacklogPreservesRecordCrossingPollBoundaries() async throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        try fixture.write(event(type: "task_complete", turnID: "seed"))
        let tracker = CodexTranscriptActivityTracker()
        let worktreeID = UUID()
        _ = await tracker.observe(transcriptPath: fixture.path, worktreeID: worktreeID)

        let crossingStart = event(type: "task_started", turnID: "a")
        let firstPadding = event(
            type: "agent_message", turnID: "first-padding",
            exactByteCount: Self.incrementalReadByteLimit - crossingStart.count / 2)
        let secondPadding = event(
            type: "agent_message", turnID: "second-padding",
            exactByteCount: Self.incrementalReadByteLimit)
        try fixture.append(
            firstPadding
                + crossingStart
                + secondPadding
                + event(type: "task_complete", turnID: "different-turn"))

        let firstCatchUp = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: worktreeID)
        let secondCatchUp = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: worktreeID)
        let caughtUp = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: worktreeID)

        #expect(firstCatchUp == nil)
        #expect(secondCatchUp == nil)
        #expect(caughtUp == .working)
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

    @Test func partialLifecycleRecordAtEOFDoesNotRepublishCachedState() async throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        try fixture.write(event(type: "task_started", turnID: "a"))
        let tracker = CodexTranscriptActivityTracker()
        let worktreeID = UUID()
        let working = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: worktreeID)

        try fixture.append(event(
            type: "task_complete", turnID: "a", terminated: false))
        let partial = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: worktreeID)

        try fixture.append(Data([0x0A]))
        let completed = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: worktreeID)

        #expect(working == .working)
        #expect(partial == nil)
        #expect(completed == .idle)
    }

    @Test func oversizedUnterminatedRecordIsDiscardedWithoutGrowingTheBuffer() async throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        try fixture.write(event(type: "task_started", turnID: "a"))
        let tracker = CodexTranscriptActivityTracker()
        let worktreeID = UUID()
        _ = await tracker.observe(transcriptPath: fixture.path, worktreeID: worktreeID)

        try fixture.append(event(
            type: "agent_message", turnID: "oversized",
            terminated: false,
            exactByteCount: Self.maxBufferedRecordByteCount + 128))
        let catchingUp = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: worktreeID)
        let boundedBuffer = await tracker.bufferedRecordState(transcriptPath: fixture.path)

        #expect(catchingUp == nil)
        #expect(boundedBuffer?.byteCount == Self.maxBufferedRecordByteCount)
        #expect(boundedBuffer?.isDiscarding == false)

        let discardedAtEOF = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: worktreeID)
        let discarding = await tracker.bufferedRecordState(transcriptPath: fixture.path)

        #expect(discardedAtEOF == nil)
        #expect(discarding?.byteCount == 0)
        #expect(discarding?.isDiscarding == true)

        try fixture.append(
            Data([0x0A]) + event(type: "task_complete", turnID: "a"))
        let recovered = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: worktreeID)
        let recoveredBuffer = await tracker.bufferedRecordState(transcriptPath: fixture.path)

        #expect(recovered == .idle)
        #expect(recoveredBuffer?.byteCount == 0)
        #expect(recoveredBuffer?.isDiscarding == false)
    }

    @Test func oversizedCompleteRecordIsNotDecodedBeforeLaterLifecycleEvent() async throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        try fixture.write(event(type: "task_started", turnID: "a"))
        let tracker = CodexTranscriptActivityTracker()
        let worktreeID = UUID()
        _ = await tracker.observe(transcriptPath: fixture.path, worktreeID: worktreeID)

        try fixture.append(
            event(
                type: "task_started", turnID: "oversized",
                exactByteCount: Self.maxBufferedRecordByteCount + 128)
                + event(type: "task_complete", turnID: "a"))
        let catchingUp = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: worktreeID)
        let state = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: worktreeID)

        #expect(catchingUp == nil)
        #expect(state == .idle)
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

    @Test func truncationRebuildUsesBoundedTailPolicy() async throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        let initialPrefix = event(
            type: "agent_message", turnID: "initial-padding",
            exactByteCount: Self.initialTailByteLimit + 512)
        try fixture.write(
            initialPrefix
                + event(type: "task_started", turnID: "initial")
                + event(
                    type: "agent_message", turnID: "more-padding",
                    exactByteCount: Self.initialTailByteLimit + 512))
        let tracker = CodexTranscriptActivityTracker()
        let worktreeID = UUID()
        _ = await tracker.observe(transcriptPath: fixture.path, worktreeID: worktreeID)

        let oldStart = event(type: "task_started", turnID: "old")
        let replacementTail = event(
            type: "agent_message", turnID: "replacement-padding",
            exactByteCount: Self.initialTailByteLimit)
        try fixture.write(oldStart + replacementTail)
        let rebuilt = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: worktreeID)

        #expect(rebuilt == nil)
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

    @Test func zeroBatchBudgetDoesNotReadOrCreateABaseline() async throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        let record = event(type: "task_started", turnID: "a")
        try fixture.write(record)
        let tracker = CodexTranscriptActivityTracker()
        let target = CodexTranscriptActivityTracker.Target(
            transcriptPath: fixture.path, worktreeID: UUID())

        let noBudget = await tracker.observe(
            transcripts: [target], totalByteLimit: 0)

        #expect(noBudget.isEmpty)
        #expect(!(await tracker.hasBaseline(transcriptPath: fixture.path)))

        let caughtUp = await tracker.observe(
            transcripts: [target], totalByteLimit: UInt64(record.count))
        #expect(caughtUp[fixture.path] == .working)
    }

    @Test func batchCursorRotatesWhenTheFirstTranscriptKeepsGrowing() async throws {
        let first = try TranscriptFixture()
        let second = try TranscriptFixture()
        defer {
            first.remove()
            second.remove()
        }
        let tracker = CodexTranscriptActivityTracker()
        let worktreeID = UUID()
        let targets = [first, second].map {
            CodexTranscriptActivityTracker.Target(
                transcriptPath: $0.path, worktreeID: worktreeID)
        }
        for fixture in [first, second] {
            try fixture.write(
                event(type: "task_complete", turnID: fixture.path)
                    + event(
                        type: "agent_message", turnID: "backlog",
                        terminated: false,
                        exactByteCount: Self.initialTailByteLimit))
        }
        let onePathBudget: UInt64 = 2

        _ = await tracker.observe(transcripts: targets, totalByteLimit: onePathBudget)
        let firstAfterOne = await tracker.bufferedRecordState(transcriptPath: first.path)
        let secondAfterOne = await tracker.bufferedRecordState(transcriptPath: second.path)
        #expect([firstAfterOne?.byteCount, secondAfterOne?.byteCount].compactMap { $0 }
            .sorted() == [Int(onePathBudget) - 1])

        try first.append(event(type: "agent_message", turnID: "still-growing"))
        _ = await tracker.observe(transcripts: targets, totalByteLimit: onePathBudget)
        let firstAfterTwo = await tracker.bufferedRecordState(transcriptPath: first.path)
        let secondAfterTwo = await tracker.bufferedRecordState(transcriptPath: second.path)

        #expect(firstAfterTwo?.byteCount == Int(onePathBudget) - 1)
        #expect(secondAfterTwo?.byteCount == Int(onePathBudget) - 1)
    }

    @Test func batchCursorRecoversWhenItsSavedPathDisappearsAndInputsReorder() async throws {
        let first = try TranscriptFixture()
        let removed = try TranscriptFixture()
        let third = try TranscriptFixture()
        defer {
            first.remove()
            removed.remove()
            third.remove()
        }
        let tracker = CodexTranscriptActivityTracker()
        let worktreeID = UUID()
        let targets = [first, removed, third].map {
            CodexTranscriptActivityTracker.Target(
                transcriptPath: $0.path, worktreeID: worktreeID)
        }
        for fixture in [first, removed, third] {
            try fixture.write(
                event(type: "task_complete", turnID: fixture.path)
                    + event(
                        type: "agent_message", turnID: "backlog",
                        terminated: false,
                        exactByteCount: Self.initialTailByteLimit))
        }
        let onePathBudget: UInt64 = 2

        _ = await tracker.observe(transcripts: targets, totalByteLimit: onePathBudget)
        #expect(await tracker.bufferedRecordState(transcriptPath: first.path)?.byteCount
            == Int(onePathBudget) - 1)

        let withoutSavedPath = [targets[0], targets[2]]
        _ = await tracker.observe(
            transcripts: withoutSavedPath, totalByteLimit: onePathBudget)
        #expect(await tracker.bufferedRecordState(transcriptPath: third.path)?.byteCount
            == Int(onePathBudget) - 1)
        #expect(await tracker.bufferedRecordState(transcriptPath: first.path)?.byteCount
            == Int(onePathBudget) - 1)

        let reordered = [targets[2], targets[0]]
        _ = await tracker.observe(
            transcripts: reordered, totalByteLimit: onePathBudget)
        #expect(await tracker.bufferedRecordState(transcriptPath: first.path)?.byteCount
            == Int(onePathBudget) * 2 - 1)
    }

    @Test func scopedPollDoesNotResetFleetBatchCursor() async throws {
        let first = try TranscriptFixture()
        let second = try TranscriptFixture()
        defer {
            first.remove()
            second.remove()
        }
        let tracker = CodexTranscriptActivityTracker()
        let firstWorktreeID = UUID()
        let secondWorktreeID = UUID()
        let firstTarget = CodexTranscriptActivityTracker.Target(
            transcriptPath: first.path, worktreeID: firstWorktreeID)
        let secondTarget = CodexTranscriptActivityTracker.Target(
            transcriptPath: second.path, worktreeID: secondWorktreeID)
        for fixture in [first, second] {
            try fixture.write(
                event(type: "task_complete", turnID: fixture.path)
                    + event(
                        type: "agent_message", turnID: "backlog",
                        terminated: false,
                        exactByteCount: Self.initialTailByteLimit))
        }
        let onePathBudget: UInt64 = 2

        _ = await tracker.observe(
            transcripts: [firstTarget, secondTarget], totalByteLimit: onePathBudget)
        await tracker.retain(
            transcriptPaths: [first.path, second.path], scope: nil)

        _ = await tracker.observe(
            transcripts: [firstTarget], totalByteLimit: onePathBudget)
        await tracker.retain(
            transcriptPaths: [first.path], scope: firstWorktreeID)
        let firstAfterScopedPoll = await tracker.bufferedRecordState(
            transcriptPath: first.path)?.byteCount

        _ = await tracker.observe(
            transcripts: [firstTarget, secondTarget], totalByteLimit: onePathBudget)

        #expect(firstAfterScopedPoll == Int(onePathBudget) * 2 - 1)
        #expect(await tracker.bufferedRecordState(transcriptPath: first.path)?.byteCount
            == firstAfterScopedPoll)
        #expect(await tracker.bufferedRecordState(transcriptPath: second.path)?.byteCount
            == Int(onePathBudget) - 1)
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
        startedAt: Int? = nil,
        completedAt: Int? = nil,
        terminated: Bool = true,
        padding: String? = nil,
        exactByteCount: Int? = nil
    ) -> Data {
        let newline = terminated ? "\n" : ""
        func encoded(padding: String?) -> Data {
            let startedAtField = startedAt.map { #", "started_at":\#($0)"# } ?? ""
            let completedAtField = completedAt.map { #", "completed_at":\#($0)"# } ?? ""
            let paddingField = padding.map { #", "padding":"\#($0)""# } ?? ""
            return Data((
                #"{"type":"event_msg","payload":{"type":"\#(type)","turn_id":"\#(turnID)"\#(startedAtField)\#(completedAtField)\#(paddingField)}}"#
                    + newline).utf8)
        }

        let base = encoded(padding: padding)
        guard let exactByteCount else { return base }

        let emptyPadded = encoded(padding: "")
        precondition(exactByteCount >= emptyPadded.count)
        let exactPadding = String(repeating: "x", count: exactByteCount - emptyPadded.count)
        return encoded(padding: exactPadding)
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
        try overwrite(at: 0, with: data)
    }

    func overwrite(at offset: UInt64, with data: Data) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
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
