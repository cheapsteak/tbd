import Foundation
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "claude-delegation")

/// A terminal and the transcript that currently speaks for it.
struct ClaudeDelegationTarget: Sendable, Equatable {
    let terminalID: UUID
    let transcriptPath: String?
}

/// Owns which Claude terminals owe a delegation sample and what the last
/// sample said.
///
/// Sampling is deferred rather than performed when a terminal reports idle,
/// and the reason is an ordering fact: Claude Code runs its `Stop` hooks
/// first and writes the turn's `turn_duration` record about two milliseconds
/// after they return. Reading while the hook is executing observes the
/// PREVIOUS turn — exactly the difference between a count of zero and a count
/// of one in the case this rail exists to catch.
///
/// All state is transient. Nothing here is persisted, and nothing here creates
/// a durable external resource, so no reconciler covers it.
actor ClaudeDelegationTracker {
    /// How much of the transcript's end to read. Measured against a real
    /// corpus, the newest `turn_duration` sits a median of ~1.3 KiB from end
    /// of file and falls inside this window for ~98% of transcripts. The
    /// remainder are transcripts with a long turn in progress, where the hook
    /// rail already reports working and this rail is not needed.
    private static let tailByteLimit = 64 * 1024

    private struct Claim {
        let transcriptPath: String
        let count: Int
    }

    private var marked: Set<UUID> = []
    private var claims: [UUID: Claim] = [:]

    func mark(terminalID: UUID) {
        marked.insert(terminalID)
    }

    func clear(terminalID: UUID) {
        marked.remove(terminalID)
        claims.removeValue(forKey: terminalID)
    }

    /// Re-reads every marked target, keeps standing claims for the rest, and
    /// returns only terminals that currently claim outstanding agents.
    func sample(targets: [ClaudeDelegationTarget]) -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        for target in targets {
            let id = target.terminalID
            // A retargeted terminal's old count cannot describe its new
            // transcript, so drop it whether or not a fresh mark arrived.
            if let claim = claims[id], claim.transcriptPath != target.transcriptPath {
                claims.removeValue(forKey: id)
            }
            if marked.remove(id) != nil {
                claims.removeValue(forKey: id)
                if let path = target.transcriptPath, !path.isEmpty,
                   let tail = Self.readTail(path: path),
                   let count = ClaudeDelegationSample.pendingCount(inTail: tail) {
                    claims[id] = Claim(transcriptPath: path, count: count)
                }
            }
            if let claim = claims[id] { result[id] = claim.count }
        }
        return result
    }

    /// Drops state for terminals that no longer exist.
    func retain(terminalIDs: Set<UUID>) {
        marked.formIntersection(terminalIDs)
        claims = claims.filter { terminalIDs.contains($0.key) }
    }

    /// Reads at most the final `tailByteLimit` bytes. Any failure returns nil,
    /// which makes no claim — inability to look is never evidence of work.
    private static func readTail(path: String) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            let start = end > UInt64(tailByteLimit) ? end - UInt64(tailByteLimit) : 0
            try handle.seek(toOffset: start)
            return try handle.read(upToCount: tailByteLimit)
        } catch {
            logger.debug("delegation tail read failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
