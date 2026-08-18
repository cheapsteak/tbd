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
/// transcript. Each path is scanned from byte zero once, then only from the
/// last successfully-read offset on later observations.
actor CodexTranscriptActivityTracker {
    private struct Baseline {
        var worktreeID: UUID
        var offset: UInt64
        var pendingFragment: Data
        var reducer: CodexTurnLifecycleReducer
    }

    private static let readChunkSize = 64 * 1024
    private var baselines: [String: Baseline] = [:]

    var baselineCount: Int { baselines.count }

    /// Returns nil when the transcript cannot be read for this observation.
    /// In particular, a cached positive state is never served as evidence that
    /// an inaccessible transcript is still active.
    func observe(transcriptPath: String, worktreeID: UUID) -> TerminalActivityState? {
        let previous = baselines[transcriptPath]
        var baseline = previous ?? Baseline(
            worktreeID: worktreeID,
            offset: 0,
            pendingFragment: Data(),
            reducer: CodexTurnLifecycleReducer())

        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: transcriptPath))
            defer { try? handle.close() }

            let fileSize = try handle.seekToEnd()
            if fileSize < baseline.offset {
                baseline = Baseline(
                    worktreeID: worktreeID,
                    offset: 0,
                    pendingFragment: Data(),
                    reducer: CodexTurnLifecycleReducer())
            } else {
                baseline.worktreeID = worktreeID
            }

            try handle.seek(toOffset: baseline.offset)
            while let chunk = try handle.read(upToCount: Self.readChunkSize), !chunk.isEmpty {
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

    private func consumeCompleteLines(from chunk: Data, into baseline: inout Baseline) {
        baseline.pendingFragment.append(chunk)
        var lineStart = baseline.pendingFragment.startIndex

        while let newline = baseline.pendingFragment[lineStart...].firstIndex(of: 0x0A) {
            baseline.reducer.consume(line: Data(baseline.pendingFragment[lineStart..<newline]))
            lineStart = baseline.pendingFragment.index(after: newline)
        }

        if lineStart != baseline.pendingFragment.startIndex {
            baseline.pendingFragment = Data(baseline.pendingFragment[lineStart...])
        }
    }
}
