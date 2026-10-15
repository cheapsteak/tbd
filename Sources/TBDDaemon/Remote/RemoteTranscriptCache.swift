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
/// - `before` — the provider's cursor for the history above the file's first
///   record, from a `--tail` reset or the last `--before` page; nil once the
///   cache reaches the conversation's beginning, and always nil for a cache
///   built by forward reads alone.
/// - `head` — a counter bumped on every prepend, so a reader knows records
///   arrived at the top of the file under the same generation.
/// - `hint` — the session's transcript hint recorded at the last caught-up
///   sync, the baseline the next sync compares the current hint with. A reset
///   that changes the file clears it; the sync records it again once caught up.
/// - `pendingPrepend` — set while a prepend is between its first and last
///   write. A load that finds it set resets the cache (see `prepend`).
///
/// A `state.json` written before the last four fields existed decodes with
/// them empty: nil, 0, nil, false.
struct RemoteTranscriptCacheState: Codable, Equatable, Sendable {
    var cursor: String?
    var length: Int
    var generation: Int
    var before: String?
    var head: Int = 0
    var hint: RemoteTranscriptHint?
    var pendingPrepend: Bool = false

    static let empty = RemoteTranscriptCacheState(cursor: nil, length: 0, generation: 0)

    enum CodingKeys: String, CodingKey {
        case cursor, length, generation, before, head, hint, pendingPrepend
    }
}

extension RemoteTranscriptCacheState {
    /// Declared in an extension so the memberwise initializer survives. Every
    /// field added after the first three is `decodeIfPresent`, so an older
    /// daemon's `state.json` still loads without a repair.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            cursor: try c.decodeIfPresent(String.self, forKey: .cursor),
            length: try c.decode(Int.self, forKey: .length),
            generation: try c.decode(Int.self, forKey: .generation),
            before: try c.decodeIfPresent(String.self, forKey: .before),
            head: try c.decodeIfPresent(Int.self, forKey: .head) ?? 0,
            hint: try c.decodeIfPresent(RemoteTranscriptHint.self, forKey: .hint),
            pendingPrepend: try c.decodeIfPresent(Bool.self, forKey: .pendingPrepend) ?? false)
    }
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
/// - **Prepend** puts a page of earlier history at the front of the one file:
///   it commits a `pendingPrepend` marker, renames a temporary file holding the
///   page followed by the current file over `transcript.jsonl`, then commits
///   the new length, `before` and `head` with the marker cleared. A load that
///   finds the marker resets the cache, at the cost of one tail refetch:
///   without it, a crash between the rename and the last write would leave a
///   file longer than `length`, and truncating it would cut the prepended file
///   in the wrong place.
///
/// Only the daemon writes here, and only from `RemoteTranscriptSync`'s
/// per-session lane, so there is never a second writer to coordinate with. The
/// app reads `transcript.jsonl` directly and uses `generation` (from the RPC
/// result) to know when to start over. Before its first sync returns it also
/// reads `generation` from `state.json` to seed the pane
/// (`RemoteTranscriptSyncSnapshot.cached(for:)`); `state.json` is always
/// replaced atomically, so that read never sees a torn file.
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

    /// Prefix of the temporary file a reset or a prepend writes before renaming
    /// it over `transcript.jsonl`. Dot-prefixed so a directory listing does not
    /// show it beside the real file; swept by `load()` when a crash stranded one.
    private static let tempPrefix = ".\(TBDConstants.remoteTranscriptFileName)."

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
    /// - A `pendingPrepend` marker: a prepend died somewhere between its first
    ///   and last write, so `length` may describe either file. The same
    ///   start-over, checked before any length comparison.
    ///
    /// Every start-over also clears `before` and `hint`: neither describes an
    /// empty file.
    ///
    /// A pair that already agrees is returned unchanged, with nothing written.
    func load() throws -> RemoteTranscriptCacheState {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        sweepStrandedTempFiles()

        let fileSize = try currentFileSize()
        var state: RemoteTranscriptCacheState
        var stateUnreadable = false
        if let data = try? Data(contentsOf: stateURL) {
            if let decoded = try? JSONDecoder().decode(RemoteTranscriptCacheState.self, from: data),
               decoded.length >= 0, decoded.generation >= 0, decoded.head >= 0 {
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

        if state.pendingPrepend {
            try truncateTranscript(to: 0)
            state = RemoteTranscriptCacheState(
                cursor: nil, length: 0, generation: state.generation + 1, before: nil,
                head: state.head, hint: nil, pendingPrepend: false)
            cacheLogger.error(
                """
                remote transcript cache \(directory.path, privacy: .public): a prepend did not finish; \
                cleared, generation \(state.generation, privacy: .public)
                """)
            try writeState(state)
            return state
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
        state = RemoteTranscriptCacheState(
            cursor: nil, length: 0, generation: state.generation + 1, head: state.head)
        cacheLogger.error(
            """
            remote transcript cache \(directory.path, privacy: .public): file (\(fileSize, privacy: .public) bytes) \
            disagrees with its state; cleared, generation \(state.generation, privacy: .public)
            """)
        try writeState(state)
        return state
    }

    /// The committed state as `state.json` records it, without repairing
    /// anything, creating the directory, or writing a byte. Nil when the file
    /// is missing or unreadable. For a reader outside the session's lane, which
    /// must never race the lane's writes with a repair of its own.
    func peekState() -> RemoteTranscriptCacheState? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(RemoteTranscriptCacheState.self, from: data)
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
        var next = state
        next.cursor = cursor
        next.length = state.length + body.count
        try writeState(next)
        return next
    }

    // MARK: - Reset

    /// Replaces the conversation with `page` and commits `cursor`, and for a
    /// tail reset the envelope's `before`, under the next generation. A forward
    /// reset passes no `before`, which clears any the cache held: the file then
    /// starts at the conversation's beginning.
    ///
    /// A page byte-identical to what is committed keeps its generation: a
    /// provider with no incremental support answers every call with the whole
    /// conversation, and bumping the generation each time would make the app
    /// discard and re-render an unchanged transcript on every sync. A reset
    /// that changes the file clears `hint`, which the sync records again once
    /// caught up.
    func reset(
        to page: Data, cursor: String?, before: String? = nil, from state: RemoteTranscriptCacheState
    ) throws -> RemoteTranscriptCacheState {
        let body = Self.lineTerminated(page)
        if body.count == state.length, let current = try? Data(contentsOf: transcriptURL), current == body {
            var next = state
            next.cursor = cursor
            next.before = before
            if next != state { try writeState(next) }
            return next
        }

        let generation = state.generation + 1
        // Commit "empty, from the beginning" first: from here until the final
        // state write, a crash leaves length 0 and no cursor, which `load()`
        // repairs to an empty file rather than a mix of two conversations.
        try writeState(RemoteTranscriptCacheState(
            cursor: nil, length: 0, generation: generation, head: state.head))

        try replaceTranscript(with: body)

        let next = RemoteTranscriptCacheState(
            cursor: cursor, length: body.count, generation: generation, before: before, head: state.head)
        try writeState(next)
        return next
    }

    // MARK: - Prepend

    /// Puts one page of earlier history at the front of the one file, in the
    /// four steps § Cache "Prepend" fixes: marker, temporary file (the page
    /// followed by the committed file), rename, final state. A crash anywhere
    /// after the marker leaves `pendingPrepend` set, and `load()` resets the
    /// cache rather than truncating a prepended file at an offset that
    /// described the old one.
    ///
    /// `before` is the cursor for the history above this page, nil once the
    /// page reaches the conversation's beginning. The forward `cursor` and the
    /// generation are untouched: the bottom of the file has not moved.
    func prepend(
        _ page: Data, before: String?, to state: RemoteTranscriptCacheState
    ) throws -> RemoteTranscriptCacheState {
        var marked = state
        marked.pendingPrepend = true
        try writeState(marked)

        let body = Self.lineTerminated(page)
        let current = (try? Data(contentsOf: transcriptURL)) ?? Data()
        try replaceTranscript(with: body + current.prefix(state.length))

        var next = state
        next.length = body.count + state.length
        next.before = before
        next.head = state.head + 1
        next.pendingPrepend = false
        try writeState(next)
        return next
    }

    // MARK: - Single-field commits

    /// Records the hint a caught-up sync saw. Writes `state.json` only.
    func commitHint(
        _ hint: RemoteTranscriptHint, to state: RemoteTranscriptCacheState
    ) throws -> RemoteTranscriptCacheState {
        var next = state
        next.hint = hint
        try writeState(next)
        return next
    }

    /// Marks the cache as reaching the conversation's beginning, or as holding
    /// history above it that can no longer be fetched. Writes `state.json` only.
    func clearBefore(in state: RemoteTranscriptCacheState) throws -> RemoteTranscriptCacheState {
        var next = state
        next.before = nil
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

    /// Writes `body` to a temporary file and renames it over
    /// `transcript.jsonl`, so a reader never sees a half-written file.
    private func replaceTranscript(with body: Data) throws {
        let temp = directory.appendingPathComponent("\(Self.tempPrefix)\(UUID().uuidString).tmp")
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
    }

    private func writeState(_ state: RemoteTranscriptCacheState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: stateURL, options: .atomic)
    }

    /// Removes reset and prepend temp files a crash stranded between write
    /// and rename.
    private func sweepStrandedTempFiles() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix(Self.tempPrefix) {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
