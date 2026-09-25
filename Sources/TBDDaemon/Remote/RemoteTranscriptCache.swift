import Foundation
import os
import TBDShared

private let cacheLogger = Logger(subsystem: "com.tbd.daemon", category: "remote-transcript")

/// `state.json` beside a cached remote transcript: what the daemon has
/// committed of `transcript.jsonl`.
///
/// - `cursor` — the provider's last continuation cursor, passed back verbatim
///   on the next `transcript read --since`. Nil means the next read starts from
///   the beginning.
/// - `length` — how many bytes of `transcript.jsonl` are committed. Bytes past
///   it are an append the daemon did not finish recording, and `load()` cuts
///   them off.
/// - `generation` — incremented whenever the file's content is replaced rather
///   than extended, so a reader holding records from an earlier generation
///   discards them and rereads from the start.
struct RemoteTranscriptCacheState: Codable, Equatable, Sendable {
    var cursor: String?
    var length: Int
    var generation: Int

    static let empty = RemoteTranscriptCacheState(cursor: nil, length: 0, generation: 0)
}

/// One remote session's transcript cache on disk:
/// `~/tbd/remote-transcripts/<provider>/<sessionID>/{transcript.jsonl,state.json}`
/// (`docs/specs/2026-09-25-remote-session-transcript-design.md` § Cache).
///
/// The two files are kept consistent by write order alone, so a crash at any
/// point leaves a pair `load()` can repair:
///
/// - **Append** writes the page to `transcript.jsonl` first, then `state.json`
///   atomically with the new cursor and length. A crash in between leaves
///   uncommitted bytes past `length`, which `load()` truncates — so the next
///   fetch, still holding the old cursor, cannot append the same records twice.
/// - **Reset** first commits an empty state under the next generation, then
///   renames a fully written temporary file over `transcript.jsonl`, then
///   commits the new cursor and length. A crash anywhere in that sequence
///   leaves a state of length 0 with no cursor, which `load()` repairs to an
///   empty file, and the next fetch reads the conversation from the beginning.
///
/// Only the daemon writes here, and only from `RemoteTranscriptSync`'s
/// per-session lane, so there is never a second writer to coordinate with. The
/// app reads `transcript.jsonl` directly and uses `generation` (from the RPC
/// result) to know when to start over.
///
/// Not an actor: every method is synchronous file IO called from inside that
/// lane.
struct RemoteTranscriptCache: Sendable {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    init(provider: String, sessionID: String, environment: [String: String]) {
        self.directory = TBDConstants.remoteTranscriptDir(
            provider: provider, sessionID: sessionID, environment: environment)
    }

    var transcriptURL: URL {
        directory.appendingPathComponent(TBDConstants.remoteTranscriptFileName)
    }

    var stateURL: URL {
        directory.appendingPathComponent(TBDConstants.remoteTranscriptStateFileName)
    }

    /// Prefix of the temporary file a reset writes before renaming it over
    /// `transcript.jsonl`. Dot-prefixed so a directory listing does not show
    /// it beside the real file; swept by `load()` when a crash stranded one.
    private static let resetTempPrefix = ".\(TBDConstants.remoteTranscriptFileName)."

    // MARK: - Load (crash repair)

    /// Reads the committed state and makes `transcript.jsonl` agree with it.
    ///
    /// - The file longer than `length`: an append whose state write never
    ///   landed. The tail is truncated, and `generation` is incremented and
    ///   persisted, because a reader may already have consumed the tail and
    ///   would otherwise render the re-fetched records twice.
    /// - The file shorter than `length` (or missing while `length` is not 0):
    ///   bytes the state vouches for are gone, and no cursor can be trusted to
    ///   continue from them. The cache starts over — empty file, no cursor, the
    ///   next generation — and the next fetch reads from the beginning.
    /// - An unreadable `state.json` with a non-empty file: the same start-over,
    ///   since nothing says how much of the file was committed.
    ///
    /// A pair that already agrees is returned unchanged, with nothing written.
    func load() throws -> RemoteTranscriptCacheState {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        sweepStrandedResetFiles()

        let fileSize = try currentFileSize()
        var state: RemoteTranscriptCacheState
        var stateUnreadable = false
        if let data = try? Data(contentsOf: stateURL) {
            if let decoded = try? JSONDecoder().decode(RemoteTranscriptCacheState.self, from: data),
               decoded.length >= 0, decoded.generation >= 0 {
                state = decoded
            } else {
                cacheLogger.error(
                    "remote transcript cache \(directory.path, privacy: .public): unreadable state.json; starting over")
                state = .empty
                stateUnreadable = true
            }
        } else {
            state = .empty
        }

        if fileSize == state.length, !(stateUnreadable && fileSize > 0) {
            return state
        }

        if fileSize > state.length, !stateUnreadable {
            try truncateTranscript(to: state.length)
            state.generation += 1
            cacheLogger.info(
                """
                remote transcript cache \(directory.path, privacy: .public): truncated \
                \(fileSize - state.length, privacy: .public) uncommitted bytes; \
                generation \(state.generation, privacy: .public)
                """)
            try writeState(state)
            return state
        }

        // Shorter than committed, or no trustworthy state for a non-empty file.
        try truncateTranscript(to: 0)
        state = RemoteTranscriptCacheState(cursor: nil, length: 0, generation: state.generation + 1)
        cacheLogger.error(
            """
            remote transcript cache \(directory.path, privacy: .public): file (\(fileSize, privacy: .public) bytes) \
            disagrees with its state; cleared, generation \(state.generation, privacy: .public)
            """)
        try writeState(state)
        return state
    }

    // MARK: - Append

    /// Appends one page at the committed length, then commits the new cursor
    /// and length. `state` must be what `load()` (or a previous write in the
    /// same sync) returned.
    ///
    /// A page that does not end in a newline gets one, so the next page's first
    /// record never lands on the same line as this page's last. An empty page
    /// writes no bytes but still commits the cursor.
    func append(
        _ page: Data, cursor: String?, to state: RemoteTranscriptCacheState
    ) throws -> RemoteTranscriptCacheState {
        let body = Self.lineTerminated(page)
        if !body.isEmpty {
            if !FileManager.default.fileExists(atPath: transcriptURL.path) {
                try Data().write(to: transcriptURL)
            }
            let handle = try FileHandle(forWritingTo: transcriptURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(state.length))
            try handle.write(contentsOf: body)
            // Anything past the new end is a stale uncommitted tail; cut it now
            // rather than leaving it for the next load to find.
            try handle.truncate(atOffset: UInt64(state.length + body.count))
        }
        let next = RemoteTranscriptCacheState(
            cursor: cursor, length: state.length + body.count, generation: state.generation)
        try writeState(next)
        return next
    }

    // MARK: - Reset

    /// Replaces the conversation with `page` and commits `cursor`, under the
    /// next generation.
    ///
    /// A page byte-identical to what is committed keeps its generation: a
    /// provider with no incremental support answers every call with the whole
    /// conversation, and bumping the generation each time would make the app
    /// discard and re-render an unchanged transcript on every sync.
    func reset(
        to page: Data, cursor: String?, from state: RemoteTranscriptCacheState
    ) throws -> RemoteTranscriptCacheState {
        let body = Self.lineTerminated(page)
        if body.count == state.length, let current = try? Data(contentsOf: transcriptURL), current == body {
            let next = RemoteTranscriptCacheState(
                cursor: cursor, length: state.length, generation: state.generation)
            if next != state { try writeState(next) }
            return next
        }

        let generation = state.generation + 1
        // Commit "empty, from the beginning" first: from here until the final
        // state write, a crash leaves length 0 and no cursor, which `load()`
        // repairs to an empty file rather than a mix of two conversations.
        try writeState(RemoteTranscriptCacheState(cursor: nil, length: 0, generation: generation))

        let temp = directory.appendingPathComponent("\(Self.resetTempPrefix)\(UUID().uuidString).tmp")
        do {
            try body.write(to: temp)
            guard rename(temp.path, transcriptURL.path) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [
                    NSFilePathErrorKey: transcriptURL.path,
                    NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO),
                ])
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }

        let next = RemoteTranscriptCacheState(cursor: cursor, length: body.count, generation: generation)
        try writeState(next)
        return next
    }

    // MARK: - Helpers

    static func lineTerminated(_ page: Data) -> Data {
        guard let last = page.last, last != UInt8(ascii: "\n") else { return page }
        var terminated = page
        terminated.append(UInt8(ascii: "\n"))
        return terminated
    }

    private func currentFileSize() throws -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: transcriptURL.path) else { return 0 }
        let attributes = try fm.attributesOfItem(atPath: transcriptURL.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }

    private func truncateTranscript(to length: Int) throws {
        if !FileManager.default.fileExists(atPath: transcriptURL.path) {
            try Data().write(to: transcriptURL)
            return
        }
        let handle = try FileHandle(forWritingTo: transcriptURL)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(length))
    }

    private func writeState(_ state: RemoteTranscriptCacheState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: stateURL, options: .atomic)
    }

    /// Removes reset temp files a crash stranded between write and rename.
    private func sweepStrandedResetFiles() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix(Self.resetTempPrefix) {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
