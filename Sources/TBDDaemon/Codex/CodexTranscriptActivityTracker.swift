import Foundation
import TBDShared

struct CodexTurnLifecycleReducer: Sendable {
    private struct EventEnvelope: Decodable {
        let type: String
        let payload: Payload
    }

    private struct Payload: Decodable {
        let type: String
        let turnID: String?
        let startedAt: Double?

        enum CodingKeys: String, CodingKey {
            case type
            case turnID = "turn_id"
            case startedAt = "started_at"
        }
    }

    private struct Turn: Sendable {
        let id: String
        let startedAt: Double?
    }

    private var currentTurn: Turn?
    private var hasLifecycleEvidence = false

    var activityState: TerminalActivityState? {
        guard hasLifecycleEvidence else { return nil }
        return currentTurn == nil ? .idle : .working
    }

    mutating func consume(line: Data) {
        guard let envelope = try? JSONDecoder().decode(EventEnvelope.self, from: line),
              envelope.type == "event_msg",
              let turnID = envelope.payload.turnID else { return }

        switch envelope.payload.type {
        case "task_started":
            hasLifecycleEvidence = true
            currentTurn = Turn(id: turnID, startedAt: envelope.payload.startedAt)
        case "task_complete", "turn_aborted":
            hasLifecycleEvidence = true
            if let currentTurn,
               currentTurn.id == turnID
                || currentTurn.startedAt != nil
                && currentTurn.startedAt == envelope.payload.startedAt {
                self.currentTurn = nil
            }
        default:
            break
        }
    }
}

/// Reconstructs a Codex session's turn activity from its append-only JSONL
/// transcript. Each path is bootstrapped from a bounded tail once, then only
/// from the last successfully-read offset on later observations. An observation
/// advances by a bounded amount and reports no state until it reaches the EOF
/// captured at its start, so partially-reduced lifecycle history is never shown.
actor CodexTranscriptActivityTracker {
    struct Target: Sendable {
        let transcriptPath: String
        let worktreeID: UUID
    }

    private struct Baseline {
        var worktreeID: UUID
        var offset: UInt64
        var pendingFragment: Data
        var discardingCurrentLine: Bool
        var reducer: CodexTurnLifecycleReducer
    }

    private struct StepResult {
        enum Status {
            case caughtUp
            case behind
            case unavailable
        }

        let state: TerminalActivityState?
        let bytesRead: UInt64
        let status: Status
    }

    private static let readChunkSize = 64 * 1024
    static let initialTailByteLimit: UInt64 = 1024 * 1024
    static let incrementalReadByteLimit = initialTailByteLimit
    static let requestReadByteLimit = incrementalReadByteLimit
    static let maxBufferedRecordByteCount = Int(initialTailByteLimit)
    private var baselines: [String: Baseline] = [:]
    private var nextBatchPathOrder: [String] = []

    var baselineCount: Int { baselines.count }

    /// Returns nil when the transcript cannot be read for this observation.
    /// In particular, a cached positive state is never served as evidence that
    /// an inaccessible transcript is still active.
    func observe(transcriptPath: String, worktreeID: UUID) -> TerminalActivityState? {
        let result = observeStep(
            transcriptPath: transcriptPath,
            worktreeID: worktreeID,
            byteLimit: Self.incrementalReadByteLimit)
        guard case .caughtUp = result.status else { return nil }
        return result.state
    }

    /// Observes several transcripts under one shared byte budget. Paths still
    /// behind their observed EOF are revisited in round-robin order, including
    /// across calls, and do not publish an intermediate reducer state.
    func observe(
        transcripts: [Target],
        totalByteLimit: UInt64 = requestReadByteLimit
    ) -> [String: TerminalActivityState] {
        guard totalByteLimit > 0 else { return [:] }

        var seenPaths: Set<String> = []
        let uniqueTargets = transcripts.filter {
            seenPaths.insert($0.transcriptPath).inserted
        }
        guard !uniqueTargets.isEmpty else { return [:] }

        let currentPaths = Set(uniqueTargets.map(\.transcriptPath))
        let nextBatchStartPath = nextBatchPathOrder.first(where: currentPaths.contains)
        let startIndex = nextBatchStartPath.flatMap { path in
            uniqueTargets.firstIndex { $0.transcriptPath == path }
        } ?? 0
        let targets = Array(uniqueTargets[startIndex...] + uniqueTargets[..<startIndex])
        var active = Array(repeating: true, count: targets.count)
        var activeCount = targets.count
        var cursor = 0
        var remainingByteCount = totalByteLimit
        var states: [String: TerminalActivityState] = [:]

        while remainingByteCount > 0, activeCount > 0 {
            if active[cursor] {
                let target = targets[cursor]
                let result = observeStep(
                    transcriptPath: target.transcriptPath,
                    worktreeID: target.worktreeID,
                    byteLimit: min(UInt64(Self.readChunkSize), remainingByteCount))
                remainingByteCount -= result.bytesRead

                switch result.status {
                case .caughtUp:
                    if let state = result.state {
                        states[target.transcriptPath] = state
                    }
                    active[cursor] = false
                    activeCount -= 1
                case .unavailable:
                    active[cursor] = false
                    activeCount -= 1
                case .behind:
                    if result.bytesRead == 0 {
                        // A future scanner change must not turn a no-progress
                        // result into a tight loop on the terminal-list path.
                        active[cursor] = false
                        activeCount -= 1
                    }
                }
            }
            cursor = (cursor + 1) % targets.count
        }

        nextBatchPathOrder =
            targets[cursor...].map(\.transcriptPath)
            + targets[..<cursor].map(\.transcriptPath)
        return states
    }

    private func observeStep(
        transcriptPath: String,
        worktreeID: UUID,
        byteLimit: UInt64
    ) -> StepResult {
        guard byteLimit > 0 else {
            return StepResult(state: nil, bytesRead: 0, status: .behind)
        }
        let previous = baselines[transcriptPath]
        var bytesRead: UInt64 = 0

        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: transcriptPath))
            defer { try? handle.close() }

            let fileSize = try handle.seekToEnd()
            var baseline: Baseline
            if let previous, fileSize >= previous.offset {
                baseline = previous
                baseline.worktreeID = worktreeID
            } else {
                let prepared = try makeTailBaseline(
                    handle: handle,
                    fileSize: fileSize,
                    worktreeID: worktreeID)
                baseline = prepared.baseline
                bytesRead = prepared.bytesRead
            }

            let unreadByteCount = fileSize - baseline.offset
            let readByteCount = min(unreadByteCount, byteLimit - bytesRead)
            let observationEndOffset = baseline.offset + readByteCount
            try handle.seek(toOffset: baseline.offset)
            while baseline.offset < observationEndOffset {
                let remaining = observationEndOffset - baseline.offset
                let count = Int(min(UInt64(Self.readChunkSize), remaining))
                guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else {
                    return StepResult(state: nil, bytesRead: bytesRead, status: .unavailable)
                }
                baseline.offset += UInt64(chunk.count)
                bytesRead += UInt64(chunk.count)
                consumeCompleteLines(from: chunk, into: &baseline)
            }

            baselines[transcriptPath] = baseline
            guard baseline.offset == fileSize else {
                return StepResult(state: nil, bytesRead: bytesRead, status: .behind)
            }
            guard baseline.pendingFragment.isEmpty,
                  !baseline.discardingCurrentLine else {
                return StepResult(state: nil, bytesRead: bytesRead, status: .caughtUp)
            }
            return StepResult(
                state: baseline.reducer.activityState,
                bytesRead: bytesRead,
                status: .caughtUp)
        } catch {
            return StepResult(state: nil, bytesRead: bytesRead, status: .unavailable)
        }
    }

    /// `scope == nil` means the supplied paths cover the whole fleet. A UUID
    /// limits pruning to baselines last observed in that worktree.
    func retain(transcriptPaths: Set<String>, scope worktreeID: UUID?) {
        guard let worktreeID else {
            baselines = baselines.filter { transcriptPaths.contains($0.key) }
            return
        }
        baselines = baselines.filter {
            $0.value.worktreeID != worktreeID || transcriptPaths.contains($0.key)
        }
    }

    func hasBaseline(transcriptPath: String) -> Bool {
        baselines[transcriptPath] != nil
    }

    func bufferedRecordState(transcriptPath: String) -> (byteCount: Int, isDiscarding: Bool)? {
        guard let baseline = baselines[transcriptPath] else { return nil }
        return (baseline.pendingFragment.count, baseline.discardingCurrentLine)
    }

    private func makeTailBaseline(
        handle: FileHandle,
        fileSize: UInt64,
        worktreeID: UUID
    ) throws -> (baseline: Baseline, bytesRead: UInt64) {
        let startOffset = fileSize > Self.initialTailByteLimit
            ? fileSize - Self.initialTailByteLimit
            : 0
        var discardingCurrentLine = false
        var bytesRead: UInt64 = 0

        if startOffset > 0 {
            try handle.seek(toOffset: startOffset - 1)
            let precedingByte = try handle.read(upToCount: 1)?.first
            bytesRead = precedingByte == nil ? 0 : 1
            discardingCurrentLine = precedingByte != 0x0A
        }

        return (
            Baseline(
                worktreeID: worktreeID,
                offset: startOffset,
                pendingFragment: Data(),
                discardingCurrentLine: discardingCurrentLine,
                reducer: CodexTurnLifecycleReducer()),
            bytesRead)
    }

    private func consumeCompleteLines(from chunk: Data, into baseline: inout Baseline) {
        var scanStart = chunk.startIndex

        if baseline.discardingCurrentLine {
            guard let newline = chunk.firstIndex(of: 0x0A) else { return }
            baseline.discardingCurrentLine = false
            scanStart = chunk.index(after: newline)
        }

        while scanStart != chunk.endIndex {
            if let newline = chunk[scanStart...].firstIndex(of: 0x0A) {
                let segmentCount = chunk.distance(from: scanStart, to: newline)
                if segmentCount <= Self.maxBufferedRecordByteCount - baseline.pendingFragment.count {
                    baseline.pendingFragment.append(contentsOf: chunk[scanStart..<newline])
                    baseline.reducer.consume(line: baseline.pendingFragment)
                }
                baseline.pendingFragment.removeAll(keepingCapacity: false)
                scanStart = chunk.index(after: newline)
                continue
            }

            let segmentCount = chunk.distance(from: scanStart, to: chunk.endIndex)
            if segmentCount <= Self.maxBufferedRecordByteCount - baseline.pendingFragment.count {
                baseline.pendingFragment.append(contentsOf: chunk[scanStart...])
            } else {
                baseline.pendingFragment.removeAll(keepingCapacity: false)
                baseline.discardingCurrentLine = true
            }
            return
        }
    }
}
