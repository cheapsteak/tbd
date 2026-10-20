import Foundation
@testable import TBDApp
import TBDShared
import TestSupport

/// Builders for the session mod's `transcript-stream.json` and its sibling
/// `alive.json`, shared by the stream reader, source, scheduler and publish
/// tests. The JSON is written the way the mod writes it
/// (`SessionMod/hooks/features/transcript-stream.ts`), not by encoding the
/// app's own decoder types, so a test reads what production reads.
enum TranscriptStreamFixtures {

    typealias Block = TranscriptStreamSnapshot.Block
    typealias Step = TranscriptStreamSnapshot.Step

    static func text(_ text: String, ended: Bool = false, uuid: String? = nil) -> Block {
        Block(kind: .text, text: text, ended: ended, uuid: uuid)
    }

    static func thinking(_ text: String, ended: Bool = false, uuid: String? = nil) -> Block {
        Block(kind: .thinking, text: text, ended: ended, uuid: uuid)
    }

    static func step(
        _ index: Int, ended: Bool = false, stopReason: String? = nil, _ blocks: [Block]
    ) -> Step {
        Step(index: index, ended: ended, stopReason: stopReason, blocks: blocks)
    }

    static func snapshot(
        turn: String = "turn-1", completion: String? = nil, _ steps: [Step]
    ) -> TranscriptStreamSnapshot {
        TranscriptStreamSnapshot(
            sessionId: "s1", updatedAtMs: 1_700_000_000_000,
            turn: .init(id: turn, completion: completion), steps: steps)
    }

    /// The file's text, as the mod writes it.
    static func json(_ snapshot: TranscriptStreamSnapshot, schemaVersion: Int = 1) -> String {
        var turn: [String: Any]?
        if let value = snapshot.turn {
            turn = ["id": value.id]
            if let completion = value.completion { turn?["completion"] = completion }
        }
        let steps: [[String: Any]] = snapshot.steps.map { step in
            [
                "index": step.index,
                "ended": step.ended,
                "stopReason": step.stopReason.map { $0 as Any } ?? NSNull(),
                "blocks": step.blocks.map { block -> [String: Any] in
                    var out: [String: Any] = ["text": block.text, "ended": block.ended]
                    switch block.kind {
                    case .text: out["kind"] = "text"
                    case .thinking: out["kind"] = "thinking"
                    case .other(let name): out["kind"] = name
                    }
                    if let uuid = block.uuid { out["uuid"] = uuid }
                    return out
                },
            ]
        }
        let object: [String: Any] = [
            "schemaVersion": schemaVersion,
            "sessionId": snapshot.sessionId,
            "updatedAtMs": snapshot.updatedAtMs,
            "turn": turn.map { $0 as Any } ?? NSNull(),
            "steps": steps,
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(bytes: data, encoding: .utf8)!
    }

    /// A fresh session directory under the fenced scratch root; returns the
    /// stream file's path inside it, not yet written.
    static func streamPath() throws -> String {
        let dir = fencedScratchRoot(prefix: "tbdstream")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/" + SessionModSessionFiles.transcriptStreamFileName
    }

    static func write(_ snapshot: TranscriptStreamSnapshot, to path: String) throws {
        try json(snapshot).write(toFile: path, atomically: false, encoding: .utf8)
    }

    /// Writes `alive.json` beside the stream file at `streamPath`.
    static func writeHeartbeat(beside streamPath: String, at date: Date) throws {
        let record = SessionModSessionFiles.AliveRecord(
            sessionId: "s1", incarnationId: UUID().uuidString,
            features: ["transcript-stream"],
            heartbeatAtMs: Int64((date.timeIntervalSince1970 * 1000).rounded()))
        let url = URL(fileURLWithPath: streamPath).deletingLastPathComponent()
            .appendingPathComponent(SessionModSessionFiles.aliveFileName)
        try JSONEncoder().encode(record).write(to: url)
    }

    /// One JSONL row with `uuid`: an assistant text row, as Claude Code writes
    /// the row that settles a streamed text block.
    static func assistantRow(uuid: String, text: String) -> String {
        let object: [String: Any] = [
            "type": "assistant",
            "uuid": uuid,
            "timestamp": "2026-10-20T10:00:00.000Z",
            "message": [
                "id": "msg_\(uuid)",
                "role": "assistant",
                "content": [["type": "text", "text": text]],
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(bytes: data, encoding: .utf8)!
    }

    /// A transcript file holding `rows`, one per line.
    static func transcript(_ rows: [String]) throws -> String {
        let dir = fencedScratchRoot(prefix: "tbdjsonl")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/transcript.jsonl"
        try rows.map { $0 + "\n" }.joined().write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }
}
