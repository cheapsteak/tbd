import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("Codex transcript activity tracker")
struct CodexTranscriptActivityTrackerTests {
    private static let transcriptReadByteLimit =
        Int(CodexTranscriptActivityTracker.transcriptReadByteLimit)
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

    @Test(
        "a rewritten close without start time prefers false idle",
        arguments: ["task_complete", "turn_aborted"]
    )
    func rewrittenCloseWithoutStartTimePrefersFalseIdle(type: String) {
        var reducer = CodexTurnLifecycleReducer()
        reducer.consume(line: event(type: "task_started", turnID: "started-id"))

        reducer.consume(line: event(type: type, turnID: "rewritten-close-id"))

        #expect(reducer.activityState == .idle)
    }

    @Test(
        "a mismatched no-time close idles a genuinely open successor",
        arguments: ["task_complete", "turn_aborted"]
    )
    func mismatchedNoTimeCloseIdlesOpenSuccessor(type: String) {
        var reducer = CodexTurnLifecycleReducer()
        reducer.consume(line: event(type: "task_started", turnID: "a"))
        reducer.consume(line: event(type: "task_started", turnID: "b"))

        reducer.consume(line: event(type: type, turnID: "a"))

        // With no started_at there is no trustworthy correlation key. The
        // product policy deliberately prefers false idle to a stuck spinner.
        #expect(reducer.activityState == .idle)
    }

    @Test(
        "a close without a turn ID prefers false idle",
        arguments: ["task_complete", "turn_aborted"]
    )
    func closeWithoutTurnIDPrefersFalseIdle(type: String) {
        var reducer = CodexTurnLifecycleReducer()
        reducer.consume(line: event(
            type: "task_started", turnID: "started-id", startedAt: 200))

        reducer.consume(line: event(type: type, turnID: nil, startedAt: 100))

        #expect(reducer.activityState == .idle)
    }

    @Test func startWithoutTurnIDIsIgnored() {
        var reducer = CodexTurnLifecycleReducer()

        reducer.consume(line: event(type: "task_started", turnID: nil))

        #expect(reducer.activityState == nil)
    }

    @Test func closeForKnownOlderStartTimeDoesNotCloseOpenTurn() {
        var reducer = CodexTurnLifecycleReducer()
        reducer.consume(line: event(type: "task_started", turnID: "current", startedAt: 200))

        reducer.consume(line: event(type: "task_complete", turnID: "older", startedAt: 100))

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
        reducer.consume(line: event(type: "task_started", turnID: "a", startedAt: 100))
        reducer.consume(line: event(type: "task_started", turnID: "b", startedAt: 200))

        reducer.consume(line: event(type: "task_complete", turnID: "a", startedAt: 100))
        #expect(reducer.activityState == .working)

        reducer.consume(line: event(type: "task_complete", turnID: "b", startedAt: 200))
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

    @Test func threadSpawnChildCloseDoesNotRestoreCopiedParentTurn() {
        var reducer = CodexTurnLifecycleReducer()
        reducer.consume(line: Data(
            #"{"type":"session_meta","payload":{"source":{"subagent":{"thread_spawn":{"depth":1}}}}}"#.utf8))
        reducer.consume(line: event(
            type: "task_started", turnID: "copied-parent", startedAt: 100))
        reducer.consume(line: event(
            type: "task_started", turnID: "child", startedAt: 200))

        reducer.consume(line: event(
            type: "task_complete", turnID: "child", startedAt: 200,
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

    @Test("generationless direct observation fences current EOF")
    func generationlessDirectObservationFencesCurrentEOF() async throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        try fixture.write(event(type: "task_started", turnID: "historical"))
        let tracker = CodexTranscriptActivityTracker()
        let worktreeID = UUID()

        let cold = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: worktreeID)
        #expect(cold == nil)

        try fixture.append(event(type: "task_started", turnID: "current"))
        let incremental = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: worktreeID)
        #expect(incremental == .working)
    }

    @Test("generationless cold targets fence current EOF before incremental observation")
    func generationlessColdTargetFencesCurrentEOF() async throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        try fixture.write(event(type: "task_started", turnID: "historical"))
        let tracker = CodexTranscriptActivityTracker()
        let target = CodexTranscriptActivityTracker.Target(
            transcriptPath: fixture.path,
            worktreeID: UUID(),
            terminalID: nil,
            sessionGeneration: nil,
            transcriptBoundaryOffset: nil)

        let cold = await tracker.observe(transcripts: [target])
        #expect(cold[target.transcriptPath] == nil)

        try fixture.append(event(type: "task_started", turnID: "current"))
        let incremental = await tracker.observe(transcripts: [target])
        #expect(incremental[target.transcriptPath] == .working)
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

        let crossingStart = event(type: "task_started", turnID: "a", startedAt: 200)
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
                + event(type: "task_complete", turnID: "different-turn", startedAt: 100))

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
        try fixture.write(Data())
        let tracker = CodexTranscriptActivityTracker()
        let worktreeID = UUID()
        _ = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: worktreeID)
        try fixture.append(initial)
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
        try fixture.write(Data())
        let tracker = CodexTranscriptActivityTracker()
        let worktreeID = UUID()
        _ = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: worktreeID)
        try fixture.append(record)

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
        try fixture.write(Data())
        let tracker = CodexTranscriptActivityTracker()
        let worktreeID = UUID()
        _ = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: worktreeID)
        try fixture.append(event(type: "task_started", turnID: "a"))
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
        try fixture.write(Data())
        let tracker = CodexTranscriptActivityTracker()
        let worktreeID = UUID()
        _ = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: worktreeID)
        try fixture.append(record)

        let state = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: worktreeID)

        #expect(state == .working)
    }

    @Test func generationlessTruncationFencesReplacementEOF() async throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        try fixture.write(Data())
        let tracker = CodexTranscriptActivityTracker()
        let worktreeID = UUID()
        _ = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: worktreeID)
        try fixture.append(
            event(type: "task_started", turnID: "a")
                + event(type: "agent_message", turnID: "padding"))
        #expect(await tracker.observe(
            transcriptPath: fixture.path, worktreeID: worktreeID) == .working)

        try fixture.write(event(type: "task_started", turnID: "replacement"))
        let fenced = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: worktreeID)
        #expect(fenced == nil)

        try fixture.append(event(type: "task_complete", turnID: "replacement"))
        let incremental = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: worktreeID)
        #expect(incremental == .idle)
    }

    @Test func transcriptPathsHaveIndependentBaselines() async throws {
        let first = try TranscriptFixture()
        let second = try TranscriptFixture()
        defer {
            first.remove()
            second.remove()
        }
        try first.write(Data())
        try second.write(Data())
        let tracker = CodexTranscriptActivityTracker()
        let worktreeID = UUID()
        _ = await tracker.observe(
            transcriptPath: first.path, worktreeID: worktreeID)
        _ = await tracker.observe(
            transcriptPath: second.path, worktreeID: worktreeID)
        try first.append(event(type: "task_started", turnID: "a"))
        try second.append(event(type: "task_complete", turnID: "b"))

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

        let fenced = await tracker.observe(
            transcripts: [target], totalByteLimit: UInt64(record.count))
        #expect(fenced[fixture.path] == nil)
        #expect(await tracker.hasBaseline(transcriptPath: fixture.path))

        try fixture.append(event(type: "task_started", turnID: "current"))
        let caughtUp = await tracker.observe(transcripts: [target])
        #expect(caughtUp[fixture.path] == .working)
    }

    @Test func batchStepLimitBoundsCaughtUpAndUnreadablePaths() async throws {
        let stepLimit = 16
        let unreadable = try (0..<(stepLimit / 2)).map { _ in
            try TranscriptFixture()
        }
        let readable = try (0...(stepLimit / 2)).map { _ in
            try TranscriptFixture()
        }
        defer {
            for fixture in unreadable + readable {
                fixture.remove()
            }
        }
        let tracker = CodexTranscriptActivityTracker()
        let worktreeID = UUID()
        for fixture in readable {
            try fixture.write(Data())
            _ = await tracker.observe(
                transcriptPath: fixture.path, worktreeID: worktreeID)
            try fixture.append(event(type: "task_complete", turnID: fixture.path))
        }
        let targets = (unreadable + readable).map {
            CodexTranscriptActivityTracker.Target(
                transcriptPath: $0.path, worktreeID: worktreeID)
        }

        let first = await tracker.observe(transcripts: targets)
        let second = await tracker.observe(transcripts: targets)

        #expect(first.count == stepLimit / 2)
        #expect(first[readable.last!.path] == nil)
        #expect(second[readable.last!.path] == .idle)
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
            try fixture.write(Data())
            _ = await tracker.observe(
                transcriptPath: fixture.path, worktreeID: worktreeID)
            try fixture.append(
                event(type: "task_complete", turnID: fixture.path)
                    + event(
                        type: "agent_message", turnID: "backlog",
                        terminated: false,
                        exactByteCount: Self.transcriptReadByteLimit))
        }
        let onePathBudget: UInt64 = 2

        _ = await tracker.observe(transcripts: targets, totalByteLimit: onePathBudget)
        let firstAfterOne = await tracker.bufferedRecordState(transcriptPath: first.path)
        let secondAfterOne = await tracker.bufferedRecordState(transcriptPath: second.path)
        #expect([firstAfterOne?.byteCount, secondAfterOne?.byteCount].compactMap { $0 }
            .sorted() == [0, Int(onePathBudget)])

        try first.append(event(type: "agent_message", turnID: "still-growing"))
        _ = await tracker.observe(transcripts: targets, totalByteLimit: onePathBudget)
        let firstAfterTwo = await tracker.bufferedRecordState(transcriptPath: first.path)
        let secondAfterTwo = await tracker.bufferedRecordState(transcriptPath: second.path)

        #expect(firstAfterTwo?.byteCount == Int(onePathBudget))
        #expect(secondAfterTwo?.byteCount == Int(onePathBudget))
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
            try fixture.write(Data())
            _ = await tracker.observe(
                transcriptPath: fixture.path, worktreeID: worktreeID)
            try fixture.append(
                event(type: "task_complete", turnID: fixture.path)
                    + event(
                        type: "agent_message", turnID: "backlog",
                        terminated: false,
                        exactByteCount: Self.transcriptReadByteLimit))
        }
        let onePathBudget: UInt64 = 2

        _ = await tracker.observe(transcripts: targets, totalByteLimit: onePathBudget)
        #expect(await tracker.bufferedRecordState(transcriptPath: first.path)?.byteCount
            == Int(onePathBudget))

        let withoutSavedPath = [targets[0], targets[2]]
        _ = await tracker.observe(
            transcripts: withoutSavedPath, totalByteLimit: onePathBudget)
        #expect(await tracker.bufferedRecordState(transcriptPath: third.path)?.byteCount
            == Int(onePathBudget))
        #expect(await tracker.bufferedRecordState(transcriptPath: first.path)?.byteCount
            == Int(onePathBudget))

        let reordered = [targets[2], targets[0]]
        _ = await tracker.observe(
            transcripts: reordered, totalByteLimit: onePathBudget)
        #expect(await tracker.bufferedRecordState(transcriptPath: first.path)?.byteCount
            == Int(onePathBudget) * 2)
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
            try fixture.write(Data())
            _ = await tracker.observe(
                transcriptPath: fixture.path,
                worktreeID: fixture.path == first.path ? firstWorktreeID : secondWorktreeID)
            try fixture.append(
                event(type: "task_complete", turnID: fixture.path)
                    + event(
                        type: "agent_message", turnID: "backlog",
                        terminated: false,
                        exactByteCount: Self.transcriptReadByteLimit))
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

        #expect(firstAfterScopedPoll == Int(onePathBudget) * 2)
        #expect(await tracker.bufferedRecordState(transcriptPath: first.path)?.byteCount
            == firstAfterScopedPoll)
        #expect(await tracker.bufferedRecordState(transcriptPath: second.path)?.byteCount
            == Int(onePathBudget))
    }

    @Test func unreadablePathReturnsNilInsteadOfCachedWorking() async throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        try fixture.write(Data())
        let tracker = CodexTranscriptActivityTracker()
        let worktreeID = UUID()
        _ = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: worktreeID)
        try fixture.append(
            event(type: "task_started", turnID: "a", padding: String(repeating: "x", count: 256)))
        let initial = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: worktreeID)
        try fixture.replaceFileWithDirectory()

        let unreadable = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: worktreeID)
        try fixture.replaceDirectoryWithFile(Data())
        let refenced = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: worktreeID)
        try fixture.append(event(type: "task_complete", turnID: "replacement"))
        let recovered = await tracker.observe(
            transcriptPath: fixture.path, worktreeID: worktreeID)

        #expect(initial == .working)
        #expect(unreadable == nil)
        #expect(refenced == nil)
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

    @Test func pendingSessionBoundaryPreventsNextObservationBootstrap() async throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        let tracker = CodexTranscriptActivityTracker()
        let target = CodexTranscriptActivityTracker.Target(
            transcriptPath: fixture.path,
            worktreeID: UUID(),
            terminalID: UUID(),
            sessionGeneration: Date(timeIntervalSince1970: 1_700_000_000))

        await tracker.establishSessionBoundariesIfAbsent(transcripts: [target])
        try fixture.write(event(type: "task_started", turnID: "historical"))
        let states = await tracker.observe(transcripts: [target])

        #expect(states[target.transcriptPath] == nil)
    }

    @Test("known boundary recovery advances past the request window and resumes incremental reads")
    func knownBoundaryRecoveryIsProgressive() async throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        var transcript = event(type: "task_started", turnID: "current")
        for index in 0..<320 {
            transcript += event(
                type: "agent_message",
                turnID: "padding-\(index)",
                exactByteCount: 4 * 1024)
        }
        #expect(transcript.count > Self.transcriptReadByteLimit)
        try fixture.write(transcript)
        let tracker = CodexTranscriptActivityTracker()
        let target = CodexTranscriptActivityTracker.Target(
            transcriptPath: fixture.path,
            worktreeID: UUID(),
            terminalID: UUID(),
            sessionGeneration: Date(timeIntervalSince1970: 1_790_400_000),
            transcriptBoundaryOffset: 0)
        let pollBudget: UInt64 = 64 * 1024

        let first = await tracker.observe(
            transcripts: [target], totalByteLimit: pollBudget)
        #expect(first[target.transcriptPath] == nil)
        var recovered: TerminalActivityState?
        for _ in 0..<48 where recovered == nil {
            recovered = await tracker.observe(
                transcripts: [target], totalByteLimit: pollBudget)[target.transcriptPath]
        }
        #expect(recovered == .working)

        try fixture.append(event(type: "task_complete", turnID: "current"))
        let completed = await tracker.observe(
            transcripts: [target], totalByteLimit: pollBudget)
        #expect(completed[target.transcriptPath] == .idle)
    }

    @Test("cold recovery scans backward to the newest start without reading older history")
    func coldRecoveryStopsAtNewestStart() async throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        var transcript = Data()
        for index in 0..<6 {
            transcript += event(
                type: "agent_message", turnID: "old-padding-\(index)",
                exactByteCount: 512 * 1024)
        }
        transcript += event(type: "task_started", turnID: "current", startedAt: 200)
        for index in 0..<3 {
            transcript += event(
                type: "agent_message", turnID: "new-padding-\(index)",
                exactByteCount: 400 * 1024)
        }
        try fixture.write(transcript)
        let tracker = CodexTranscriptActivityTracker()
        let target = recoveryTarget(fixture: fixture, boundary: 0, generation: 1_790_401_000)

        var observations: [TerminalActivityState?] = []
        for _ in 0..<4 where observations.last != .working {
            observations.append(
                await tracker.observe(transcripts: [target])[fixture.path])
        }

        #expect(observations.prefix(2).allSatisfy { $0 == nil })
        #expect(observations.last == .working)
    }

    @Test("reverse recovery agrees with forward lifecycle reduction")
    func reverseRecoveryMatchesForwardLifecycleSemantics() async throws {
        let cases: [[Data]] = [
            [event(type: "task_started", turnID: "current", startedAt: 200)],
            [
                event(type: "task_started", turnID: "current", startedAt: 200),
                event(type: "task_complete", turnID: "current", startedAt: 200),
            ],
            [
                event(type: "task_started", turnID: "current", startedAt: 200),
                event(type: "task_complete", turnID: "older", startedAt: 100),
            ],
            [
                event(type: "task_started", turnID: "current", startedAt: 200),
                event(type: "turn_aborted", turnID: nil, startedAt: 100),
            ],
            [
                event(type: "task_started", turnID: "current", startedAt: 200),
                event(type: "task_complete", turnID: "rewritten", startedAt: nil),
            ],
            [event(type: "task_complete", turnID: "closed", startedAt: 100)],
            [
                Data("not json\n".utf8),
                Data(#"{"type":"response_item","payload":{"type":"task_started","turn_id":"ignored"}}"#.utf8)
                    + Data([0x0A]),
            ],
        ]

        for (index, lines) in cases.enumerated() {
            var reducer = CodexTurnLifecycleReducer()
            lines.forEach { reducer.consume(line: $0) }
            let fixture = try TranscriptFixture()
            defer { fixture.remove() }
            try fixture.write(lines.reduce(into: Data()) { $0 += $1 })
            let tracker = CodexTranscriptActivityTracker()
            let target = recoveryTarget(
                fixture: fixture, boundary: 0,
                generation: 1_790_401_010 + Double(index))

            let recovered = await tracker.observe(transcripts: [target])[fixture.path]

            #expect(recovered == reducer.activityState)
        }
    }

    @Test("reliable closes encountered backward match the newest start by ID or time")
    func coldRecoveryCorrelatesReliableCloses() async throws {
        let matchingID = try TranscriptFixture()
        let matchingTime = try TranscriptFixture()
        let mismatching = try TranscriptFixture()
        defer {
            matchingID.remove()
            matchingTime.remove()
            mismatching.remove()
        }
        try matchingID.write(
            event(type: "task_started", turnID: "current", startedAt: 200)
                + event(type: "task_complete", turnID: "current", startedAt: 999))
        try matchingTime.write(
            event(type: "task_started", turnID: "current", startedAt: 200)
                + event(type: "turn_aborted", turnID: "rewritten", startedAt: 200))
        try mismatching.write(
            event(type: "task_started", turnID: "current", startedAt: 200)
                + event(type: "task_complete", turnID: "older", startedAt: 100))
        let tracker = CodexTranscriptActivityTracker()
        let targets = [matchingID, matchingTime, mismatching].enumerated().map { index, fixture in
            recoveryTarget(
                fixture: fixture, boundary: 0,
                generation: 1_790_401_100 + Double(index))
        }

        let states = await tracker.observe(transcripts: targets)

        #expect(states[matchingID.path] == .idle)
        #expect(states[matchingTime.path] == .idle)
        #expect(states[mismatching.path] == .working)
    }

    @Test("many reliable closes transition to bounded forward replay at the newest start")
    func coldRecoveryDoesNotRetainReliableCloseKeys() async throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        var transcript = event(type: "task_started", turnID: "current", startedAt: 200)
        for index in 0..<2_000 {
            transcript += event(
                type: "task_complete", turnID: "older-\(index)", startedAt: index + 1_000)
        }
        try fixture.write(transcript)
        let tracker = CodexTranscriptActivityTracker()
        let target = recoveryTarget(fixture: fixture, boundary: 0, generation: 1_790_401_150)

        var phase: CodexTranscriptActivityTracker.ColdRecoveryPhase?
        for _ in 0..<16 where phase != .forwardReplay {
            #expect(await tracker.observe(
                transcripts: [target], totalByteLimit: 64 * 1024)[fixture.path] == nil)
            phase = await tracker.coldRecoveryPhase(transcriptPath: fixture.path)
        }

        #expect(phase == .forwardReplay)
        var state: TerminalActivityState?
        for _ in 0..<16 where state == nil {
            state = await tracker.observe(
                transcripts: [target], totalByteLimit: 64 * 1024)[fixture.path]
        }
        #expect(state == .working)
    }

    @Test("an unreliable close synchronizes idle without scanning older history")
    func coldRecoveryStopsAtUnconditionalClose() async throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        var transcript = Data()
        for index in 0..<6 {
            transcript += event(
                type: "agent_message", turnID: "padding-\(index)",
                exactByteCount: 512 * 1024)
        }
        transcript += event(type: "task_complete", turnID: "rewritten", startedAt: nil)
        try fixture.write(transcript)
        let tracker = CodexTranscriptActivityTracker()
        let target = recoveryTarget(fixture: fixture, boundary: 0, generation: 1_790_401_200)

        let states = await tracker.observe(
            transcripts: [target], totalByteLimit: 64 * 1024)

        #expect(states[fixture.path] == .idle)
    }

    @Test("recovery reaches the boundary before publishing no lifecycle evidence")
    func coldRecoveryWithNoAnchorScansToBoundary() async throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        var transcript = Data()
        for index in 0..<3 {
            transcript += event(
                type: "agent_message", turnID: "padding-\(index)",
                exactByteCount: 512 * 1024)
        }
        try fixture.write(transcript)
        let tracker = CodexTranscriptActivityTracker()
        let target = recoveryTarget(fixture: fixture, boundary: 0, generation: 1_790_401_300)

        #expect(await tracker.observe(transcripts: [target])[fixture.path] == nil)
        try fixture.append(event(type: "task_started", turnID: "appended"))
        #expect(await tracker.observe(transcripts: [target])[fixture.path] == nil)
        #expect(await tracker.observe(transcripts: [target])[fixture.path] == .working)
    }

    @Test("a record crossing a positive recovery boundary is excluded")
    func coldRecoveryExcludesRecordCrossingPositiveBoundary() async throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        let crossing = event(
            type: "task_started", turnID: "crossing", startedAt: 100,
            exactByteCount: 128 * 1024)
        let boundary = crossing.count / 2
        try fixture.write(crossing + event(type: "agent_message", turnID: "after"))
        let tracker = CodexTranscriptActivityTracker()
        let target = recoveryTarget(
            fixture: fixture, boundary: Int64(boundary), generation: 1_790_401_400)

        #expect(await tracker.observe(transcripts: [target])[fixture.path] == nil)
        try fixture.append(event(type: "task_started", turnID: "current"))
        #expect(await tracker.observe(transcripts: [target])[fixture.path] == .working)
    }

    @Test("a captured partial record remains unknown and recovery stops at its newline")
    func coldRecoveryWaitsForCapturedPartialRecord() async throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        try fixture.write(event(
            type: "task_started", turnID: "current", startedAt: 200,
            terminated: false))
        let tracker = CodexTranscriptActivityTracker()
        let target = recoveryTarget(fixture: fixture, boundary: 0, generation: 1_790_401_500)

        #expect(await tracker.observe(transcripts: [target])[fixture.path] == nil)
        try fixture.append(
            Data([0x0A]) + event(type: "task_complete", turnID: "current", startedAt: 200))
        #expect(await tracker.observe(transcripts: [target])[fixture.path] == .working)
        #expect(await tracker.observe(transcripts: [target])[fixture.path] == .idle)
    }

    @Test("partial completion charges bytes read beyond its first newline")
    func capturedPartialCompletionExhaustsItsReadBudget() async throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        try fixture.write(event(
            type: "task_started", turnID: "current", startedAt: 200,
            terminated: false))
        let tracker = CodexTranscriptActivityTracker()
        let target = recoveryTarget(fixture: fixture, boundary: 0, generation: 1_790_401_550)
        let budget = 64 * 1024

        #expect(await tracker.observe(
            transcripts: [target], totalByteLimit: UInt64(budget))[fixture.path] == nil)
        try fixture.append(
            Data([0x0A])
                + event(
                    type: "agent_message", turnID: "later-padding",
                    exactByteCount: budget))

        #expect(await tracker.observe(
            transcripts: [target], totalByteLimit: UInt64(budget))[fixture.path] == nil)
        #expect(await tracker.coldRecoveryPhase(transcriptPath: fixture.path) == .reverseSearch)
        #expect(await tracker.observe(
            transcripts: [target], totalByteLimit: UInt64(budget))[fixture.path] == .working)
    }

    @Test("shrinking during reverse recovery restarts from the known boundary")
    func shrinkDuringReverseRecoveryRestartsExactly() async throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        var transcript = event(type: "task_started", turnID: "old", startedAt: 100)
        for index in 0..<4 {
            transcript += event(
                type: "agent_message", turnID: "padding-\(index)",
                exactByteCount: 256 * 1024)
        }
        try fixture.write(transcript)
        let tracker = CodexTranscriptActivityTracker()
        let target = recoveryTarget(fixture: fixture, boundary: 0, generation: 1_790_401_575)

        #expect(await tracker.observe(
            transcripts: [target], totalByteLimit: 64 * 1024)[fixture.path] == nil)
        #expect(await tracker.coldRecoveryPhase(transcriptPath: fixture.path) == .reverseSearch)

        try fixture.write(event(type: "task_started", turnID: "replacement", startedAt: 300))

        #expect(await tracker.observe(
            transcripts: [target], totalByteLimit: 64 * 1024)[fixture.path] == .working)
        try fixture.append(event(
            type: "task_complete", turnID: "replacement", startedAt: 300))
        #expect(await tracker.observe(
            transcripts: [target], totalByteLimit: 64 * 1024)[fixture.path] == .idle)
    }

    @Test("malformed and oversized reverse records do not become lifecycle evidence")
    func coldRecoveryIgnoresMalformedAndOversizedRecords() async throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        try fixture.write(
            event(type: "task_complete", turnID: "seed", startedAt: nil)
                + Data("not json\n".utf8)
                + event(
                    type: "task_started", turnID: "oversized",
                    exactByteCount: Self.maxBufferedRecordByteCount + 128))
        let tracker = CodexTranscriptActivityTracker()
        let target = recoveryTarget(fixture: fixture, boundary: 0, generation: 1_790_401_600)

        var state: TerminalActivityState?
        for _ in 0..<4 where state == nil {
            state = await tracker.observe(transcripts: [target])[fixture.path]
        }

        #expect(state == .idle)
    }

    @Test("positive durable boundaries exclude prior lifecycle evidence after restart")
    func positiveBoundaryExcludesPriorLifecycleEvidence() async throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        let orphan = event(type: "task_started", turnID: "orphan")
        try fixture.write(
            orphan + event(type: "agent_message", turnID: "later-session"))
        let target = CodexTranscriptActivityTracker.Target(
            transcriptPath: fixture.path,
            worktreeID: UUID(),
            terminalID: UUID(),
            sessionGeneration: Date(timeIntervalSince1970: 1_790_400_100),
            transcriptBoundaryOffset: Int64(orphan.count))

        let tracker = CodexTranscriptActivityTracker()
        #expect(await tracker.observe(transcripts: [target])[fixture.path] == nil)
        let restartedTracker = CodexTranscriptActivityTracker()
        #expect(await restartedTracker.observe(transcripts: [target])[fixture.path] == nil)

        try fixture.append(event(type: "task_started", turnID: "current"))
        #expect(await restartedTracker.observe(transcripts: [target])[fixture.path] == .working)
    }

    @Test("unknown durable boundary fences at current EOF")
    func unknownBoundaryRetainsConservativeFence() async throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        try fixture.write(event(type: "task_started", turnID: "historical"))
        let tracker = CodexTranscriptActivityTracker()
        let target = CodexTranscriptActivityTracker.Target(
            transcriptPath: fixture.path,
            worktreeID: UUID(),
            terminalID: UUID(),
            sessionGeneration: Date(timeIntervalSince1970: 1_790_400_200),
            transcriptBoundaryOffset: nil)

        #expect(await tracker.observe(transcripts: [target])[fixture.path] == nil)
        try fixture.append(event(type: "task_complete", turnID: "later"))
        #expect(await tracker.observe(transcripts: [target])[fixture.path] == .idle)
    }

    @Test("recovery finishes its captured record without chasing later records")
    func recoveryExtendsOnlyThroughCapturedRecord() async throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        try fixture.write(event(
            type: "task_started", turnID: "current", terminated: false))
        let tracker = CodexTranscriptActivityTracker()
        let target = CodexTranscriptActivityTracker.Target(
            transcriptPath: fixture.path,
            worktreeID: UUID(),
            terminalID: UUID(),
            sessionGeneration: Date(timeIntervalSince1970: 1_790_400_300),
            transcriptBoundaryOffset: 0)

        #expect(await tracker.observe(transcripts: [target])[fixture.path] == nil)
        try fixture.append(
            Data([0x0A]) + event(type: "task_complete", turnID: "current"))
        #expect(await tracker.observe(transcripts: [target])[fixture.path] == .working)
        #expect(await tracker.observe(transcripts: [target])[fixture.path] == .idle)
    }

    @Test("initial durable boundary replays a truncated replacement from zero")
    func initialBoundaryReplaysAfterTruncation() async throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        try fixture.write(
            event(type: "task_started", turnID: "initial")
                + event(type: "agent_message", turnID: "padding"))
        let tracker = CodexTranscriptActivityTracker()
        let target = CodexTranscriptActivityTracker.Target(
            transcriptPath: fixture.path,
            worktreeID: UUID(),
            terminalID: UUID(),
            sessionGeneration: Date(timeIntervalSince1970: 1_790_400_400),
            transcriptBoundaryOffset: 0)

        #expect(await tracker.observe(transcripts: [target])[fixture.path] == .working)
        try fixture.write(event(type: "task_complete", turnID: "replacement"))
        #expect(await tracker.observe(transcripts: [target])[fixture.path] == .idle)
    }

    @Test("positive durable boundary fences when the transcript shrinks below it")
    func positiveBoundaryFencesAfterShrink() async throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        let prefix = event(
            type: "agent_message", turnID: "prefix", exactByteCount: 4 * 1024)
        try fixture.write(prefix + event(type: "task_started", turnID: "current"))
        let tracker = CodexTranscriptActivityTracker()
        let target = CodexTranscriptActivityTracker.Target(
            transcriptPath: fixture.path,
            worktreeID: UUID(),
            terminalID: UUID(),
            sessionGeneration: Date(timeIntervalSince1970: 1_790_400_500),
            transcriptBoundaryOffset: Int64(prefix.count))

        #expect(await tracker.observe(transcripts: [target])[fixture.path] == .working)
        try fixture.write(event(type: "task_started", turnID: "pre-fence"))
        #expect(await tracker.observe(transcripts: [target])[fixture.path] == nil)
        try fixture.append(event(type: "task_started", turnID: "post-fence"))
        #expect(await tracker.observe(transcripts: [target])[fixture.path] == .working)
    }

    @Test("cold boundary preparation obeys the shared filesystem step limit")
    func coldBoundaryPreparationIsStepBounded() async throws {
        let fixtures = try (0...16).map { _ in try TranscriptFixture() }
        defer { fixtures.forEach { $0.remove() } }
        for fixture in fixtures {
            try fixture.write(Data())
        }
        let tracker = CodexTranscriptActivityTracker()
        let worktreeID = UUID()
        let generation = Date(timeIntervalSince1970: 1_790_400_700)
        let targets = fixtures.map {
            CodexTranscriptActivityTracker.Target(
                transcriptPath: $0.path,
                worktreeID: worktreeID,
                terminalID: UUID(),
                sessionGeneration: generation,
                transcriptBoundaryOffset: 0)
        }

        _ = await tracker.observe(transcripts: targets)
        #expect(await tracker.baselineCount == 16)

        _ = await tracker.observe(transcripts: targets)
        #expect(await tracker.baselineCount == 17)
    }

    @Test("progressive recoveries share request bytes in round-robin order")
    func progressiveRecoveriesRemainFair() async throws {
        let first = try TranscriptFixture()
        let second = try TranscriptFixture()
        defer {
            first.remove()
            second.remove()
        }
        let recoveryBytes = 2 * 64 * 1024
        for (index, fixture) in [first, second].enumerated() {
            try fixture.write(
                event(type: "task_started", turnID: "turn-\(index)")
                    + event(
                        type: "agent_message",
                        turnID: "padding-\(index)",
                        exactByteCount: recoveryBytes))
        }
        let tracker = CodexTranscriptActivityTracker()
        let worktreeID = UUID()
        let generation = Date(timeIntervalSince1970: 1_790_400_800)
        let targets = [first, second].map {
            CodexTranscriptActivityTracker.Target(
                transcriptPath: $0.path,
                worktreeID: worktreeID,
                terminalID: UUID(),
                sessionGeneration: generation,
                transcriptBoundaryOffset: 0)
        }
        let oneQuantum: UInt64 = 64 * 1024

        var completionPoll: [String: Int] = [:]
        for poll in 1...16 where completionPoll.count < targets.count {
            let states = await tracker.observe(
                transcripts: targets, totalByteLimit: oneQuantum)
            #expect(states.isEmpty || Set(states.keys) == Set(targets.map(\.transcriptPath)))
            for (path, state) in states {
                #expect(state == .working)
                completionPoll[path] = poll
            }

            if poll.isMultiple(of: 2) {
                let firstPhase = await tracker.coldRecoveryPhase(
                    transcriptPath: first.path)
                let secondPhase = await tracker.coldRecoveryPhase(
                    transcriptPath: second.path)
                #expect(firstPhase == secondPhase)
            }
        }

        #expect(Set(completionPoll.keys) == Set(targets.map(\.transcriptPath)))
        if let firstPoll = completionPoll[first.path],
           let secondPoll = completionPoll[second.path]
        {
            #expect(firstPoll == secondPoll)
        }
    }

    private func event(
        type: String,
        turnID: String?,
        startedAt: Int? = nil,
        completedAt: Int? = nil,
        terminated: Bool = true,
        padding: String? = nil,
        exactByteCount: Int? = nil
    ) -> Data {
        let newline = terminated ? "\n" : ""
        func encoded(padding: String?) -> Data {
            let turnIDField = turnID.map { #", "turn_id":"\#($0)""# } ?? ""
            let startedAtField = startedAt.map { #", "started_at":\#($0)"# } ?? ""
            let completedAtField = completedAt.map { #", "completed_at":\#($0)"# } ?? ""
            let paddingField = padding.map { #", "padding":"\#($0)""# } ?? ""
            return Data((
                #"{"type":"event_msg","payload":{"type":"\#(type)"\#(turnIDField)\#(startedAtField)\#(completedAtField)\#(paddingField)}}"#
                    + newline).utf8)
        }

        let base = encoded(padding: padding)
        guard let exactByteCount else { return base }

        let emptyPadded = encoded(padding: "")
        precondition(exactByteCount >= emptyPadded.count)
        let exactPadding = String(repeating: "x", count: exactByteCount - emptyPadded.count)
        return encoded(padding: exactPadding)
    }

    private func recoveryTarget(
        fixture: TranscriptFixture,
        boundary: Int64,
        generation: Double
    ) -> CodexTranscriptActivityTracker.Target {
        CodexTranscriptActivityTracker.Target(
            transcriptPath: fixture.path,
            worktreeID: UUID(),
            terminalID: UUID(),
            sessionGeneration: Date(timeIntervalSince1970: generation),
            transcriptBoundaryOffset: boundary)
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
