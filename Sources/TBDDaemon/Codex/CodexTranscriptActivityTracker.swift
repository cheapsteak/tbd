import Foundation
import TBDShared

struct CodexTurnLifecycleEvent: Sendable {
    enum Kind: Sendable {
        case started
        case closed
    }

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

    let kind: Kind
    let turnID: String?
    let startedAt: Double?

    static func decode(line: Data) -> Self? {
        guard let envelope = try? JSONDecoder().decode(EventEnvelope.self, from: line),
              envelope.type == "event_msg" else { return nil }

        let kind: Kind
        switch envelope.payload.type {
        case "task_started":
            kind = .started
        case "task_complete", "turn_aborted":
            kind = .closed
        default:
            return nil
        }
        return Self(
            kind: kind,
            turnID: envelope.payload.turnID,
            startedAt: envelope.payload.startedAt)
    }
}

struct CodexTurnLifecycleReducer: Sendable {
    enum RecoverySeed: Sendable {
        case noEvidence
        case idle
    }

    private struct Turn: Sendable {
        let id: String
        let startedAt: Double?
    }

    private var currentTurn: Turn?
    private var hasLifecycleEvidence = false

    init() {}

    init(recoverySeed: RecoverySeed) {
        switch recoverySeed {
        case .noEvidence:
            break
        case .idle:
            hasLifecycleEvidence = true
        }
    }

    var activityState: TerminalActivityState? {
        guard hasLifecycleEvidence else { return nil }
        return currentTurn == nil ? .idle : .working
    }

    mutating func consume(line: Data) {
        guard let event = CodexTurnLifecycleEvent.decode(line: line) else { return }
        consume(event: event)
    }

    mutating func consume(event: CodexTurnLifecycleEvent) {
        switch event.kind {
        case .started:
            guard let turnID = event.turnID else { return }
            hasLifecycleEvidence = true
            currentTurn = Turn(id: turnID, startedAt: event.startedAt)
        case .closed:
            hasLifecycleEvidence = true
            // Some rollout writers omit or rewrite the close ID. With no
            // trustworthy identity key, prefer false idle to a permanent
            // false-working indicator. When both records carry identity, a
            // present timestamp still protects a newer turn from a late close.
            if let currentTurn,
               event.turnID == nil
                || currentTurn.id == event.turnID
                || currentTurn.startedAt != nil
                && currentTurn.startedAt == event.startedAt
                || event.startedAt == nil {
                self.currentTurn = nil
            }
        }
    }
}

private struct CodexReverseLifecycleSearch: Sendable {
    enum Outcome: Sendable {
        case idle
        case replayFrom(UInt64)
    }

    private var sawClose = false

    mutating func consume(
        event: CodexTurnLifecycleEvent,
        recordStartOffset: UInt64
    ) -> Outcome? {
        switch event.kind {
        case .closed:
            sawClose = true
            guard event.turnID != nil,
                  event.startedAt != nil else { return .idle }
            return nil
        case .started:
            guard event.turnID != nil else { return nil }
            return .replayFrom(recordStartOffset)
        }
    }

    var boundarySeed: CodexTurnLifecycleReducer.RecoverySeed {
        sawClose ? .idle : .noEvidence
    }
}

/// Reconstructs a Codex session's turn activity from its append-only JSONL
/// transcript. A persisted session boundary is recovered by scanning backward
/// from a fixed EOF to the newest valid start or an unconditional close. A
/// start anchors a bounded forward replay through that same EOF so reliable
/// closes are correlated exactly. An observation advances by a bounded amount
/// and reports no state until both phases finish. Targets without a known
/// durable boundary fence at current EOF rather than inferring state from an
/// arbitrary historical window.
/// SessionStart operations are ordered by their persisted observation generation
/// so a delayed actor hop cannot reverse initial-attachment and boundary policy.
actor CodexTranscriptActivityTracker {
    enum ColdRecoveryPhase: Equatable, Sendable {
        case reverseSearch
        case forwardReplay
    }

    struct Target: Sendable {
        let transcriptPath: String
        let worktreeID: UUID
        let terminalID: UUID?
        let sessionGeneration: Date?
        let transcriptBoundaryOffset: Int64?

        init(
            transcriptPath: String,
            worktreeID: UUID,
            terminalID: UUID? = nil,
            sessionGeneration: Date? = nil,
            transcriptBoundaryOffset: Int64? = nil
        ) {
            self.transcriptPath = transcriptPath
            self.worktreeID = worktreeID
            self.terminalID = terminalID
            self.sessionGeneration = sessionGeneration
            self.transcriptBoundaryOffset = transcriptBoundaryOffset
        }
    }

    struct StampedObservation: Sendable {
        let states: [String: TerminalActivityState]
        let observedAt: Date
    }

    private struct Baseline {
        enum Policy {
            case knownBoundary(UInt64)
            case unknownBoundary
        }

        var worktreeID: UUID
        var offset: UInt64
        var pendingFragment: Data
        var discardingCurrentLine: Bool
        var reducer: CodexTurnLifecycleReducer
        var policy: Policy
        var recovery: Recovery?
    }

    private enum Recovery {
        case reverse(ReverseRecovery)
        case forward(targetEOF: UInt64)

        var targetEOF: UInt64 {
            switch self {
            case let .reverse(recovery): recovery.targetEOF
            case let .forward(targetEOF): targetEOF
            }
        }
    }

    private struct ReverseRecovery {
        let boundary: UInt64
        var cursor: UInt64
        var targetEOF: UInt64
        var awaitingCapturedLineNewline: Bool
        var recordSuffix: Data
        var hasTerminatingNewline: Bool
        var discardingRecord: Bool
        let boundaryStartsRecord: Bool
        var search: CodexReverseLifecycleSearch
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
        let boundaryOffset: Int64?
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
    // transcript work per request without imposing a historical horizon.
    static let transcriptReadByteLimit: UInt64 = 1024 * 1024
    static let incrementalReadByteLimit = transcriptReadByteLimit
    static let requestReadByteLimit = incrementalReadByteLimit
    // Sixteen 64 KiB steps cap zero-byte metadata work as well as byte reads,
    // so missing or truncated files cannot expand one request without bound.
    static let requestStepLimit = Int(requestReadByteLimit) / readChunkSize
    // Observed lifecycle records are tens of KiB or less; one MiB leaves broad
    // margin while preventing a malformed unterminated record from growing.
    static let maxBufferedRecordByteCount = Int(transcriptReadByteLimit)
    private var baselines: [String: Baseline] = [:]
    private var sessionGenerations: [UUID: SessionGeneration] = [:]
    private var nextBatchPathOrder: [String] = []
    private var batchPathWorktreeIDs: [String: UUID] = [:]

    var baselineCount: Int { baselines.count }

    /// A cold, generationless observation fences at current EOF and returns nil;
    /// later calls reduce only bytes appended after that fence. Also returns nil
    /// when the transcript cannot be read for this observation.
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

        establishSessionBoundariesIfAbsent(transcripts: transcripts)

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
                if hasPendingBoundary(for: target) {
                    let established = capturePendingBoundary(for: target)
                    advanceBatchPath(target.transcriptPath)
                    if !established {
                        active[cursor] = false
                        activeCount -= 1
                    }
                    cursor = (cursor + 1) % targets.count
                    continue
                }
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

    private func hasPendingBoundary(for target: Target) -> Bool {
        guard let terminalID = target.terminalID,
              let generation = target.sessionGeneration,
              let current = sessionGenerations[terminalID] else { return false }
        return current.observedAt == generation
            && current.transcriptPath == target.transcriptPath
            && current.boundaryOffset == target.transcriptBoundaryOffset
            && !current.boundaryEstablished
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
        return StampedObservation(
            states: observe(transcripts: transcripts, totalByteLimit: totalByteLimit),
            observedAt: now()
        )
    }

    /// Attach the first accepted session without fencing lifecycle records the
    /// rollout wrote before its SessionStart hook reached TBD. Reuse the
    /// durable boundary path so recovery can continue across bounded polls.
    func adoptInitialSession(
        transcriptPath: String,
        worktreeID: UUID,
        terminalID: UUID,
        generation: Date,
        boundaryOffset: Int64 = 0
    ) {
        guard boundaryOffset == 0 else { return }
        if let current = sessionGenerations[terminalID] {
            guard current.observedAt <= generation else { return }
            if current.observedAt == generation {
                guard current.attachment == .boundary else {
                    return
                }
                if current.boundaryOffset == 0 {
                    sessionGenerations[terminalID] = SessionGeneration(
                        worktreeID: worktreeID,
                        transcriptPath: transcriptPath,
                        observedAt: generation,
                        attachment: .initial,
                        boundaryEstablished: current.boundaryEstablished,
                        boundaryOffset: 0)
                    return
                }
                baselines.removeValue(forKey: current.transcriptPath)
            } else {
                baselines.removeValue(forKey: current.transcriptPath)
            }
        }
        let established = captureSessionBoundary(
            transcriptPath: transcriptPath,
            worktreeID: worktreeID,
            boundaryOffset: 0)
        sessionGenerations[terminalID] = SessionGeneration(
            worktreeID: worktreeID,
            transcriptPath: transcriptPath,
            observedAt: generation,
            attachment: .initial,
            boundaryEstablished: established,
            boundaryOffset: 0)
    }

    /// Attach the exact durable offset returned by the SessionStart writer.
    /// A persisted nil remains unknown and cold-fences current EOF until a
    /// later accepted generation supplies an exact offset.
    func establishSessionBoundary(
        transcriptPath: String,
        worktreeID: UUID,
        terminalID: UUID,
        generation: Date,
        boundaryOffset: Int64?
    ) {
        applySessionBoundary(
            transcriptPath: transcriptPath,
            worktreeID: worktreeID,
            terminalID: terminalID,
            generation: generation,
            boundaryOffset: boundaryOffset)
    }

    /// Reconstruct the exact persisted SessionStart target after daemon restart.
    /// An unavailable boundary is retried until its path can be fenced. Later
    /// generations always replace older actor state.
    func establishSessionBoundariesIfAbsent(transcripts: [Target]) {
        for transcript in transcripts {
            guard let terminalID = transcript.terminalID,
                  let generation = transcript.sessionGeneration else { continue }
            applySessionBoundary(
                transcriptPath: transcript.transcriptPath,
                worktreeID: transcript.worktreeID,
                terminalID: terminalID,
                generation: generation,
                boundaryOffset: transcript.transcriptBoundaryOffset,
                captureImmediately: false)
        }
    }

    private func applySessionBoundary(
        transcriptPath: String,
        worktreeID: UUID,
        terminalID: UUID,
        generation: Date,
        boundaryOffset: Int64?,
        captureImmediately: Bool = true
    ) {
        if let current = sessionGenerations[terminalID] {
            guard current.observedAt <= generation else { return }
            if current.observedAt == generation {
                if current.boundaryOffset == boundaryOffset {
                    if current.boundaryEstablished || !captureImmediately {
                        return
                    }
                }
                // A terminal-list reconstruction is provisional. The
                // SessionStart writer's exact offset is authoritative even if
                // the provisional nil-boundary fence reached current EOF.
                baselines.removeValue(forKey: current.transcriptPath)
            } else {
                baselines.removeValue(forKey: current.transcriptPath)
            }
        }
        guard captureImmediately else {
            baselines.removeValue(forKey: transcriptPath)
            sessionGenerations[terminalID] = SessionGeneration(
                worktreeID: worktreeID,
                transcriptPath: transcriptPath,
                observedAt: generation,
                attachment: .boundary,
                boundaryEstablished: false,
                boundaryOffset: boundaryOffset)
            return
        }
        let established = captureSessionBoundary(
            transcriptPath: transcriptPath,
            worktreeID: worktreeID,
            boundaryOffset: boundaryOffset)
        sessionGenerations[terminalID] = SessionGeneration(
            worktreeID: worktreeID,
            transcriptPath: transcriptPath,
            observedAt: generation,
            attachment: .boundary,
            boundaryEstablished: established,
            boundaryOffset: boundaryOffset)
    }

    private func capturePendingBoundary(for target: Target) -> Bool {
        guard let terminalID = target.terminalID,
              let generation = target.sessionGeneration,
              let current = sessionGenerations[terminalID],
              current.observedAt == generation,
              current.transcriptPath == target.transcriptPath,
              current.boundaryOffset == target.transcriptBoundaryOffset,
              !current.boundaryEstablished else { return true }
        let established = captureSessionBoundary(
            transcriptPath: target.transcriptPath,
            worktreeID: target.worktreeID,
            boundaryOffset: current.boundaryOffset)
        sessionGenerations[terminalID] = SessionGeneration(
            worktreeID: target.worktreeID,
            transcriptPath: target.transcriptPath,
            observedAt: generation,
            attachment: current.attachment,
            boundaryEstablished: established,
            boundaryOffset: current.boundaryOffset)
        return established
    }

    @discardableResult
    private func captureSessionBoundary(
        transcriptPath: String,
        worktreeID: UUID,
        boundaryOffset: Int64?
    ) -> Bool {
        batchPathWorktreeIDs[transcriptPath] = worktreeID
        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: transcriptPath))
            defer { try? handle.close() }
            let fileSize = try handle.seekToEnd()
            switch boundaryOffset {
            case nil:
                baselines[transcriptPath] = try makeFenceBaseline(
                    handle: handle,
                    offset: fileSize,
                    worktreeID: worktreeID,
                    policy: .unknownBoundary)
            case let boundaryOffset?:
                guard boundaryOffset >= 0 else {
                    baselines[transcriptPath] = try makeFenceBaseline(
                        handle: handle,
                        offset: fileSize,
                        worktreeID: worktreeID,
                        policy: .unknownBoundary)
                    return true
                }
                let boundary = UInt64(boundaryOffset)
                if boundary <= fileSize {
                    baselines[transcriptPath] = try makeRecoveryBaseline(
                        handle: handle,
                        boundary: boundary,
                        recoveryTargetEOF: fileSize,
                        worktreeID: worktreeID)
                } else {
                    baselines[transcriptPath] = try makeFenceBaseline(
                        handle: handle,
                        offset: fileSize,
                        worktreeID: worktreeID,
                        policy: .knownBoundary(boundary))
                }
            }
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
            if let previous,
               fileSize >= previous.offset,
               previous.recovery.map({ fileSize >= $0.targetEOF }) ?? true {
                baseline = previous
                baseline.worktreeID = worktreeID
            } else if let previous {
                baseline = try resetBaselineAfterShrink(
                    previous, handle: handle, fileSize: fileSize, worktreeID: worktreeID)
            } else {
                baseline = try makeFenceBaseline(
                    handle: handle,
                    offset: fileSize,
                    worktreeID: worktreeID,
                    policy: .unknownBoundary)
            }

            let wasRecovering = baseline.recovery != nil
            while let recovery = baseline.recovery, bytesRead < byteLimit {
                let bytesReadBeforePhase = bytesRead
                switch recovery {
                case .reverse:
                    try readReverseRecoveryBytes(
                        handle: handle,
                        fileSize: fileSize,
                        byteLimit: byteLimit - bytesRead,
                        baseline: &baseline,
                        bytesRead: &bytesRead)
                case .forward:
                    try readForwardRecoveryBytes(
                        handle: handle,
                        byteLimit: byteLimit - bytesRead,
                        baseline: &baseline,
                        bytesRead: &bytesRead)
                }

                if bytesRead == bytesReadBeforePhase,
                   baseline.recovery != nil {
                    break
                }
            }

            if baseline.recovery != nil {
                baselines[transcriptPath] = baseline
                return StepResult(state: nil, bytesRead: bytesRead, status: .behind)
            }

            if wasRecovering {
                baselines[transcriptPath] = baseline
                return StepResult(
                    state: baseline.reducer.activityState,
                    bytesRead: bytesRead,
                    status: .caughtUp)
            }

            let unreadByteCount = fileSize - baseline.offset
            let readByteCount = min(unreadByteCount, byteLimit - bytesRead)
            try readBytes(
                handle: handle,
                count: readByteCount,
                baseline: &baseline,
                bytesRead: &bytesRead)

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

    func coldRecoveryPhase(transcriptPath: String) -> ColdRecoveryPhase? {
        guard let recovery = baselines[transcriptPath]?.recovery else { return nil }
        switch recovery {
        case .reverse: return .reverseSearch
        case .forward: return .forwardReplay
        }
    }

    private func makeRecoveryBaseline(
        handle: FileHandle,
        boundary: UInt64,
        recoveryTargetEOF: UInt64,
        worktreeID: UUID
    ) throws -> Baseline {
        var baseline = try makeFenceBaseline(
            handle: handle,
            offset: boundary,
            worktreeID: worktreeID,
            policy: .knownBoundary(boundary))
        let targetNeedsNewline: Bool
        if recoveryTargetEOF == 0 {
            targetNeedsNewline = false
        } else {
            try handle.seek(toOffset: recoveryTargetEOF - 1)
            guard let byte = try handle.read(upToCount: 1)?.first else {
                throw CocoaError(.fileReadUnknown)
            }
            targetNeedsNewline = byte != 0x0A
        }
        if boundary != recoveryTargetEOF || targetNeedsNewline {
            let boundaryStartsRecord: Bool
            if boundary == 0 {
                boundaryStartsRecord = true
            } else {
                try handle.seek(toOffset: boundary - 1)
                guard let byte = try handle.read(upToCount: 1)?.first else {
                    throw CocoaError(.fileReadUnknown)
                }
                boundaryStartsRecord = byte == 0x0A
            }
            baseline.offset = recoveryTargetEOF
            baseline.pendingFragment.removeAll(keepingCapacity: false)
            baseline.recovery = .reverse(ReverseRecovery(
                boundary: boundary,
                cursor: recoveryTargetEOF,
                targetEOF: recoveryTargetEOF,
                awaitingCapturedLineNewline: targetNeedsNewline,
                recordSuffix: Data(),
                hasTerminatingNewline: false,
                discardingRecord: false,
                boundaryStartsRecord: boundaryStartsRecord,
                search: CodexReverseLifecycleSearch()))
            baseline.discardingCurrentLine = false
        }
        return baseline
    }

    private func makeFenceBaseline(
        handle: FileHandle,
        offset: UInt64,
        worktreeID: UUID,
        policy: Baseline.Policy
    ) throws -> Baseline {
        var discardingCurrentLine = false
        if offset > 0 {
            try handle.seek(toOffset: offset - 1)
            guard let lastByte = try handle.read(upToCount: 1)?.first else {
                throw CocoaError(.fileReadUnknown)
            }
            discardingCurrentLine = lastByte != 0x0A
        }
        return Baseline(
            worktreeID: worktreeID,
            offset: offset,
            pendingFragment: Data(),
            discardingCurrentLine: discardingCurrentLine,
            reducer: CodexTurnLifecycleReducer(),
            policy: policy,
            recovery: nil)
    }

    private func resetBaselineAfterShrink(
        _ previous: Baseline,
        handle: FileHandle,
        fileSize: UInt64,
        worktreeID: UUID
    ) throws -> Baseline {
        switch previous.policy {
        case .knownBoundary(0):
            return try makeRecoveryBaseline(
                handle: handle,
                boundary: 0,
                recoveryTargetEOF: fileSize,
                worktreeID: worktreeID)
        case let .knownBoundary(boundary):
            guard fileSize >= boundary else {
                return try makeFenceBaseline(
                    handle: handle,
                    offset: fileSize,
                    worktreeID: worktreeID,
                    policy: .knownBoundary(boundary))
            }
            return try makeRecoveryBaseline(
                handle: handle,
                boundary: boundary,
                recoveryTargetEOF: fileSize,
                worktreeID: worktreeID)
        case .unknownBoundary:
            return try makeFenceBaseline(
                handle: handle,
                offset: fileSize,
                worktreeID: worktreeID,
                policy: .unknownBoundary)
        }
    }

    private func readReverseRecoveryBytes(
        handle: FileHandle,
        fileSize: UInt64,
        byteLimit: UInt64,
        baseline: inout Baseline,
        bytesRead: inout UInt64
    ) throws {
        var remainingBudget = byteLimit
        guard case var .reverse(recovery) = baseline.recovery else { return }

        if recovery.awaitingCapturedLineNewline, remainingBudget > 0 {
            try handle.seek(toOffset: baseline.offset)
            let available = min(fileSize - baseline.offset, remainingBudget)
            let count = Int(min(UInt64(Self.readChunkSize), available))
            guard count > 0 else {
                baseline.recovery = .reverse(recovery)
                return
            }
            guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else {
                throw CocoaError(.fileReadUnknown)
            }
            let consumedCount: Int
            if let newline = chunk.firstIndex(of: 0x0A) {
                consumedCount = chunk.distance(from: chunk.startIndex, to: newline) + 1
                recovery.awaitingCapturedLineNewline = false
            } else {
                consumedCount = chunk.count
            }
            baseline.offset += UInt64(consumedCount)
            recovery.targetEOF = baseline.offset
            recovery.cursor = baseline.offset
            bytesRead += UInt64(chunk.count)
            remainingBudget -= UInt64(chunk.count)
        }

        guard !recovery.awaitingCapturedLineNewline else {
            baseline.recovery = .reverse(recovery)
            return
        }

        while recovery.cursor > recovery.boundary, remainingBudget > 0 {
            let count = min(
                recovery.cursor - recovery.boundary,
                min(UInt64(Self.readChunkSize), remainingBudget))
            let start = recovery.cursor - count
            try handle.seek(toOffset: start)
            guard let chunk = try handle.read(upToCount: Int(count)),
                  chunk.count == Int(count) else {
                throw CocoaError(.fileReadUnknown)
            }
            recovery.cursor = start
            bytesRead += count
            remainingBudget -= count

            if let outcome = consumeBackward(
                chunk: chunk, chunkStartOffset: start, recovery: &recovery
            ) {
                applyReverseSearchOutcome(
                    outcome, recovery: recovery, baseline: &baseline)
                return
            }
        }

        if recovery.cursor == recovery.boundary {
            if recovery.boundaryStartsRecord,
               let outcome = finishBoundaryRecord(recovery: &recovery) {
                applyReverseSearchOutcome(
                    outcome, recovery: recovery, baseline: &baseline)
                return
            }
            finishReverseRecovery(
                seed: recovery.search.boundarySeed,
                recovery: recovery,
                baseline: &baseline)
            return
        }

        baseline.recovery = .reverse(recovery)
    }

    private func consumeBackward(
        chunk: Data,
        chunkStartOffset: UInt64,
        recovery: inout ReverseRecovery
    ) -> CodexReverseLifecycleSearch.Outcome? {
        var scanEnd = chunk.endIndex

        while scanEnd > chunk.startIndex,
              let newline = chunk[chunk.startIndex..<scanEnd].lastIndex(of: 0x0A) {
            let segmentStart = chunk.index(after: newline)
            if recovery.hasTerminatingNewline {
                prependBackwardSegment(
                    chunk[segmentStart..<scanEnd], recovery: &recovery)
                let recordStartOffset = chunkStartOffset
                    + UInt64(chunk.distance(from: chunk.startIndex, to: segmentStart))
                if let outcome = finishBackwardRecord(
                    recordStartOffset: recordStartOffset,
                    recovery: &recovery
                ) {
                    return outcome
                }
            } else {
                recovery.hasTerminatingNewline = true
            }
            scanEnd = newline
        }

        if scanEnd > chunk.startIndex, recovery.hasTerminatingNewline {
            prependBackwardSegment(chunk[chunk.startIndex..<scanEnd], recovery: &recovery)
        }
        return nil
    }

    private func prependBackwardSegment(
        _ segment: Data.SubSequence,
        recovery: inout ReverseRecovery
    ) {
        guard !recovery.discardingRecord else { return }
        guard segment.count
                <= Self.maxBufferedRecordByteCount - recovery.recordSuffix.count else {
            recovery.recordSuffix.removeAll(keepingCapacity: false)
            recovery.discardingRecord = true
            return
        }
        guard !segment.isEmpty else { return }
        var record = Data(capacity: segment.count + recovery.recordSuffix.count)
        record.append(contentsOf: segment)
        record.append(recovery.recordSuffix)
        recovery.recordSuffix = record
    }

    private func finishBackwardRecord(
        recordStartOffset: UInt64,
        recovery: inout ReverseRecovery
    ) -> CodexReverseLifecycleSearch.Outcome? {
        defer {
            recovery.recordSuffix.removeAll(keepingCapacity: false)
            recovery.discardingRecord = false
        }
        guard !recovery.discardingRecord,
              let event = CodexTurnLifecycleEvent.decode(line: recovery.recordSuffix) else {
            return nil
        }
        return recovery.search.consume(
            event: event,
            recordStartOffset: recordStartOffset)
    }

    private func finishBoundaryRecord(
        recovery: inout ReverseRecovery
    ) -> CodexReverseLifecycleSearch.Outcome? {
        guard recovery.hasTerminatingNewline else { return nil }
        return finishBackwardRecord(
            recordStartOffset: recovery.boundary,
            recovery: &recovery)
    }

    private func applyReverseSearchOutcome(
        _ outcome: CodexReverseLifecycleSearch.Outcome,
        recovery: ReverseRecovery,
        baseline: inout Baseline
    ) {
        switch outcome {
        case .idle:
            finishReverseRecovery(seed: .idle, recovery: recovery, baseline: &baseline)
        case let .replayFrom(offset):
            baseline.offset = offset
            baseline.pendingFragment.removeAll(keepingCapacity: false)
            baseline.discardingCurrentLine = false
            baseline.reducer = CodexTurnLifecycleReducer()
            baseline.recovery = .forward(targetEOF: recovery.targetEOF)
        }
    }

    private func finishReverseRecovery(
        seed: CodexTurnLifecycleReducer.RecoverySeed,
        recovery: ReverseRecovery,
        baseline: inout Baseline
    ) {
        baseline.offset = recovery.targetEOF
        baseline.pendingFragment.removeAll(keepingCapacity: false)
        baseline.discardingCurrentLine = false
        baseline.reducer = CodexTurnLifecycleReducer(recoverySeed: seed)
        baseline.recovery = nil
    }

    private func readForwardRecoveryBytes(
        handle: FileHandle,
        byteLimit: UInt64,
        baseline: inout Baseline,
        bytesRead: inout UInt64
    ) throws {
        guard case let .forward(targetEOF) = baseline.recovery else { return }
        let count = min(targetEOF - baseline.offset, byteLimit)
        try readBytes(
            handle: handle,
            count: count,
            baseline: &baseline,
            bytesRead: &bytesRead)
        guard baseline.offset == targetEOF,
              baseline.pendingFragment.isEmpty,
              !baseline.discardingCurrentLine else { return }
        baseline.recovery = nil
    }

    private func readBytes(
        handle: FileHandle,
        count: UInt64,
        baseline: inout Baseline,
        bytesRead: inout UInt64
    ) throws {
        let observationEndOffset = baseline.offset + count
        try handle.seek(toOffset: baseline.offset)
        while baseline.offset < observationEndOffset {
            let remaining = observationEndOffset - baseline.offset
            let readCount = Int(min(UInt64(Self.readChunkSize), remaining))
            guard let chunk = try handle.read(upToCount: readCount), !chunk.isEmpty else {
                throw CocoaError(.fileReadUnknown)
            }
            baseline.offset += UInt64(chunk.count)
            bytesRead += UInt64(chunk.count)
            consumeCompleteLines(from: chunk, into: &baseline)
        }
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
