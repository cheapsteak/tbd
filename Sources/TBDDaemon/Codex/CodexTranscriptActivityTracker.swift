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

        enum CodingKeys: String, CodingKey {
            case type
            case turnID = "turn_id"
        }
    }

    private var currentTurnID: String?
    private var hasLifecycleEvidence = false

    var activityState: TerminalActivityState? {
        guard hasLifecycleEvidence else { return nil }
        return currentTurnID == nil ? .idle : .working
    }

    mutating func consume(line: Data) {
        guard let envelope = try? JSONDecoder().decode(EventEnvelope.self, from: line),
              envelope.type == "event_msg",
              let turnID = envelope.payload.turnID else { return }

        switch envelope.payload.type {
        case "task_started":
            hasLifecycleEvidence = true
            currentTurnID = turnID
        case "task_complete", "turn_aborted":
            hasLifecycleEvidence = true
            if currentTurnID == turnID {
                currentTurnID = nil
            }
        default:
            break
        }
    }
}

/// Reconstructs a Codex session's turn activity from its append-only JSONL
/// transcript. Each path is bootstrapped from a bounded tail once, then only
/// from the last successfully-read offset on later observations.
actor CodexTranscriptActivityTracker {
    private struct Baseline {
        var worktreeID: UUID
        var offset: UInt64
        var pendingFragment: Data
        var discardingCurrentLine: Bool
        var reducer: CodexTurnLifecycleReducer
    }

    private static let readChunkSize = 64 * 1024
    static let initialTailByteLimit: UInt64 = 1024 * 1024
    static let maxBufferedRecordByteCount = Int(initialTailByteLimit)
    private var baselines: [String: Baseline] = [:]

    var baselineCount: Int { baselines.count }

    /// Returns nil when the transcript cannot be read for this observation.
    /// In particular, a cached positive state is never served as evidence that
    /// an inaccessible transcript is still active.
    func observe(transcriptPath: String, worktreeID: UUID) -> TerminalActivityState? {
        let previous = baselines[transcriptPath]

        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: transcriptPath))
            defer { try? handle.close() }

            let fileSize = try handle.seekToEnd()
            var baseline: Baseline
            if let previous, fileSize >= previous.offset {
                baseline = previous
                baseline.worktreeID = worktreeID
            } else {
                baseline = try makeTailBaseline(
                    handle: handle,
                    fileSize: fileSize,
                    worktreeID: worktreeID)
            }

            try handle.seek(toOffset: baseline.offset)
            while baseline.offset < fileSize {
                let remaining = fileSize - baseline.offset
                let count = Int(min(UInt64(Self.readChunkSize), remaining))
                guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { return nil }
                baseline.offset += UInt64(chunk.count)
                consumeCompleteLines(from: chunk, into: &baseline)
            }

            baselines[transcriptPath] = baseline
            return baseline.reducer.activityState
        } catch {
            return nil
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
    ) throws -> Baseline {
        let startOffset = fileSize > Self.initialTailByteLimit
            ? fileSize - Self.initialTailByteLimit
            : 0
        var discardingCurrentLine = false

        if startOffset > 0 {
            try handle.seek(toOffset: startOffset - 1)
            let precedingByte = try handle.read(upToCount: 1)?.first
            discardingCurrentLine = precedingByte != 0x0A
        }

        return Baseline(
            worktreeID: worktreeID,
            offset: startOffset,
            pendingFragment: Data(),
            discardingCurrentLine: discardingCurrentLine,
            reducer: CodexTurnLifecycleReducer())
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
