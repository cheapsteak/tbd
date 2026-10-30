import Foundation
import TBDShared

/// The session mod's `transcript-stream.json`: a live view of the main loop's
/// current turn, written by the `transcript-stream` feature from inside Claude
/// Code (`SessionMod/hooks/features/transcript-stream.ts`). It holds the
/// current step and the one before it; each step's text and thinking blocks in
/// the order the model produced them, each with the `uuid` of the transcript
/// row that will hold it once `session.append` named one.
///
/// The file is rewritten whole on every change, so it is never a history: a
/// block that is no longer here has left the stream.
/// Design: docs/specs/2026-10-20-transcript-stream-mod-design.md.
struct TranscriptStreamSnapshot: Decodable, Equatable, Sendable {
    /// The only `schemaVersion` this build reads.
    static let schemaVersion = 1

    struct Turn: Decodable, Equatable, Sendable {
        let id: String
        /// How the turn completed (`answer`, `aborted`, ...), once it has.
        let completion: String?
    }

    struct Step: Decodable, Equatable, Sendable {
        let index: Int
        let ended: Bool
        /// Why the model stopped; nil while the step runs, and on an
        /// interrupted step.
        let stopReason: String?
        let blocks: [Block]
    }

    struct Block: Decodable, Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case text
            case thinking
            /// A kind this build does not show; kept so positions stay put.
            case other(String)
        }

        let kind: Kind
        let text: String
        let ended: Bool
        /// The transcript row that holds this block, once the mod knows it.
        let uuid: String?

        private enum CodingKeys: String, CodingKey { case kind, text, ended, uuid }

        init(kind: Kind, text: String, ended: Bool, uuid: String?) {
            self.kind = kind
            self.text = text
            self.ended = ended
            self.uuid = uuid
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .kind) {
            case "text": kind = .text
            case "thinking": kind = .thinking
            case let other: kind = .other(other)
            }
            text = try container.decode(String.self, forKey: .text)
            ended = try container.decode(Bool.self, forKey: .ended)
            uuid = try container.decodeIfPresent(String.self, forKey: .uuid)
        }
    }

    let schemaVersion: Int
    let sessionId: String
    let updatedAtMs: Int64
    let turn: Turn?
    let steps: [Step]

    init(schemaVersion: Int = TranscriptStreamSnapshot.schemaVersion, sessionId: String,
         updatedAtMs: Int64, turn: Turn?, steps: [Step]) {
        self.schemaVersion = schemaVersion
        self.sessionId = sessionId
        self.updatedAtMs = updatedAtMs
        self.turn = turn
        self.steps = steps
    }

    /// Every `uuid` the snapshot's blocks carry.
    var blockUUIDs: Set<String> {
        Set(steps.flatMap { $0.blocks.compactMap(\.uuid) })
    }
}

/// Reads `transcript-stream.json` whole. Pure apart from the one file read.
///
/// The mod's `$.fs` has no rename, so a write is not atomic and a read can
/// land on a cut-off file. That is the expected cause of a file that does not
/// parse, and it is no news: the caller keeps its last good snapshot, and the
/// next read 100 ms later sees the finished write.
enum StreamFileReader {
    enum Read: Equatable, Sendable {
        /// No file: the session has no stream.
        case missing
        /// A file that does not parse, carries an unknown `schemaVersion`, or
        /// cannot be read right now. Keep what you had.
        case noNews
        case snapshot(TranscriptStreamSnapshot)
    }

    /// Decodes one whole file. Nil for bytes that do not parse or a schema
    /// version this build does not know.
    static func decode(_ data: Data) -> TranscriptStreamSnapshot? {
        guard let snapshot = try? JSONDecoder().decode(TranscriptStreamSnapshot.self, from: data),
              snapshot.schemaVersion == TranscriptStreamSnapshot.schemaVersion else {
            return nil
        }
        return snapshot
    }

    /// Reads and decodes the file at `path`.
    static func read(path: String) -> Read {
        let fd = open(path, O_RDONLY)
        if fd < 0 { return errno == ENOENT ? .missing : .noNews }
        let data: Data
        do {
            data = try FileHandle(fileDescriptor: fd, closeOnDealloc: true).readToEnd() ?? Data()
        } catch {
            return .noNews
        }
        return decode(data).map(Read.snapshot) ?? .noNews
    }

    /// Whether the mod's heartbeat beside the stream file at `streamPath` is
    /// stale at `now` — older than `SessionModSessionFiles.heartbeatStaleAfter`.
    /// False when `alive.json` is missing or unreadable: only a heartbeat that
    /// is there and old says the mod has stopped.
    static func heartbeatIsStale(streamPath: String, now: Date) -> Bool {
        let alive = URL(fileURLWithPath: streamPath)
            .deletingLastPathComponent()
            .appendingPathComponent(SessionModSessionFiles.aliveFileName)
        guard let data = FileManager.default.contents(atPath: alive.path),
              let record = try? JSONDecoder().decode(SessionModSessionFiles.AliveRecord.self, from: data) else {
            return false
        }
        return record.isStale(now: now)
    }
}
