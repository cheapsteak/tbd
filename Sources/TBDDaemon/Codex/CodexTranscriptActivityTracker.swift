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
              envelope.type == "event_msg" else { return }

        switch envelope.payload.type {
        case "task_started":
            guard let turnID = envelope.payload.turnID else { return }
            hasLifecycleEvidence = true
            currentTurn = Turn(id: turnID, startedAt: envelope.payload.startedAt)
        case "task_complete", "turn_aborted":
            hasLifecycleEvidence = true
            // Some rollout writers omit or rewrite the close ID. With no
            // trustworthy identity key, prefer false idle to a permanent
            // false-working indicator. When both records carry identity, a
            // present timestamp still protects a newer turn from a late close.
            if let currentTurn,
               envelope.payload.turnID == nil
                || currentTurn.id == envelope.payload.turnID
                || currentTurn.startedAt != nil
                && currentTurn.startedAt == envelope.payload.startedAt
                || envelope.payload.startedAt == nil {
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
/// SessionStart operations are ordered by their persisted observation generation
/// so a delayed actor hop cannot reverse initial-attachment and boundary policy.
actor CodexTranscriptActivityTracker {
    struct Target: Sendable {
        let transcriptPath: String
        let worktreeID: UUID
        let terminalID: UUID?
        let sessionGeneration: Date?

        init(
            transcriptPath: String,
            worktreeID: UUID,
            terminalID: UUID? = nil,
            sessionGeneration: Date? = nil
        ) {
            self.transcriptPath = transcriptPath
            self.worktreeID = worktreeID
            self.terminalID = terminalID
            self.sessionGeneration = sessionGeneration
        }
    }

    struct StampedObservation: Sendable {
        let states: [String: TerminalActivityState]
        let observedAt: Date
    }

    private struct Baseline {
        var worktreeID: UUID
        var offset: UInt64
        var pendingFragment: Data
        var discardingCurrentLine: Bool
        var reducer: CodexTurnLifecycleReducer
    }

    private struct SessionGeneration {
        enum Attachment {
            case initial
            case boundary
        }

        let worktreeID: UUID
        let transcriptPath: String
        let observedAt: Date
        let attachment: Attachment
        let boundaryEstablished: Bool
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

    // A 64 KiB read is the fairness and I/O quantum: each active transcript
    // gets one bounded step before another path can consume the shared budget.
    private static let readChunkSize = 64 * 1024
    // terminal.list is a two-second polling hot path. One MiB bounds all
    // transcript work per request while still covering ordinary rollout tails.
    static let initialTailByteLimit: UInt64 = 1024 * 1024
    static let incrementalReadByteLimit = initialTailByteLimit
    static let requestReadByteLimit = incrementalReadByteLimit
    // Sixteen 64 KiB steps cap zero-byte metadata work as well as byte reads,
    // so missing or truncated files cannot expand one request without bound.
    static let requestStepLimit = Int(requestReadByteLimit) / readChunkSize
    // Observed lifecycle records are tens of KiB or less; one MiB leaves broad
    // margin while preventing a malformed unterminated record from growing.
    static let maxBufferedRecordByteCount = Int(initialTailByteLimit)
    private var baselines: [String: Baseline] = [:]
    private var sessionGenerations: [UUID: SessionGeneration] = [:]
    private var nextBatchPathOrder: [String] = []
    private var batchPathWorktreeIDs: [String: UUID] = [:]

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

        let targetsByPath = Dictionary(
            uniqueKeysWithValues: uniqueTargets.map { ($0.transcriptPath, $0) })
        var knownPaths = Set(nextBatchPathOrder)
        for target in uniqueTargets {
            batchPathWorktreeIDs[target.transcriptPath] = target.worktreeID
            if knownPaths.insert(target.transcriptPath).inserted {
                nextBatchPathOrder.append(target.transcriptPath)
            }
        }
        let targets = nextBatchPathOrder.compactMap { targetsByPath[$0] }
        var active = Array(repeating: true, count: targets.count)
        var activeCount = targets.count
        var cursor = 0
        var remainingByteCount = totalByteLimit
        var remainingStepCount = Self.requestStepLimit
        var states: [String: TerminalActivityState] = [:]

        while remainingByteCount > 0, remainingStepCount > 0, activeCount > 0 {
            if active[cursor] {
                let target = targets[cursor]
                remainingStepCount -= 1
                let result = observeStep(
                    transcriptPath: target.transcriptPath,
                    worktreeID: target.worktreeID,
                    byteLimit: min(UInt64(Self.readChunkSize), remainingByteCount))
                remainingByteCount -= result.bytesRead
                advanceBatchPath(target.transcriptPath)

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

        return states
    }

    /// Couples a batch result to the actor order in which its transcript
    /// observation completed. Minting the timestamp before this actor accepts
    /// another call prevents reversed RPC completions from assigning a newer
    /// timestamp to an older transcript result.
    func observeStamped(
        transcripts: [Target],
        totalByteLimit: UInt64 = requestReadByteLimit,
        now: @Sendable () -> Date
    ) -> StampedObservation {
        StampedObservation(
            states: observe(transcripts: transcripts, totalByteLimit: totalByteLimit),
            observedAt: now()
        )
    }

    /// Attach the first accepted session without fencing lifecycle records the
    /// rollout wrote before its SessionStart hook reached TBD. Reuse the
    /// ordinary bounded observation path so an existing baseline survives and
    /// an absent baseline gets the same tail bootstrap as terminal.list.
    func adoptInitialSession(
        transcriptPath: String,
        worktreeID: UUID,
        terminalID: UUID,
        generation: Date
    ) {
        if let current = sessionGenerations[terminalID] {
            guard current.observedAt <= generation else { return }
            if current.observedAt == generation {
                guard current.attachment == .boundary else {
                    _ = observe(transcriptPath: transcriptPath, worktreeID: worktreeID)
                    return
                }
                // A list raced the handler after persistence and reconstructed
                // this same generation as a restart boundary. Initial-session
                // knowledge is more specific, so discard that EOF baseline and
                // perform the ordinary bounded bootstrap below.
                baselines.removeValue(forKey: current.transcriptPath)
            } else {
                baselines.removeValue(forKey: current.transcriptPath)
            }
        }
        sessionGenerations[terminalID] = SessionGeneration(
            worktreeID: worktreeID,
            transcriptPath: transcriptPath,
            observedAt: generation,
            attachment: .initial,
            boundaryEstablished: false)
        _ = observe(transcriptPath: transcriptPath, worktreeID: worktreeID)
    }

    /// Establish a lifecycle boundary for an accepted SessionStart without
    /// re-reading history before that event. This matters when Codex reuses the
    /// same transcript path after an interrupted turn: an unmatched historical
    /// `task_started` must not become current-session working evidence again.
    /// Bytes appended after the captured EOF are reduced normally, so the next
    /// genuine turn supersedes the boundary. A missing file leaves a pending
    /// boundary that terminal.list retries without replaying history.
    func establishSessionBoundary(
        transcriptPath: String,
        worktreeID: UUID,
        terminalID: UUID,
        generation: Date
    ) {
        applySessionBoundary(
            transcriptPath: transcriptPath,
            worktreeID: worktreeID,
            terminalID: terminalID,
            generation: generation)
    }

    /// Reconstruct the boundary from a persisted SessionStart generation after
    /// daemon restart. An established boundary or live initial attachment wins
    /// at the same generation; an unavailable pending boundary is retried until
    /// it can capture EOF. Later generations always replace older actor state.
    func establishSessionBoundariesIfAbsent(transcripts: [Target]) {
        for transcript in transcripts {
            guard let terminalID = transcript.terminalID,
                  let generation = transcript.sessionGeneration else { continue }
            applySessionBoundary(
                transcriptPath: transcript.transcriptPath,
                worktreeID: transcript.worktreeID,
                terminalID: terminalID,
                generation: generation)
        }
    }

    private func applySessionBoundary(
        transcriptPath: String,
        worktreeID: UUID,
        terminalID: UUID,
        generation: Date
    ) {
        if let current = sessionGenerations[terminalID] {
            guard current.observedAt <= generation else { return }
            if current.observedAt == generation {
                guard current.attachment == .boundary,
                      !current.boundaryEstablished else { return }
            } else {
                baselines.removeValue(forKey: current.transcriptPath)
            }
        }
        let established = captureSessionBoundary(
            transcriptPath: transcriptPath,
            worktreeID: worktreeID)
        sessionGenerations[terminalID] = SessionGeneration(
            worktreeID: worktreeID,
            transcriptPath: transcriptPath,
            observedAt: generation,
            attachment: .boundary,
            boundaryEstablished: established)
    }

    @discardableResult
    private func captureSessionBoundary(
        transcriptPath: String,
        worktreeID: UUID
    ) -> Bool {
        batchPathWorktreeIDs[transcriptPath] = worktreeID
        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: transcriptPath))
            defer { try? handle.close() }
            let fileSize = try handle.seekToEnd()
            var discardingCurrentLine = false
            if fileSize > 0 {
                try handle.seek(toOffset: fileSize - 1)
                let lastByte = try handle.read(upToCount: 1)?.first
                discardingCurrentLine = lastByte != 0x0A
            }
            baselines[transcriptPath] = Baseline(
                worktreeID: worktreeID,
                offset: fileSize,
                pendingFragment: Data(),
                discardingCurrentLine: discardingCurrentLine,
                reducer: CodexTurnLifecycleReducer())
            return true
        } catch {
            // Never retain positive evidence across a session boundary when
            // the file is temporarily unavailable. A later list observation
            // retries the boundary when the new session creates the path.
            baselines.removeValue(forKey: transcriptPath)
            return false
        }
    }

    private func advanceBatchPath(_ transcriptPath: String) {
        guard let index = nextBatchPathOrder.firstIndex(of: transcriptPath) else { return }
        nextBatchPathOrder.remove(at: index)
        nextBatchPathOrder.append(transcriptPath)
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
    /// limits pruning to baselines and session generations last observed in
    /// that worktree.
    func retain(transcriptPaths: Set<String>, scope worktreeID: UUID?) {
        guard let worktreeID else {
            baselines = baselines.filter { transcriptPaths.contains($0.key) }
            sessionGenerations = sessionGenerations.filter {
                transcriptPaths.contains($0.value.transcriptPath)
            }
            nextBatchPathOrder.removeAll { !transcriptPaths.contains($0) }
            batchPathWorktreeIDs = batchPathWorktreeIDs.filter {
                transcriptPaths.contains($0.key)
            }
            return
        }
        baselines = baselines.filter {
            $0.value.worktreeID != worktreeID || transcriptPaths.contains($0.key)
        }
        sessionGenerations = sessionGenerations.filter {
            $0.value.worktreeID != worktreeID
                || transcriptPaths.contains($0.value.transcriptPath)
        }
        let removedPaths = Set(batchPathWorktreeIDs.compactMap { path, owner in
            owner == worktreeID && !transcriptPaths.contains(path) ? path : nil
        })
        nextBatchPathOrder.removeAll { removedPaths.contains($0) }
        batchPathWorktreeIDs = batchPathWorktreeIDs.filter {
            !removedPaths.contains($0.key)
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
