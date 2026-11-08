import Foundation
import os
import TBDShared

// MARK: - Source and events

/// Where a transcript feed reads from.
///
/// A remote session's source joins this enum as its own case; `open()` and
/// `refreshSession()` are the places that switch on it.
enum TranscriptFeedSource: Sendable {
    /// A local Claude session. `resolvePath` finds the session's transcript
    /// file as the terminal row names it now (`ClaudeTranscriptLocator`), or
    /// nil when it cannot tell. The feed calls it at open, at start and on
    /// every session change, so a session that moved to a new file is followed
    /// there. The path never comes from the phone.
    case local(terminalID: UUID, resolvePath: @Sendable () async -> String?)
}

/// One live event of an open transcript, as the feed hands it to the
/// service, which numbers it on the phone's stream.
enum TranscriptFeedEvent: Sendable, Equatable {
    /// New items: `transcript.append`.
    case append(TranscriptItemsData)
    /// Items the phone has, shaped again: `transcript.update`.
    case update(TranscriptItemsData)
    /// The transcript started over: `transcript.reset`.
    case reset(TranscriptResetData)
}

// MARK: - The feed

/// One phone's open transcript: its first page, the older pages before it,
/// and the live `transcript.append`, `transcript.update` and
/// `transcript.reset` events after it (spec section 7).
///
/// **Lifecycle.** `open()` reads the first page and starts nothing, so a feed
/// that is never started holds no task and no file. `start()` begins the live
/// part: one worker, which does every read and emits every event in order,
/// and one watcher over the transcript file. `close()` ends both for good.
/// The service starts a feed once the phone's connection is live, so its
/// events follow the `transcript.open` reply, and closes it on
/// `transcript.close`, on another open, when the grace after a disconnect
/// runs out and on a revoke.
///
/// **What wakes the worker.** A watcher tick (`FileWatcher`, debounced on the
/// injected clock) or a state delta for the terminal (`noteDelta(_:)`) asks
/// for a step. A session change, and any delta while the feed has no file,
/// asks for the path first. Wakeups coalesce, so a burst of them costs one
/// read, and the last read always follows the last wakeup.
///
/// **A step** (`TranscriptAppendCursor.step(path:)`):
/// - **Lines appended** are ingested one at a time into an
///   `IncrementalTranscript`, each with the offset of its first byte, and
///   shaped. New items go out as `transcript.append`. Earlier live items
///   patched by a result in this batch, and calls on a page the phone loaded
///   whose result arrived, go out as `transcript.update`. Each event fits
///   `PhoneFrameBudget.eventDataBytes` (`frames(_:session:budget:)`).
/// - **A rewrite** (`/clear`, `/compact`, a same-size rewrite) starts over:
///   the generation goes up, so every cursor the phone holds goes stale, and
///   `transcript.reset` with reason `rewrite` carries the new first page.
/// - **Nothing new, or a read that failed**, sends nothing.
///
/// **A rollover.** When the path resolves to a different file, the feed
/// starts over on that file with reason `rollover` and watches it instead.
/// A path that does not resolve changes nothing.
///
/// **A missing file** gives an empty first page that has reached its start.
/// The feed looks again on every delta for its terminal, and once the file
/// reads, sends its first page in a reset.
///
/// **Item IDs match the pager's.** A line without a `uuid` gets
/// `at-<offset>` as its ID in a page (`TranscriptParser.parseWindow`), so the
/// feed stamps that `uuid` on such a line before ingesting it, when the batch
/// gives each line's exact offset. A batch that skipped a line (an empty
/// line, or one that is not UTF-8) gives no exact offsets, and its lines keep
/// the incremental parser's own IDs and take the batch's start as their
/// offset.
///
/// **Bounded state.** Every index drops the entry added first once it is
/// full (`TranscriptFeedIndex`):
/// - **results** – `resultLimit` tool results from every page read and from
///   live lines, joined into older pages as `ShapingContext.joinedResults`.
///   A call on an older page whose result has been dropped shows `running`;
/// - **line offsets** – `lineOffsetLimit` item IDs, for detail lookups;
/// - **calls waiting** – `waitingCallLimit` page rows still `running`, kept to
///   update when their result arrives;
/// - **live facts** – `liveFactLimit` file-edit stats and subagent IDs from
///   live lines;
/// - **page subagent IDs** – `liveFactLimit` subagent IDs from the pages read,
///   so `transcript.detail` can find a page row's subagent;
/// - **subagent counts** – `SubagentCountCache.limit` counts, each read once
///   per agent and read again once the agent's result arrives.
///
/// The live `IncrementalTranscript` holds the items appended since the last
/// reset, which it needs to patch late results, so it grows with the live
/// part of a session and starts over on every reset.
actor TranscriptFeed {
    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "phone-bridge")

    static let resultLimit = 4_096
    static let lineOffsetLimit = 8_192
    static let waitingCallLimit = 1_024
    static let liveFactLimit = 1_024

    static let rewriteReason = "rewrite"
    static let rolloverReason = "rollover"

    /// The page of a transcript with no file yet.
    static let emptyPage = TranscriptPage(items: [], cursor: nil, reachedStart: true, omittedItems: 0)

    let session: PhoneSessionRef
    let showDetails: Bool
    private let source: TranscriptFeedSource
    private let emit: @Sendable (TranscriptFeedEvent) async -> Void
    private let clock: any Clock<Duration>

    /// The transcript file, or nil when it never resolved.
    private var path: String?
    /// Goes up on every reset; the phone's cursors carry it.
    private(set) var generation = 0
    /// Where the live part reads from; nil while the file has not been read.
    private var cursor: TranscriptAppendCursor?
    private var transcript = IncrementalTranscript()
    private var results = TranscriptFeedIndex<ToolResult>(limit: TranscriptFeed.resultLimit)
    private var lineOffsets = TranscriptFeedIndex<UInt64>(limit: TranscriptFeed.lineOffsetLimit)
    private var waitingCalls = TranscriptFeedIndex<PhoneItem>(limit: TranscriptFeed.waitingCallLimit)
    private var liveFileEdits = TranscriptFeedIndex<FileEditStats>(limit: TranscriptFeed.liveFactLimit)
    private var liveAgentIDs = TranscriptFeedIndex<String>(limit: TranscriptFeed.liveFactLimit)
    private var pageAgentIDs = TranscriptFeedIndex<String>(limit: TranscriptFeed.liveFactLimit)
    private let subagentCounts = SubagentCountCache()
    private var lastDetail: CachedDetail?

    private var wakeups: AsyncStream<Void>.Continuation?
    private var worker: Task<Void, Never>?
    private var watcher: Task<Void, Never>?
    private var watcherToken: UInt64 = 0
    private var stepWanted = false
    private var sessionCheckWanted = false
    private var closed = false
    /// The reads the worker has finished, each with its events emitted. For
    /// tests, which wait on it to know a read is behind them.
    private(set) var readCount = 0

    /// The last detail the phone was sent, for the generation it was read in.
    private struct CachedDetail: Sendable {
        let generation: Int
        let itemID: String
        let part: TranscriptDetailPart
        let value: any Sendable
    }

    init(session: PhoneSessionRef, showDetails: Bool, source: TranscriptFeedSource,
         emit: @escaping @Sendable (TranscriptFeedEvent) async -> Void,
         clock: any Clock<Duration> = ContinuousClock()) {
        self.session = session
        self.showDetails = showDetails
        self.source = source
        self.emit = emit
        self.clock = clock
    }

    // MARK: - Opening and closing

    /// The first page, generation 0: `TranscriptPager.firstPage` over the
    /// session's file, or `emptyPage` when it has none or it cannot be read.
    /// Starts nothing.
    func open() async throws -> TranscriptPage {
        switch source {
        case .local(_, let resolvePath):
            path = await resolvePath()
        }
        return loadFirstPage(generation: generation) ?? Self.emptyPage
    }

    /// Starts the live part: the worker, the watcher, and a first wakeup that
    /// resolves the path again and reads what was appended since `open()`.
    /// Does nothing once started or closed.
    func start() {
        guard !closed, worker == nil else { return }
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wakeups = continuation
        sessionCheckWanted = true
        stepWanted = true
        continuation.yield()
        worker = Task { [weak self] in
            for await _ in stream {
                guard let self else { return }
                await self.runWanted()
            }
        }
        startWatcher()
    }

    /// Ends the worker and the watcher for good. A later `start()` does
    /// nothing, and a read in progress emits nothing more.
    func close() {
        closed = true
        lastDetail = nil
        wakeups?.finish()
        wakeups = nil
        worker?.cancel()
        worker = nil
        stopWatcher()
    }

    /// Whether a watcher task runs. For tests.
    var isWatching: Bool {
        watcher != nil
    }

    /// The file the feed reads, or nil with none. For tests.
    var transcriptPath: String? {
        path
    }

    // MARK: - Wakeups

    /// Wakes the worker for a delta about the feed's terminal: a session
    /// change (`terminalSessionUpdated`, `terminalReplaced`) asks for the path
    /// again, and activity, prompt, awaiting-input and parking changes ask for
    /// a step. Any other delta, and any delta before `start()`, does nothing.
    func noteDelta(_ delta: StateDelta) {
        guard case .local(let terminalID, _) = source else { return }
        switch delta {
        case .terminalSessionUpdated(let d) where d.terminalID == terminalID:
            sessionCheckWanted = true
        case .terminalReplaced(let terminal) where terminal.id == terminalID:
            sessionCheckWanted = true
        case .terminalActivityUpdated(let d) where d.terminalID == terminalID:
            stepWanted = true
        case .terminalPendingPromptsChanged(let d) where d.terminalID == terminalID:
            stepWanted = true
        case .terminalAwaitingInputChanged(let d) where d.terminalID == terminalID:
            stepWanted = true
        case .terminalHibernationChanged(let d) where d.terminalID == terminalID:
            stepWanted = true
        default:
            return
        }
        wakeups?.yield()
    }

    /// A watcher tick.
    private func noteFileChange() {
        stepWanted = true
        wakeups?.yield()
    }

    /// Does what the wakeups asked for, until nothing more is wanted, and
    /// emits each read's events in order before the next read.
    private func runWanted() async {
        while !closed, sessionCheckWanted || stepWanted {
            // With no file read yet, any wakeup looks for the file again.
            let checkSession = sessionCheckWanted || cursor == nil
            sessionCheckWanted = false
            stepWanted = false
            let events: [TranscriptFeedEvent]
            if checkSession {
                events = await refreshSession()
            } else {
                events = step()
            }
            if watcher == nil {
                startWatcher()
            }
            for event in events {
                guard !closed else { return }
                await emit(event)
            }
            readCount += 1
        }
    }

    // MARK: - Reading

    /// Resolves the path again. A different file is a rollover; the same one
    /// takes a step. Nil changes nothing.
    private func refreshSession() async -> [TranscriptFeedEvent] {
        let resolved: String?
        switch source {
        case .local(_, let resolvePath):
            resolved = await resolvePath()
        }
        guard !closed else { return [] }
        guard let resolved, resolved != path else { return step() }
        path = resolved
        stopWatcher()
        return [reset(reason: Self.rolloverReason)]
    }

    /// One read of the lines appended since the last.
    private func step() -> [TranscriptFeedEvent] {
        guard let path else { return [] }
        guard var cursor else {
            // The file has not been read: once it reads, its first page goes
            // out as a reset.
            let next = generation + 1
            guard let page = loadFirstPage(generation: next) else { return [] }
            generation = next
            return [.reset(TranscriptResetData(session: session, reason: Self.rewriteReason, page: page))]
        }
        let start = cursor.offset
        switch cursor.step(path: path) {
        case .unreadable, .unchanged:
            return []
        case .reset:
            return [reset(reason: Self.rewriteReason)]
        case .appended(let lines):
            let end = cursor.offset
            self.cursor = cursor
            return ingest(lines, from: start, to: end)
        }
    }

    /// Starts over at the file's tail in a new generation.
    private func reset(reason: String) -> TranscriptFeedEvent {
        generation += 1
        let page = loadFirstPage(generation: generation) ?? Self.emptyPage
        return .reset(TranscriptResetData(session: session, reason: reason, page: page))
    }

    /// Drops everything built from the file, reads the first page in
    /// `generation`, and keeps what the live part needs from it. Nil, with
    /// no cursor, when there is no path or the file cannot be read.
    private func loadFirstPage(generation: Int) -> TranscriptPage? {
        cursor = nil
        transcript = IncrementalTranscript()
        results.removeAll()
        lineOffsets.removeAll()
        waitingCalls.removeAll()
        liveFileEdits.removeAll()
        liveAgentIDs.removeAll()
        pageAgentIDs.removeAll()
        subagentCounts.removeAll()
        lastDetail = nil
        guard let path,
              let build = TranscriptPager.firstPage(
                filePath: path, generation: generation,
                ctx: ShapingContext(showDetails: showDetails, subagentItemCount: subagentCount(path: path)))
        else { return nil }
        for (id, result) in build.results {
            results.set(result, for: id)
        }
        for (id, offset) in build.lineOffsets {
            lineOffsets.set(offset, for: id)
        }
        for (id, item) in build.unresolvedCalls {
            waitingCalls.set(item, for: id)
        }
        for (id, agentID) in build.subagentAgentIDs {
            pageAgentIDs.set(agentID, for: id)
        }
        cursor = TranscriptAppendCursor(path: path, offset: build.endOffset) { path, offset in
            TranscriptAppendCursor.diskTailWindow(path: path, endingAt: offset)
        }
        return build.page
    }

    /// The events for `lines`, read from `start` to `end`.
    private func ingest(_ lines: [String], from start: UInt64, to end: UInt64) -> [TranscriptFeedEvent] {
        guard !lines.isEmpty, let path else { return [] }
        let span = lines.reduce(UInt64(0)) { $0 + UInt64($1.utf8.count) + 1 }
        let exact = span == end - start
        var lineOffset = start
        let firstNew = transcript.items.count
        var patched: Set<Int> = []
        var resolved: [String] = []
        for line in lines {
            var text = line
            if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
               let json = object as? [String: Any] {
                for (id, stats) in TranscriptParser.fileEditStats(fromLine: json) {
                    liveFileEdits.set(stats, for: id)
                }
                for (id, agentID) in TranscriptParser.subagentAgentIDs(fromLine: json) {
                    liveAgentIDs.set(agentID, for: id)
                    subagentCounts.forget(agentID)
                }
                if exact, json["uuid"] == nil, let stamped = Self.stamped(json, offset: lineOffset) {
                    text = stamped
                }
            }
            let before = transcript.items.count
            let change = transcript.ingest(lines: [text])
            for index in before..<transcript.items.count {
                lineOffsets.set(lineOffset, for: transcript.items[index].id)
            }
            patched.formUnion(change.updated.filter { $0 < firstNew })
            resolved.append(contentsOf: change.resolvedToolUseIDs)
            if exact {
                lineOffset += UInt64(line.utf8.count) + 1
            }
        }

        let ctx = ShapingContext(
            showDetails: showDetails, fileEdits: liveFileEdits.dictionary,
            subagentAgentIDs: liveAgentIDs.dictionary, subagentItemCount: subagentCount(path: path))
        let appended = transcript.items[firstNew...].compactMap { TranscriptShaper.shape($0, ctx) }
        var updated = patched.sorted().compactMap { TranscriptShaper.shape(transcript.items[$0], ctx) }
        for id in resolved {
            guard let result = transcript.toolResult(for: id) else { continue }
            results.set(result, for: id)
            if let row = waitingCalls.remove(id) {
                updated.append(resolvedRow(row, result: result, path: path))
            }
        }
        let appendEvents = Self.frames(appended, session: session, budget: PhoneFrameBudget.eventDataBytes)
            .map(TranscriptFeedEvent.append)
        let updateEvents = Self.frames(updated, session: session, budget: PhoneFrameBudget.eventDataBytes)
            .map(TranscriptFeedEvent.update)
        return appendEvents + updateEvents
    }

    /// A page row that was `running`, with its result's status and, for a
    /// subagent, its item count.
    private func resolvedRow(_ row: PhoneItem, result: ToolResult, path: String) -> PhoneItem {
        var itemCount = row.itemCount
        if row.kind == .subagent, let agentID = liveAgentIDs[row.id] {
            itemCount = subagentCount(path: path)(agentID).map { min(max($0, 0), PhoneAppConstants.subagentCountLimit) }
        }
        return PhoneItem(
            id: row.id, kind: row.kind, at: row.at, text: row.text, truncated: row.truncated,
            toolName: row.toolName, target: row.target,
            toolStatus: result.isError ? TranscriptShaper.errorStatus : TranscriptShaper.okStatus,
            added: row.added, removed: row.removed, agentType: row.agentType, itemCount: itemCount,
            sender: row.sender)
    }

    /// `json` with `"uuid": "at-<offset>"`, encoded again, or nil when it
    /// does not encode.
    private static func stamped(_ json: [String: Any], offset: UInt64) -> String? {
        var copy = json
        copy["uuid"] = "at-\(offset)"
        guard let data = try? JSONSerialization.data(withJSONObject: copy) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The subagent counts for the transcript at `path`, through the cache.
    private func subagentCount(path: String) -> @Sendable (String) -> Int? {
        let counts = subagentCounts
        let showDetails = self.showDetails
        return { agentID in
            counts.count(agentID: agentID, transcriptPath: path, showDetails: showDetails)
        }
    }

    // MARK: - The watcher

    /// Watches the file, when there is one, in place of any earlier watcher.
    /// A watcher whose stream ends on its own (the file went away) is
    /// replaced after the next read that finds the file again.
    private func startWatcher() {
        stopWatcher()
        guard !closed, let path, FileManager.default.fileExists(atPath: path) else { return }
        watcherToken &+= 1
        let token = watcherToken
        let changes = FileWatcher(clock: clock).changes(for: path)
        watcher = Task { [weak self] in
            for await _ in changes {
                await self?.noteFileChange()
            }
            await self?.watcherEnded(token)
        }
    }

    private func stopWatcher() {
        watcherToken &+= 1
        watcher?.cancel()
        watcher = nil
    }

    private func watcherEnded(_ token: UInt64) {
        guard token == watcherToken else { return }
        watcher = nil
    }

    // MARK: - Older pages and details

    /// The page before `cursor`, with the results the feed keeps joined in.
    /// Its results, its rows' offsets and its calls still `running` are kept
    /// too, so the page before it can join a result that sits on this one.
    /// Throws `stale_cursor` for a cursor of another generation, or one that
    /// no longer names a line of the file.
    func olderPage(cursor: String) throws -> TranscriptPage {
        guard let path else {
            throw PhoneAppError(code: .staleCursor, message: TranscriptPager.staleCursorMessage)
        }
        let ctx = ShapingContext(
            showDetails: showDetails, joinedResults: results.dictionary, subagentItemCount: subagentCount(path: path))
        let build = try TranscriptPager.olderPage(filePath: path, cursor: cursor, generation: generation, ctx: ctx)
        for (id, result) in build.results {
            results.set(result, for: id)
        }
        for (id, offset) in build.lineOffsets {
            lineOffsets.set(offset, for: id)
        }
        for (id, item) in build.unresolvedCalls {
            waitingCalls.set(item, for: id)
        }
        for (id, agentID) in build.subagentAgentIDs {
            pageAgentIDs.set(agentID, for: id)
        }
        return build.page
    }

    /// Where to look up `itemID`'s detail, or nil when the feed has no file:
    /// the transcript file, the offset of the item's line and its subagent's
    /// ID when the feed kept them, and the generation they belong to.
    func detailContext(itemID: String) -> TranscriptDetailContext? {
        guard let path else { return nil }
        return TranscriptDetailContext(
            filePath: path, lineOffset: lineOffsets[itemID],
            agentID: liveAgentIDs[itemID] ?? pageAgentIDs[itemID], generation: generation)
    }

    /// The detail last cached for `itemID`'s `part` in this generation, as
    /// `Value`, or nil.
    func cachedDetail<Value: Sendable>(itemID: String, part: TranscriptDetailPart, as type: Value.Type) -> Value? {
        guard let lastDetail, lastDetail.generation == generation,
              lastDetail.itemID == itemID, lastDetail.part == part else { return nil }
        return lastDetail.value as? Value
    }

    /// Keeps `value`, read in `generation`, as the detail of `itemID`'s
    /// `part`, in place of the one kept before. Keeps nothing once the feed
    /// is closed or has moved to another generation.
    func cacheDetail<Value: Sendable>(_ value: Value, itemID: String, part: TranscriptDetailPart, generation: Int) {
        guard !closed, generation == self.generation else { return }
        lastDetail = CachedDetail(generation: generation, itemID: itemID, part: part, value: value)
    }

    // MARK: - Frames

    /// `items` in order, split into as few `TranscriptItemsData` as keep each
    /// one's encoded size within `budget`. An item too large for any frame is
    /// left out and logged by count; the shaper's caps keep every item far
    /// below the budget.
    static func frames(_ items: [PhoneItem], session: PhoneSessionRef, budget: Int) -> [TranscriptItemsData] {
        guard !items.isEmpty else { return [] }
        let encoder = PhoneAppCoding.makeEncoder()
        let empty = (try? encoder.encode(TranscriptItemsData(session: session, items: [])).count) ?? budget
        var frames: [TranscriptItemsData] = []
        var current: [PhoneItem] = []
        var used = empty
        var tooLarge = 0
        for item in items {
            let size = (try? encoder.encode(item).count) ?? budget + 1
            guard empty + size <= budget else {
                tooLarge += 1
                continue
            }
            if !current.isEmpty, used + 1 + size > budget {
                frames.append(TranscriptItemsData(session: session, items: current))
                current = []
                used = empty
            }
            used += current.isEmpty ? size : size + 1
            current.append(item)
        }
        if !current.isEmpty {
            frames.append(TranscriptItemsData(session: session, items: current))
        }
        if tooLarge > 0 {
            logger.error("Phone transcript: left out \(tooLarge, privacy: .public) items too large for an event")
        }
        return frames
    }
}

// MARK: - Bounded index

/// A string-keyed map that holds at most `limit` entries, dropping the one
/// added first when a new key would pass the limit. Updating a key keeps its
/// place; removing one and adding it again puts it last.
struct TranscriptFeedIndex<Value: Sendable>: Sendable {
    private struct Entry: Sendable {
        let stamp: UInt64
        let value: Value
    }

    private struct Slot: Sendable {
        let key: String
        let stamp: UInt64
    }

    let limit: Int
    private var entries: [String: Entry] = [:]
    /// Keys in the order they were added, from `head`. A slot whose stamp no
    /// longer matches its key's entry was removed or replaced and is skipped.
    private var order: [Slot] = []
    private var head = 0
    private var nextStamp: UInt64 = 0

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    var count: Int {
        entries.count
    }

    subscript(key: String) -> Value? {
        entries[key]?.value
    }

    /// Every entry, as a dictionary.
    var dictionary: [String: Value] {
        entries.mapValues(\.value)
    }

    mutating func set(_ value: Value, for key: String) {
        if let existing = entries[key] {
            entries[key] = Entry(stamp: existing.stamp, value: value)
            return
        }
        let stamp = nextStamp
        nextStamp &+= 1
        entries[key] = Entry(stamp: stamp, value: value)
        order.append(Slot(key: key, stamp: stamp))
        while entries.count > limit, head < order.count {
            let oldest = order[head]
            head += 1
            if entries[oldest.key]?.stamp == oldest.stamp {
                entries[oldest.key] = nil
            }
        }
        // Slots of removed entries pile up only until the next compaction,
        // so `order` stays within a few times `limit`.
        if head >= limit || order.count - head > 2 * limit {
            order = order[head...].filter { entries[$0.key]?.stamp == $0.stamp }
            head = 0
        }
    }

    @discardableResult
    mutating func remove(_ key: String) -> Value? {
        entries.removeValue(forKey: key)?.value
    }

    mutating func removeAll() {
        entries = [:]
        order = []
        head = 0
    }
}

// MARK: - Subagent counts

/// Subagent item counts by agent ID, for `ShapingContext.subagentItemCount`.
///
/// Each count parses up to `PhoneAppConstants.subagentCountLimit` bytes of
/// the subagent's transcript, so a count is read once per agent and kept,
/// unknown counts included. The feed forgets an agent's count when the
/// agent's result arrives, so the count read after it is the finished one,
/// and forgets every count on a reset. At most `limit` are kept; past that
/// the cache starts over.
final class SubagentCountCache: Sendable {
    static let limit = 256

    private let counts = OSAllocatedUnfairLock<[String: Int?]>(initialState: [:])

    func count(agentID: String, transcriptPath: String, showDetails: Bool) -> Int? {
        if let cached = counts.withLock({ $0[agentID] }) {
            return cached
        }
        let fresh = TranscriptPager.subagentItemCount(
            transcriptPath: transcriptPath, agentID: agentID, showDetails: showDetails)
        counts.withLock { counts in
            if counts.count >= Self.limit {
                counts.removeAll()
            }
            counts[agentID] = .some(fresh)
        }
        return fresh
    }

    func forget(_ agentID: String) {
        _ = counts.withLock { $0.removeValue(forKey: agentID) }
    }

    func removeAll() {
        counts.withLock { $0.removeAll() }
    }
}
