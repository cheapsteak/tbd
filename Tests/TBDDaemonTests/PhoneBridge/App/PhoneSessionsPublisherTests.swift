import Foundation
import TBDShared
import Testing
import TestSupport

@testable import TBDDaemonLib

/// Tier 1: the sessions publisher over canned snapshots and a virtual clock,
/// and `sessions.subscribe` through the service over an in-memory database
/// with fake session actions. Nothing touches the disk or the network.
@Suite("Phone sessions publisher", .clockDriven)
struct PhoneSessionsPublisherTests {
    // MARK: - Fixtures

    /// Seven UTF-8 bytes that grow to thirteen once escaped: a two-byte
    /// letter, a quote, a control character and a three-byte letter.
    private static let unit = "é\"\u{1}名"
    /// A field at `PhoneText.fieldLimit`, the most the builder keeps.
    private static let longText = PhoneText.capped(String(repeating: unit, count: 40))

    /// The snapshot `gather` returns, which a test changes between windows.
    private final class SnapshotBox: @unchecked Sendable {
        private let lock = NSLock()
        private var snapshot: PhoneSnapshot

        init(_ snapshot: PhoneSnapshot) {
            self.snapshot = snapshot
        }

        var value: PhoneSnapshot {
            get { lock.withLock { snapshot } }
            set { lock.withLock { snapshot = newValue } }
        }
    }

    private struct Publisher {
        let publisher: PhoneSessionsPublisher
        let gathered: SnapshotBox
        /// One entry per gather, recorded once it has read the box.
        let gathers: FireRecorder<Int>
        let emitted: FireRecorder<SessionsChangedData>
        let subscriptions: StateSubscriptionManager
        let clock: EventDrivenTestClock
    }

    /// A publisher whose gather returns what `gathered` holds, and whose
    /// emits land in `emitted`.
    private static func makePublisher(gathering snapshot: PhoneSnapshot) -> Publisher {
        let gathered = SnapshotBox(snapshot)
        let gathers = FireRecorder<Int>()
        let emitted = FireRecorder<SessionsChangedData>()
        let subscriptions = StateSubscriptionManager()
        let clock = EventDrivenTestClock()
        let publisher = PhoneSessionsPublisher(
            gather: {
                let value = gathered.value
                gathers.record(1)
                return value
            },
            emit: { emitted.record($0) },
            subscriptions: subscriptions,
            clock: clock)
        return Publisher(
            publisher: publisher, gathered: gathered, gathers: gathers, emitted: emitted,
            subscriptions: subscriptions, clock: clock)
    }

    private static func session(_ terminalID: UUID, _ chip: PhoneStatusChip, at changedAt: Int64) -> PhoneSession {
        let available = PhoneCapability(available: true, reason: nil)
        return PhoneSession(
            ref: .local(terminalID: terminalID), agent: .claude, tabName: "Claude",
            status: PhoneStatus(chip: chip, changedAt: changedAt, reason: nil, untilAt: nil),
            profileName: nil, profileID: nil, model: nil,
            capabilities: PhoneCapabilities(
                transcript: available, send: available, answer: available,
                switchProfile: available, fork: available, model: available),
            openPromptID: nil)
    }

    private static func row(_ id: String, name: String = "acme", sessions: [PhoneSession] = []) -> PhoneRow {
        PhoneRow(
            id: id, kind: "worktree", name: name, remote: false,
            statusChangedAt: sessions.map { $0.status.changedAt }.max() ?? 0, sessions: sessions)
    }

    /// One repo group holding `rows` in order, at depth 0.
    private static func snapshot(_ rows: [PhoneRow], groupName: String = "acme") -> PhoneSnapshot {
        let placements = rows.map { PhoneRowPlacement(id: $0.id, depth: 0) }
        return PhoneSnapshot(
            layout: [PhoneGroupLayout(id: "repo:acme", kind: "repo", name: groupName, rows: placements)],
            rows: rows, omittedRows: 0)
    }

    /// A row whose every text field is at the field limit, with one session
    /// whose six capabilities each carry a reason at the limit too.
    private static func bigRow(_ index: Int) -> PhoneRow {
        let unavailable = PhoneCapability(available: false, reason: longText)
        let session = PhoneSession(
            ref: .local(terminalID: UUID()), agent: .claude, tabName: longText,
            status: PhoneStatus(chip: .rateLimited, changedAt: Int64.max, reason: longText, untilAt: Int64.max),
            profileName: longText, profileID: UUID(), model: longText,
            capabilities: PhoneCapabilities(
                transcript: unavailable, send: unavailable, answer: unavailable,
                switchProfile: unavailable, fork: unavailable, model: unavailable),
            openPromptID: longText)
        return PhoneRow(
            id: "\(index)-\(UUID().uuidString)", kind: "worktree", name: longText, remote: false,
            statusChangedAt: Int64.max, sessions: [session])
    }

    private static func bigLayout(_ rows: [PhoneRow]) -> [PhoneGroupLayout] {
        let placements = rows.map { PhoneRowPlacement(id: $0.id, depth: 3) }
        return [PhoneGroupLayout(id: "repo:acme", kind: "repo", name: longText, rows: placements)]
    }

    // MARK: - Publishing

    /// Two deltas inside one window make one gather and one change, sent
    /// when the window ends.
    @Test func aDeltaPublishesOneDebouncedChange() async throws {
        let w = UUID()
        let terminalID = UUID()
        let before = Self.snapshot([Self.row("\(w)", sessions: [Self.session(terminalID, .idle, at: 1_000)])])
        let after = Self.snapshot([Self.row("\(w)", sessions: [Self.session(terminalID, .working, at: 2_000)])])
        let p = Self.makePublisher(gathering: before)
        await p.publisher.start(baseline: before)

        // The window opened at start, which finds nothing new.
        try await p.clock.requireAdvanceWhenArmed(by: .milliseconds(500))
        _ = await p.gathers.next()

        p.gathered.value = after
        p.subscriptions.broadcast(delta: .modelProfilesChanged)
        p.subscriptions.broadcast(delta: .remoteSessionsChanged)
        try await p.clock.requireAdvanceWhenArmed(by: .milliseconds(500))

        let change = try #require(await p.emitted.next())
        let ids = change.rows.map { $0.id }
        #expect(ids == ["\(w)"])
        #expect(change.layout == nil)
        #expect(change.removedRowIDs.isEmpty)
        #expect(p.emitted.values.count == 1)
        #expect(p.gathers.values.count == 2)
        await p.publisher.stop()
    }

    /// A gather that finds only a session's time moved, with the same chip,
    /// sends nothing: the next change the phone gets is a real one, against
    /// the `changedAt` it already had.
    @Test func anUnchangedGatherPublishesNothing() async throws {
        let w = UUID()
        let terminalID = UUID()
        let baseline = Self.snapshot([Self.row("\(w)", sessions: [Self.session(terminalID, .rateLimited, at: 1_000)])])
        let restamped = Self.snapshot([Self.row("\(w)", sessions: [Self.session(terminalID, .rateLimited, at: 9_000)])])
        let p = Self.makePublisher(gathering: restamped)
        await p.publisher.start(baseline: baseline)

        // The window opened at start gathers the restamped list.
        try await p.clock.requireAdvanceWhenArmed(by: .milliseconds(500))
        _ = await p.gathers.next()

        let working = Self.snapshot([Self.row("\(w)", sessions: [Self.session(terminalID, .working, at: 12_000)])])
        p.gathered.value = working
        p.subscriptions.broadcast(delta: .modelProfilesChanged)
        try await p.clock.requireAdvanceWhenArmed(by: .milliseconds(500))

        // Emits run in order, so a change from the first window would come
        // first.
        let change = try #require(await p.emitted.next())
        #expect(change.rows == working.rows)
        #expect(p.emitted.values.count == 1)

        let steadied = PhoneSessionsPublisher.steadied(restamped, since: baseline)
        #expect(steadied == baseline)
        #expect(PhoneSessionsPublisher.diff(old: baseline, new: steadied) == nil)
        await p.publisher.stop()
    }

    @Test func aReorderSendsTheLayout() {
        let a = Self.row("acme-a")
        let b = Self.row("acme-b")
        let old = Self.snapshot([a, b])

        let reordered = Self.snapshot([b, a])
        let reorder = PhoneSessionsPublisher.diff(old: old, new: reordered)
        #expect(reorder == SessionsChangedData(layout: reordered.layout, rows: [], removedRowIDs: []))

        // A renamed repo changes only the layout.
        let renamed = Self.snapshot([a, b], groupName: "acme-renamed")
        #expect(PhoneSessionsPublisher.diff(old: old, new: renamed)?.layout == renamed.layout)

        // A changed row alone leaves the layout out.
        let changedA = Self.row("acme-a", name: "acme-a2")
        let edited = Self.snapshot([changedA, b])
        #expect(PhoneSessionsPublisher.diff(old: old, new: edited)
            == SessionsChangedData(layout: nil, rows: [changedA], removedRowIDs: []))

        // A row that is gone is named, and the group's rows changed.
        let shrunk = Self.snapshot([a])
        #expect(PhoneSessionsPublisher.diff(old: old, new: shrunk)
            == SessionsChangedData(layout: shrunk.layout, rows: [], removedRowIDs: ["acme-b"]))

        #expect(PhoneSessionsPublisher.diff(old: old, new: old) == nil)
    }

    @Test func stopRemovesTheSubscriberForGood() async throws {
        let empty = PhoneSnapshot(layout: [], rows: [], omittedRows: 0)
        let p = Self.makePublisher(gathering: empty)

        await p.publisher.start(baseline: empty)
        #expect(await p.publisher.isSubscribed)
        #expect(p.subscriptions.subscriberCount == 1)
        try await p.clock.requireSleeperArmed()

        await p.publisher.stop()
        #expect(await p.publisher.isSubscribed == false)
        #expect(p.subscriptions.subscriberCount == 0)
        try await waitUntil("the stopped publisher's window to be cancelled") {
            !p.clock.hasSleeper
        }

        await p.publisher.start(baseline: empty)
        #expect(await p.publisher.isSubscribed == false)
        #expect(p.subscriptions.subscriberCount == 0)
    }

    // MARK: - Frames

    /// 600 rows with every field at its limit, a layout naming them all and
    /// 100 long removals: every frame fits the budget as a whole event, the
    /// layout rides on the first frame only, and nothing is lost or reordered.
    @Test func framesEachFitTheBudget() throws {
        let rows = (0..<600).map { Self.bigRow($0) }
        let removals = (0..<100).map { "\($0)-\(Self.longText)" }
        let layout = Self.bigLayout(rows)
        let data = SessionsChangedData(layout: layout, rows: rows, removedRowIDs: removals)
        let budget = PhoneFrameBudget.eventDataBytes

        let frames = PhoneSessionsPublisher.frames(data, budget: budget)

        #expect(frames.count > 1)
        for frame in frames {
            let event = try PhoneAppCoding.event(.sessionsChanged, seq: Int.max, data: frame)
            #expect(event.count <= budget)
            #expect(PhoneAppCoding.framedSize(event) <= PhoneFrameBudget.maxPlaintext)
        }
        let first = try #require(frames.first)
        #expect(first.layout == layout)
        let laterLayouts = frames.dropFirst().compactMap { $0.layout }
        #expect(laterLayouts.isEmpty)
        let sentRows = frames.flatMap { $0.rows }
        #expect(sentRows == rows)
        let sentRemovals = frames.flatMap { $0.removedRowIDs }
        #expect(sentRemovals == removals)
    }

    @Test func anItemTooLargeForAFrameIsLeftOut() throws {
        let small = Self.row("acme-small")
        let big = Self.bigRow(0)
        let smallEvent = try PhoneAppCoding.event(
            .sessionsChanged, seq: Int.max, data: SessionsChangedData(layout: nil, rows: [small], removedRowIDs: []))
        // Room for the small row and not the big one.
        let budget = smallEvent.count

        let frames = PhoneSessionsPublisher.frames(
            SessionsChangedData(layout: nil, rows: [small, big, small], removedRowIDs: []), budget: budget)

        #expect(frames == [
            SessionsChangedData(layout: nil, rows: [small], removedRowIDs: []),
            SessionsChangedData(layout: nil, rows: [small], removedRowIDs: []),
        ])
    }

    /// The reply carries the layout and as many rows as fit, with `more`
    /// set; the rest follow as events. A small list fits whole.
    @Test func aLargeSnapshotReplyCarriesWhatFitsAndLeavesTheRest() throws {
        let rows = (0..<600).map { Self.bigRow($0) }
        let layout = Self.bigLayout(rows)
        let snapshot = PhoneSnapshot(layout: layout, rows: rows, omittedRows: 7)

        let parts = PhoneAppService.snapshotReply(snapshot, requestID: "acme-1", stream: "acme-stream", seq: 4)

        let reply = try #require(parts.reply)
        #expect(reply.count <= PhoneFrameBudget.eventDataBytes)
        #expect(PhoneAppCoding.framedSize(reply) <= PhoneFrameBudget.maxPlaintext)
        let result = try JSONDecoder().decode(PhoneReplyEnvelope<SessionsSubscribeResult>.self, from: reply).result
        let sent = try #require(result.rows)
        #expect(!sent.isEmpty)
        #expect(sent + parts.rest == rows)
        #expect(result.more)
        #expect(result.layout == layout)
        #expect(result.omittedRows == 7)
        #expect(result.replayed == false)
        #expect(result.stream == "acme-stream")
        #expect(result.seq == 4)

        let few = Array(rows.prefix(2))
        let whole = PhoneAppService.snapshotReply(
            PhoneSnapshot(layout: Self.bigLayout(few), rows: few, omittedRows: 0),
            requestID: "acme-2", stream: "acme-stream", seq: 4)
        #expect(whole.rest.isEmpty)
        let wholeReply = try #require(whole.reply)
        let wholeResult = try JSONDecoder().decode(PhoneReplyEnvelope<SessionsSubscribeResult>.self, from: wholeReply).result
        #expect(wholeResult.rows == few)
        #expect(wholeResult.more == false)
    }

    // MARK: - Gathering

    /// The gather reads the stored tab order and the tab labels of every
    /// worktree with an agent tab, and the snapshot orders and names that
    /// worktree's sessions by them.
    @Test func theGatherReadsEachWorktreesTabOrderAndLabels() async throws {
        let h = try await PhoneServiceHarness.make()
        let first = try await h.seedTerminal()
        let second = try await h.db.terminals.create(
            worktreeID: first.worktreeID, tmuxWindowID: "@2", tmuxPaneID: "%2",
            claudeSessionID: "acme-session-2", kind: .claude)
        let other = try await h.seedTerminal()
        try await h.db.worktrees.setTabOrder(worktreeID: first.worktreeID, tabIDs: [second.id, first.id])
        try await h.db.tabs.setLabel(tabID: second.id, worktreeID: first.worktreeID, label: "review")
        try await h.db.tabs.setLabel(tabID: other.id, worktreeID: other.worktreeID, label: "acme other")

        let snapshot = try await h.service.gatherSnapshot()

        let foundRow = snapshot.rows.first { $0.id == first.worktreeID.uuidString }
        let row = try #require(foundRow)
        let refs = row.sessions.map(\.ref)
        #expect(refs == [.local(terminalID: second.id), .local(terminalID: first.id)])
        #expect(row.sessions.first?.tabName == "review")
        let foundOther = snapshot.rows.first { $0.id == other.worktreeID.uuidString }
        let otherRow = try #require(foundOther)
        #expect(otherRow.sessions.first?.tabName == "acme other")
    }

    // MARK: - sessions.subscribe

    private static let fresh = SessionsSubscribeParams(stream: nil, sinceSeq: nil)

    private static func result(_ bytes: Data) throws -> SessionsSubscribeResult {
        try JSONDecoder().decode(PhoneReplyEnvelope<SessionsSubscribeResult>.self, from: bytes).result
    }

    /// A phone back inside the grace, naming its stream and the last `seq` it
    /// saw, gets `replayed: true` and the events it missed, in order, after
    /// the reply.
    @Test func subscribeWithAKnownStreamReplays() async throws {
        let h = try await PhoneServiceHarness.make()
        let deviceID = h.peer.deviceID
        let outbox = await h.connect()
        let (_, firstBytes) = try await h.request(.sessionsSubscribe, params: Self.fresh, on: outbox)
        let first = try Self.result(firstBytes)
        #expect(first.replayed == false)

        await h.service.phoneDisconnected(h.peer)
        let one = SessionsChangedData(layout: nil, rows: [], removedRowIDs: ["acme-1"])
        let two = SessionsChangedData(layout: nil, rows: [], removedRowIDs: ["acme-2"])
        await h.service.emit(.sessionsChanged, data: one, to: deviceID)
        await h.service.emit(.sessionsChanged, data: two, to: deviceID)
        let again = await h.connect()

        let (reply, bytes) = try await h.request(
            .sessionsSubscribe, params: SessionsSubscribeParams(stream: first.stream, sinceSeq: first.seq), on: again)

        #expect(reply.error == nil)
        let resumed = try Self.result(bytes)
        #expect(resumed.replayed)
        #expect(resumed.stream == first.stream)
        #expect(resumed.seq == first.seq + 2)
        #expect(resumed.layout == nil)
        #expect(resumed.rows == nil)
        let oneBytes = try PhoneAppCoding.event(.sessionsChanged, seq: first.seq + 1, data: one)
        let twoBytes = try PhoneAppCoding.event(.sessionsChanged, seq: first.seq + 2, data: two)
        #expect(try await again.body(at: 1) == oneBytes)
        #expect(try await again.body(at: 2) == twoBytes)
        #expect(await h.service.resumeDecision(for: deviceID) == .replay)
        await h.service.phoneRevoked(deviceID: deviceID)
    }

    /// A stream this laptop does not know gets a fresh snapshot with the
    /// laptop's own stream, and the connection's decision is a snapshot.
    @Test func subscribeWithAForeignStreamSnapshots() async throws {
        let h = try await PhoneServiceHarness.make()
        let deviceID = h.peer.deviceID
        let repo = try await h.db.repos.create(path: "/acme/widgets", displayName: "acme", defaultBranch: "main")
        let worktree = try await h.db.worktrees.create(
            repoID: repo.id, name: "acme-one", displayName: "Acme one", branch: "acme-one",
            path: "/acme/widgets-one", tmuxServer: "tbd-acme")
        let outbox = await h.connect()

        let (reply, bytes) = try await h.request(
            .sessionsSubscribe, params: SessionsSubscribeParams(stream: "acme-foreign", sinceSeq: 3), on: outbox)

        #expect(reply.error == nil)
        let result = try Self.result(bytes)
        let stream = await h.service.streamID(for: deviceID)
        #expect(result.stream == stream)
        #expect(result.replayed == false)
        #expect(result.seq == 0)
        #expect(result.more == false)
        #expect(result.omittedRows == 0)
        let layout = try #require(result.layout)
        let found = layout.first { $0.id == "repo:\(repo.id.uuidString)" }
        let group = try #require(found)
        #expect(group.name == "acme")
        let placed = group.rows.map { $0.id }
        #expect(placed == [worktree.id.uuidString])
        let rowIDs = (result.rows ?? []).map { $0.id }
        #expect(rowIDs.contains(worktree.id.uuidString))
        #expect(await h.service.resumeDecision(for: deviceID) == .snapshot)
        let publisher = await h.service.sessionsPublisher(for: deviceID)
        #expect(publisher != nil)
        await h.service.phoneRevoked(deviceID: deviceID)
    }

    /// A stream the laptop knows, on a state with no publisher yet, still
    /// gets a snapshot: there is nothing to carry the list on.
    @Test func aReplayWithNoPublisherSnapshots() async throws {
        let h = try await PhoneServiceHarness.make()
        let deviceID = h.peer.deviceID
        let outbox = await h.connect()
        let stream = try #require(await h.service.streamID(for: deviceID))

        let (reply, bytes) = try await h.request(
            .sessionsSubscribe, params: SessionsSubscribeParams(stream: stream, sinceSeq: 0), on: outbox)

        #expect(reply.error == nil)
        let result = try Self.result(bytes)
        #expect(result.replayed == false)
        #expect(result.layout != nil)
        #expect(await h.service.resumeDecision(for: deviceID) == .snapshot)
        await h.service.phoneRevoked(deviceID: deviceID)
    }

    /// The publisher keeps the list current while the phone is away: what it
    /// finds is numbered and kept, and the resume replays it.
    @Test func aChangeWhileAwayIsKeptAndReplayed() async throws {
        let h = try await PhoneServiceHarness.make()
        let deviceID = h.peer.deviceID
        let outbox = await h.connect()
        let (_, firstBytes) = try await h.request(.sessionsSubscribe, params: Self.fresh, on: outbox)
        let first = try Self.result(firstBytes)
        #expect(first.layout == [])
        // The publisher's first window.
        try await h.clock.requireSleeperArmed()

        await h.service.phoneDisconnected(h.peer)
        let repo = try await h.db.repos.create(path: "/acme/widgets", displayName: "acme", defaultBranch: "main")
        await h.clock.advance(by: .milliseconds(500))
        try await waitUntil("the change to be kept") {
            await h.service.lastSeq(for: deviceID) == first.seq + 1
        }
        #expect(outbox.bodies.count == 1)

        let again = await h.connect()
        let (_, bytes) = try await h.request(
            .sessionsSubscribe, params: SessionsSubscribeParams(stream: first.stream, sinceSeq: first.seq), on: again)

        let resumed = try Self.result(bytes)
        #expect(resumed.replayed)
        #expect(resumed.seq == first.seq + 1)
        let eventBytes = try await again.body(at: 1)
        let event = try JSONDecoder().decode(PhoneEventEnvelope<SessionsChangedData>.self, from: eventBytes)
        #expect(event.event == PhoneAppEventName.sessionsChanged.rawValue)
        #expect(event.seq == first.seq + 1)
        let groupIDs = (event.data.layout ?? []).map { $0.id }
        #expect(groupIDs == ["repo:\(repo.id.uuidString)"])
        await h.service.phoneRevoked(deviceID: deviceID)
    }

    /// A second `sessions.subscribe` on the connection replaces the publisher
    /// and leaves one subscriber; a revoke removes that one too.
    @Test func aSecondSubscribeRestartsThePublisher() async throws {
        let h = try await PhoneServiceHarness.make()
        let deviceID = h.peer.deviceID
        let outbox = await h.connect()

        _ = try await h.request(.sessionsSubscribe, params: Self.fresh, on: outbox)
        let first = try #require(await h.service.sessionsPublisher(for: deviceID))
        _ = try await h.request(.sessionsSubscribe, params: Self.fresh, on: outbox)
        let second = try #require(await h.service.sessionsPublisher(for: deviceID))

        #expect(first !== second)
        try await waitUntil("the first publisher to stop and the second to subscribe") {
            let firstSubscribed = await first.isSubscribed
            let secondSubscribed = await second.isSubscribed
            return !firstSubscribed && secondSubscribed
        }
        #expect(h.subscriptions.subscriberCount == 1)

        await h.service.phoneRevoked(deviceID: deviceID)
        #expect(await second.isSubscribed == false)
        #expect(h.subscriptions.subscriberCount == 0)
    }
}
