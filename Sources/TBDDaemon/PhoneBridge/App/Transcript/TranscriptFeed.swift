import Foundation
import os
import TBDShared

// MARK: - Source and events

/// Where a transcript feed reads from.
enum TranscriptFeedSource: Sendable {
    /// A local Claude session. `resolvePath` finds the session's transcript
    /// file as the terminal row names it now (`ClaudeTranscriptLocator`), or
    /// nil when it cannot tell. The feed calls it at open, at start and on
    /// every session change, so a session that moved to a new file is followed
    /// there. The path never comes from the phone.
    case local(terminalID: UUID, resolvePath: @Sendable () async -> String?)
    /// A remote session's transcript cache, which `follower` syncs while the
    /// feed is live. Each sync names the cache file; the path never comes from
    /// the phone.
    case remote(RemoteTranscriptFollower)
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
/// **The first live read is checked.** A fresh `TranscriptAppendCursor`
/// reads from its offset without checking the file, so the feed takes one
/// step as soon as it builds one, right after the page read. Every later step
/// can then tell a rewrite from an append, however long the live part waits
/// to start. Lines that first step read go out with the next step's.
///
/// **Item IDs match the pager's.** A line without a string `uuid` gets
/// `at-<offset>` as its ID in a page (`TranscriptParser.parseWindow`), so the
/// feed stamps that `uuid` on such a line before ingesting it, when the batch
/// gives each line's exact offset. A batch that skipped a line (an empty
/// line, or one that is not UTF-8) gives no exact offsets, so such a line is
/// stamped `line-<n>` instead, counting the live lines since the last reset
/// as the incremental parser would, and takes the batch's start as its
/// offset.
///
/// **A remote session** reads the daemon's transcript cache instead of a
/// session file, and follows it through `RemoteTranscriptFollower` rather
/// than a watcher: `open()` syncs once and pages the cache the sync names,
/// and the live part runs one sync per `remoteSyncInterval`, the phone
/// counting as a viewer while the transcript is open. Each sync's result is
/// applied in order by the worker:
/// - **a newer cache generation**, or another cache file, starts over with
///   reason `generation`;
/// - **a newer `head`**, earlier history prepended to the cache, moves the
///   cursor past the prepend (`TranscriptAppendCursor.rebaseAfterPrepend`),
///   and every line offset the feed keeps with it, so the live part goes on
///   appending; when the cursor's bytes cannot be found, the feed starts over
///   with reason `rewrite`;
/// - **then a step**, as for a local file. A step that finds the cache
///   changed before the cursor tries the same move first, since within a
///   generation the cache only grows at either end, and a load another
///   viewer ran can prepend before any sync reports it.
///
/// A sync that fails sends nothing; the next one that succeeds brings the
/// phone up to date. An older page that reaches the top of the cache while
/// the last sync said earlier history can be loaded loads it first
/// (`olderPage(cursor:)`).
///
/// **Bounded state.** Every index drops the entry added first once it is
/// full (`TranscriptFeedIndex`):
/// - **results** – `resultLimit` tool results from every page read and from
///   live lines, joined into older pages as `ShapingContext.joinedResults`.
///   Only each result's `isError` is kept, the one part shaping reads.
///   A call on an older page whose result has been dropped shows `running`;
/// - **line offsets** – `lineOffsetLimit` item IDs, for detail lookups;
/// - **calls waiting** – `waitingCallLimit` rows still `running`, from pages
///   and from live transcripts set aside, kept to update when their result
///   arrives;
/// - **live facts** – `liveFactLimit` file-edit stats and subagent IDs from
///   live lines;
/// - **page subagent IDs** – `liveFactLimit` subagent IDs from the pages read,
///   so `transcript.detail` can find a page row's subagent;
/// - **subagent counts** – `SubagentCountCache.limit` counts, each read once
///   per agent and read again once the agent's result arrives.
///
/// The live `IncrementalTranscript` holds the items appended since it
/// started, which it needs to patch late results. It starts over on every
/// reset, and also once it holds `liveItemLimit` items, since compaction
/// keeps appending to the same file: its calls still `running` then join the
/// calls waiting, where a late result updates them as it updates a page's
/// (`resolvedRow`), so the phone sees no difference.
actor TranscriptFeed {
    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "phone-bridge")

    static let resultLimit = 4_096
    static let lineOffsetLimit = 8_192
    static let waitingCallLimit = 1_024
    static let liveFactLimit = 1_024
    /// The most items the live transcript holds before it starts over.
    static let liveItemLimit = 2_000

    static let rewriteReason = "rewrite"
    static let rolloverReason = "rollover"
    static let generationReason = "generation"

    private static let staleCursor = PhoneAppError(code: .staleCursor, message: TranscriptPager.staleCursorMessage)
    /// The kinds of item that count as messages for an older page's
    /// `olderPageMessages`, as `TranscriptParser.parseWindow` counts them.
    private static let messageKinds: Set<PhoneItemKind> = [.user, .slash, .assistant, .peer]

    /// The page of a transcript with no file yet.
    static let emptyPage = TranscriptPage(items: [], cursor: nil, reachedStart: true, omittedItems: 0)

    let session: PhoneSessionRef
    let showDetails: Bool
    private let source: TranscriptFeedSource
    private let emit: @Sendable (TranscriptFeedEvent) async -> Void
    private let liveItemLimit: Int
    private let clock: any Clock<Duration>

    /// The transcript file, or nil when it never resolved.
    private var path: String?
    /// Goes up on every reset; the phone's cursors carry it.
    private(set) var generation = 0
    /// Where the live part reads from; nil while the file has not been read.
    private var cursor: TranscriptAppendCursor?
    /// Lines the cursor read when it was built, past the page, from the
    /// page's end: the next step ingests them before its own.
    private var heldLines: (lines: [String], start: UInt64)?
    private var transcript = IncrementalTranscript()
    /// The non-empty live lines ingested since the last reset, across live
    /// transcripts, for the `line-<n>` IDs.
    private var liveLineCount = 0
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

    /// What the last sync, or load of earlier history, said about a remote
    /// session's cache. Nil for a local source.
    private var remote: RemoteCache?
    /// The newest sync result the worker has yet to apply.
    private var pendingSync: RemoteTranscriptSyncResult?
    /// A start-over a load of earlier history asked the worker for, with its
    /// reason.
    private var pendingReset: String?
    /// The follower's syncs, while the live part runs for a remote session.
    private var syncLoop: Task<Void, Never>?

    /// A remote session's cache, as the feed last heard of it.
    private struct RemoteCache: Sendable {
        /// The cache's own generation, which a provider reset bumps. Not the
        /// feed's `generation`, which the phone's cursors carry.
        var generation: Int
        /// Bumped by every prepend of earlier history within a generation.
        var head: Int
        /// Whether earlier history can be loaded now.
        var hasEarlier: Bool
        /// Whether a load reached the start in this generation, so no later
        /// sync offers earlier history again.
        var earlierEnded = false
    }

    /// The last detail the phone was sent, for the generation it was read in.
    private struct CachedDetail: Sendable {
        let generation: Int
        let itemID: String
        let part: TranscriptDetailPart
        let value: any Sendable
    }

    /// `liveItemLimit` is the production `liveItemLimit` unless a test needs
    /// the live transcript to start over sooner.
    init(session: PhoneSessionRef, showDetails: Bool, source: TranscriptFeedSource,
         emit: @escaping @Sendable (TranscriptFeedEvent) async -> Void,
         liveItemLimit: Int = TranscriptFeed.liveItemLimit,
         clock: any Clock<Duration> = ContinuousClock()) {
        self.session = session
        self.showDetails = showDetails
        self.source = source
        self.emit = emit
        self.liveItemLimit = max(1, liveItemLimit)
        self.clock = clock
    }

    // MARK: - Opening and closing

    /// The first page, generation 0: `TranscriptPager.firstPage` over the
    /// session's file, or `emptyPage` when it has none or it cannot be read.
    /// A remote session's file is the cache one sync names, and a sync that
    /// fails is the error thrown. Starts nothing.
    func open() async throws -> TranscriptPage {
        switch source {
        case .local(_, let resolvePath):
            path = await resolvePath()
        case .remote(let follower):
            let result = try await follower.sync()
            adopt(result)
        }
        return loadFirstPage(generation: generation) ?? Self.emptyPage
    }

    /// Starts the live part: the worker, the watcher (for a remote session,
    /// the follower's syncs), and a first wakeup that resolves the path again
    /// and reads what was appended since `open()`. Does nothing once started
    /// or closed.
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
        switch source {
        case .local:
            startWatcher()
        case .remote(let follower):
            startSyncLoop(follower)
        }
    }

    /// Ends the worker, the watcher and the follower's syncs for good. A
    /// later `start()` does nothing, and a read in progress emits nothing
    /// more.
    func close() {
        closed = true
        lastDetail = nil
        wakeups?.finish()
        wakeups = nil
        worker?.cancel()
        worker = nil
        stopWatcher()
        syncLoop?.cancel()
        syncLoop = nil
        pendingSync = nil
        pendingReset = nil
    }

    /// Whether a watcher task runs. For tests.
    var isWatching: Bool {
        watcher != nil
    }

    /// Whether the follower's syncs run. For tests.
    var isSyncing: Bool {
        syncLoop != nil
    }

    /// The file the feed reads, or nil with none. For tests.
    var transcriptPath: String? {
        path
    }

    /// The items the live transcript holds. For tests.
    var liveItemCount: Int {
        transcript.items.count
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

    /// A remote sync's result, in place of any the worker has yet to apply:
    /// each is compared with what the feed holds, so the newest is enough.
    private func noteSynced(_ result: RemoteTranscriptSyncResult) {
        guard !closed else { return }
        pendingSync = result
        wakeups?.yield()
    }

    /// Does what the wakeups asked for, until nothing more is wanted, and
    /// emits each read's events in order before the next read. Lines held
    /// by a reset's fresh cursor ask for a step of their own, so they follow
    /// the reset at once.
    private func runWanted() async {
        while !closed,
              sessionCheckWanted || stepWanted || heldLines != nil || pendingSync != nil || pendingReset != nil {
            // With no file read yet, any wakeup looks for the file again.
            let checkSession = sessionCheckWanted || cursor == nil
            sessionCheckWanted = false
            stepWanted = false
            let events: [TranscriptFeedEvent]
            if let reason = pendingReset {
                pendingReset = nil
                events = [reset(reason: reason)]
            } else if let result = pendingSync {
                pendingSync = nil
                events = applySync(result)
            } else if checkSession {
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
    /// takes a step. Nil changes nothing. A remote session's path comes with
    /// each sync instead, so it takes a step.
    private func refreshSession() async -> [TranscriptFeedEvent] {
        let resolvePath: @Sendable () async -> String?
        switch source {
        case .local(_, let resolve):
            resolvePath = resolve
        case .remote:
            return step()
        }
        let resolved = await resolvePath()
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
        // Lines held from when the cursor was built come first; they end
        // where the cursor now stands.
        var held = heldLines
        heldLines = nil
        var start = held?.start ?? cursor.offset
        var outcome = cursor.step(path: path)
        if outcome == .reset, case .remote = source, let shift = rebaseCursor(), let rebased = self.cursor {
            // Within a generation a remote cache only grows at either end, so
            // a change before the cursor is earlier history that a load
            // prepended before any sync reported it: read on past it.
            held = held.map { (lines: $0.lines, start: $0.start + shift) }
            cursor = rebased
            start = held?.start ?? cursor.offset
            outcome = cursor.step(path: path)
        }
        var lines = held?.lines ?? []
        switch outcome {
        case .unreadable, .unchanged:
            break
        case .reset:
            return [reset(reason: Self.rewriteReason)]
        case .appended(let appended):
            lines += appended
            self.cursor = cursor
        }
        return ingest(lines, from: start, to: cursor.offset)
    }

    // MARK: - A remote cache

    /// Takes a sync's cache file and state as the feed's own.
    private func adopt(_ result: RemoteTranscriptSyncResult) {
        path = result.path
        remote = RemoteCache(generation: result.generation, head: result.head, hasEarlier: result.hasEarlier)
    }

    /// Applies a sync's result, then steps. A newer cache generation, or
    /// another cache file, starts over with reason `generation`. A newer
    /// `head` moves the cursor past the earlier history prepended, or starts
    /// over with reason `rewrite` when it cannot. A result from a sync that
    /// read the cache before something the feed already applied (an older
    /// generation or `head`) changes nothing but the step.
    private func applySync(_ result: RemoteTranscriptSyncResult) -> [TranscriptFeedEvent] {
        guard var cache = remote else { return step() }
        if result.generation > cache.generation || result.path != path {
            adopt(result)
            return [reset(reason: Self.generationReason)]
        }
        guard result.generation == cache.generation, result.head >= cache.head else { return step() }
        let prepended = result.head > cache.head
        cache.head = result.head
        cache.hasEarlier = result.hasEarlier && !cache.earlierEnded
        remote = cache
        if prepended, rebaseCursor() == nil {
            return [reset(reason: Self.rewriteReason)]
        }
        return step()
    }

    /// Moves the cursor past earlier history prepended to a remote cache,
    /// with every offset the feed keeps beside it, and returns how many bytes
    /// were prepended. Nil, with nothing moved, when there is no cursor or
    /// the bytes it read are not found within `anchorScanLimit` past it; the
    /// caller then starts over.
    private func rebaseCursor() -> UInt64? {
        guard var moved = cursor else { return nil }
        let before = moved.offset
        guard moved.rebaseAfterPrepend(limit: PhoneAppConstants.anchorScanLimit), moved.offset >= before else {
            return nil
        }
        let shift = moved.offset - before
        cursor = moved
        if shift > 0 {
            lineOffsets.mapValues { $0 + shift }
            heldLines = heldLines.map { (lines: $0.lines, start: $0.start + shift) }
        }
        return shift
    }

    /// Runs the follower's syncs while the live part runs, each result handed
    /// to the worker. `close()` cancels the task, which ends the follower's
    /// stream and its syncing with it.
    private func startSyncLoop(_ follower: RemoteTranscriptFollower) {
        syncLoop = Task { [weak self] in
            let ticks = await follower.ticks()
            for await result in ticks {
                guard let self else { return }
                await self.noteSynced(result)
            }
        }
    }

    /// `build`'s page as the phone gets it, `build` read in `generation`. A
    /// remote page that reached the top of the cache while earlier history
    /// can be loaded has not reached the start: its cursor names offset 0, so
    /// the phone asks for the page before it, which loads that history. Any
    /// other page is as built.
    private func phonePage(_ build: PageBuild, generation: Int) -> TranscriptPage {
        guard build.page.reachedStart, remote?.hasEarlier == true, let path,
              let cursor = TranscriptPager.makeCursor(generation: generation, offset: 0, filePath: path) else {
            return build.page
        }
        return TranscriptPage(
            items: build.page.items, cursor: cursor, reachedStart: false, omittedItems: build.page.omittedItems)
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
        heldLines = nil
        transcript = IncrementalTranscript()
        liveLineCount = 0
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
            results.set(Self.statusOnly(result), for: id)
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
        var fresh = TranscriptAppendCursor(path: path, offset: build.endOffset) { path, offset in
            TranscriptAppendCursor.diskTailWindow(path: path, endingAt: offset)
        }
        // The first step reads without checking the file, so take it now,
        // while the page is fresh: a rewrite before the next step is then a
        // reset rather than a splice. A fresh cursor never resets, and what
        // it reads waits for the next step.
        if case .appended(let lines) = fresh.step(path: path), !lines.isEmpty {
            heldLines = (lines: lines, start: build.endOffset)
        }
        cursor = fresh
        return phonePage(build, generation: generation)
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
                // The pager reads any `uuid` that is not a string as none.
                if !(json["uuid"] is String) {
                    let id = exact ? "at-\(lineOffset)" : "line-\(liveLineCount)"
                    if let stamped = Self.stamped(json, id: id) {
                        text = stamped
                    }
                }
            }
            if !line.isEmpty {
                liveLineCount += 1
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
            guard let result = transcript.toolResult(for: id).map(Self.statusOnly) else { continue }
            results.set(result, for: id)
            if let row = waitingCalls.remove(id) {
                updated.append(resolvedRow(row, result: result, path: path))
            }
        }
        if transcript.items.count >= liveItemLimit {
            setLiveTranscriptAside(ctx)
        }
        let appendEvents = Self.frames(appended, session: session, budget: PhoneFrameBudget.eventDataBytes)
            .map(TranscriptFeedEvent.append)
        let updateEvents = Self.frames(updated, session: session, budget: PhoneFrameBudget.eventDataBytes)
            .map(TranscriptFeedEvent.update)
        return appendEvents + updateEvents
    }

    /// Starts a fresh live transcript in place of the current one, whose
    /// rows the phone already holds. Its calls still `running`, shaped with
    /// `ctx`, join the calls waiting, so their results update them as they
    /// would have updated the live rows.
    private func setLiveTranscriptAside(_ ctx: ShapingContext) {
        for item in transcript.items {
            guard let row = TranscriptShaper.shape(item, ctx), row.toolStatus == TranscriptShaper.runningStatus else {
                continue
            }
            waitingCalls.set(row, for: row.id)
        }
        transcript = IncrementalTranscript()
    }

    /// `result` with only what shaping reads, its `isError`, so the results
    /// index holds no tool output.
    private static func statusOnly(_ result: ToolResult) -> ToolResult {
        ToolResult(text: "", truncatedTo: nil, isError: result.isError)
    }

    /// A waiting row that was `running`, with its result's status and, for
    /// a subagent, its item count.
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

    /// `json` with `"uuid": id`, encoded again, or nil when it does not
    /// encode.
    private static func stamped(_ json: [String: Any], id: String) -> String? {
        var copy = json
        copy["uuid"] = id
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
    /// replaced after the next read that finds the file again. A remote
    /// session's cache changes only through syncs, so it has no watcher.
    private func startWatcher() {
        guard case .local = source else { return }
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
    /// no longer names a line of the file. A remote session's page can load
    /// earlier history first (`remoteOlderPage`).
    func olderPage(cursor: String) async throws -> TranscriptPage {
        guard let path else { throw Self.staleCursor }
        switch source {
        case .local:
            let build = try TranscriptPager.olderPage(
                filePath: path, cursor: cursor, generation: generation, ctx: pageContext(path: path))
            return keep(build)
        case .remote(let follower):
            return try await remoteOlderPage(cursor: cursor, path: path, follower: follower)
        }
    }

    /// An older page of a remote cache: the page before `cursor`, and, when
    /// that page reaches the top of the cache with fewer than
    /// `olderPageMessages` messages while the last sync said earlier history
    /// can be loaded, one `remote.transcriptLoadEarlier`, after which the
    /// cursor is resolved again past what it prepended and the page built
    /// again. The page has reached the start only when it reaches the top of
    /// the cache and no earlier history can be loaded.
    ///
    /// - **A load that fails** leaves the cache as it was. The phone gets the
    ///   cache's page, whose cursor still asks for more, so it can try again;
    ///   with nothing in the cache to show, the load's error is the reply.
    /// - **A load that met a newer generation** fetched nothing: a sync
    ///   replaced the cache first. The feed starts over with reason
    ///   `generation`, and the cursor is stale.
    /// - **A load that reached the start**, or found the history expired,
    ///   ends the scroll: no later sync in this generation offers earlier
    ///   history again, and the page reaches the start.
    /// - **A prepend the feed cannot follow** starts the feed over with reason
    ///   `rewrite`, and the cursor is stale.
    /// - **A feed that started over or closed** while the load ran makes the
    ///   cursor stale.
    private func remoteOlderPage(
        cursor: String, path: String, follower: RemoteTranscriptFollower
    ) async throws -> TranscriptPage {
        let pageGeneration = generation
        let cached = try remoteBuild(cursor: cursor, path: path)
        guard needsEarlier(cached) else { return keep(cached) }
        let loaded: RemoteTranscriptLoadEarlierResult
        do {
            loaded = try await follower.loadEarlier()
        } catch {
            if error is CancellationError { throw error }
            Self.logger.error(
                "Phone transcript: loading earlier remote history failed: \(PhoneAppService.errorType(error), privacy: .public)")
            guard !closed, generation == pageGeneration, self.path == path else { throw Self.staleCursor }
            guard !cached.page.items.isEmpty else { throw error }
            return keep(cached)
        }
        guard !closed, generation == pageGeneration, self.path == path, var cache = remote else {
            throw Self.staleCursor
        }
        guard loaded.generation == cache.generation else {
            if loaded.generation > cache.generation {
                remote = RemoteCache(generation: loaded.generation, head: loaded.head, hasEarlier: false)
                pendingReset = Self.generationReason
                wakeups?.yield()
            }
            throw Self.staleCursor
        }
        if loaded.reachedStart || loaded.expired {
            cache.earlierEnded = true
            cache.hasEarlier = false
        }
        let prepended = loaded.head > cache.head
        cache.head = max(cache.head, loaded.head)
        remote = cache
        if prepended, rebaseCursor() == nil {
            pendingReset = Self.rewriteReason
            wakeups?.yield()
            throw Self.staleCursor
        }
        let rebuilt = try remoteBuild(cursor: cursor, path: path)
        return keep(rebuilt)
    }

    /// The page before `cursor` in the remote cache at `path`, or
    /// `stale_cursor` when the cursor names no line of it.
    private func remoteBuild(cursor: String, path: String) throws -> PageBuild {
        guard let offset = TranscriptPager.resolveCursor(cursor, generation: generation, filePath: path),
              let build = TranscriptPager.olderPage(
                filePath: path, before: offset, generation: generation, ctx: pageContext(path: path)) else {
            throw Self.staleCursor
        }
        return build
    }

    /// Whether a remote page needs earlier history loaded: it reaches the top
    /// of the cache, the last sync said earlier history can be loaded, and it
    /// holds fewer than `olderPageMessages` messages.
    private func needsEarlier(_ build: PageBuild) -> Bool {
        guard build.startOffset == 0, remote?.hasEarlier == true else { return false }
        let messages = build.page.items.filter { Self.messageKinds.contains($0.kind) }.count
        return messages < PhoneAppConstants.olderPageMessages
    }

    /// How an older page is shaped: with the results the feed keeps.
    private func pageContext(path: String) -> ShapingContext {
        ShapingContext(
            showDetails: showDetails, joinedResults: results.dictionary, subagentItemCount: subagentCount(path: path))
    }

    /// Keeps an older page's results, its rows' offsets, its calls still
    /// `running` and its subagent IDs, and returns the page as the phone gets
    /// it.
    private func keep(_ build: PageBuild) -> TranscriptPage {
        for (id, result) in build.results {
            results.set(Self.statusOnly(result), for: id)
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
        return phonePage(build, generation: generation)
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

    /// Every value replaced by `transform` of it, each keeping its place.
    mutating func mapValues(_ transform: (Value) -> Value) {
        entries = entries.mapValues { Entry(stamp: $0.stamp, value: transform($0.value)) }
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
