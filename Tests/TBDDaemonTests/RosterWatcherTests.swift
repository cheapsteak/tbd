import Clocks
import Foundation
import Testing

import TestSupport

@testable import TBDDaemonLib
@testable import TBDShared

/// The local roster — the outbound half of remote peer messaging
/// (`docs/specs/2026-08-29-remote-peer-messaging-design.md` § "The local
/// roster").
///
/// **Nothing here goes near `~/.claude`.** Every `RosterWatcher` is constructed
/// with an explicit registry directory under `FileManager.temporaryDirectory`,
/// which is the only way to construct one: the type has no initializer that
/// resolves a path and no static helper that builds one out of `$HOME`, so a
/// test cannot reach the developer's real registry by forgetting to inject
/// something. Process liveness is injected too — no test signals, probes or
/// depends on a real pid.

// MARK: - Fixtures

/// The `procStart` a live pid reports in these tests. Its exact shape is
/// `ctime(3)`'s, the one `ProcessStartTime.format` produces.
private let liveProcStart = "Sat Aug 29 22:07:57 2026"

private let repoA = UUID()
private let repoB = UUID()

private func spawnedSession(
    repoID: UUID = repoA,
    displayName: String = "useful-swallow",
    worktreePath: String = "/tmp/tbd-roster-fixture/useful-swallow",
    pane: String = "%3541",
    claudeSessionID: String? = "4E12DD65-92B8-4D8E-9920-214C6553FC63"
) -> TBDSpawnedSession {
    TBDSpawnedSession(
        worktreeID: UUID(),
        repoID: repoID,
        terminalID: UUID(),
        displayName: displayName,
        worktreePath: worktreePath,
        tmuxPaneID: pane,
        claudeSessionID: claudeSessionID)
}

/// One registry record, as a dictionary, so a test can leave a key out the way
/// a real registry does. The census in
/// `docs/research/2026-08-29-cross-machine-messaging/findings.md` found
/// `status` on 83 of 84 records, `version` on 83, `tmux` on 80 and `pidDomain`
/// on 63 — absence is ordinary here, not damage.
private func registryRecord(
    sessionID: String? = "4E12DD65-92B8-4D8E-9920-214C6553FC63",
    cwd: String? = "/tmp/tbd-roster-fixture/useful-swallow",
    socket: String? = "/tmp/cc-socks/4242.sock",
    peerProtocol: Int? = 1,
    status: String? = "busy",
    tmux: String? = "main:@3541.%3541",
    procStart: String? = liveProcStart,
    version: String? = "2.1.251"
) -> [String: Any] {
    var fields: [String: Any] = [
        "startedAt": 1_788_041_297_648,
        "peerFeatures": ["notify_idle"],
        "kind": "interactive",
        "entrypoint": "cli",
        "name": "useful-swallow",
        "nameSince": 1_788_041_297_648,
    ]
    if let sessionID { fields["sessionId"] = sessionID }
    if let cwd { fields["cwd"] = cwd }
    if let socket { fields["messagingSocketPath"] = socket }
    if let peerProtocol { fields["peerProtocol"] = peerProtocol }
    if let status { fields["status"] = status }
    if let tmux { fields["tmux"] = tmux }
    if let procStart { fields["procStart"] = procStart }
    if let version { fields["version"] = version }
    return fields
}

private func write(_ fields: [String: Any], pid: pid_t, in directory: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    try data.write(to: directory.appendingPathComponent("\(pid).json"))
}

private func remove(pid: pid_t, in directory: URL) throws {
    try FileManager.default.removeItem(at: directory.appendingPathComponent("\(pid).json"))
}

private func withRegistry(_ body: (URL) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("tbd-roster-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory)
}

/// TBD's own bookkeeping, injected. An actor because two tests change what TBD
/// knows between scans.
private actor FakeSessionDirectory: LocalSessionDirectory {
    private var sessions: [TBDSpawnedSession]

    init(_ sessions: [TBDSpawnedSession]) {
        self.sessions = sessions
    }

    func spawnedSessions() async -> [TBDSpawnedSession] { sessions }
}

/// Everything one link was told, in order.
private actor FrameSink {
    private(set) var frames: [PeerBridgeFrame] = []

    func append(_ frame: PeerBridgeFrame) { frames.append(frame) }

    /// Drain, so a test can assert on "what the second scan sent" rather than
    /// on a growing transcript.
    func drain() -> [PeerBridgeFrame] {
        defer { frames = [] }
        return frames
    }
}

private func link(
    repoID: UUID = repoA,
    peerProtocol: Int = 1,
    handles: any LocalPeerHandleRegistry = MemoizingLocalPeerHandleRegistry(),
    sink: FrameSink
) -> RosterLinkRegistration {
    RosterLinkRegistration(
        id: UUID(), repoID: repoID, peerProtocol: peerProtocol, handles: handles
    ) { frame in
        await sink.append(frame)
    }
}

private func peers(_ frames: [PeerBridgeFrame]) -> [PeerBridgePeer] {
    frames.compactMap { frame -> PeerBridgePeer? in
        guard case .peer(let peer) = frame else { return nil }
        return peer
    }
}

private func goneHandles(_ frames: [PeerBridgeFrame]) -> [String] {
    frames.compactMap { frame -> String? in
        guard case .peerGone(let handle) = frame else { return nil }
        return handle
    }
}

/// A watcher wired for a test: an explicit directory, injected bookkeeping, and
/// a pid liveness function that answers for `livePIDs` and nothing else.
private func watcher(
    directory: URL,
    sessions: FakeSessionDirectory,
    origin: String = "laptop",
    livePIDs: [pid_t: String] = [4242: liveProcStart, 4343: liveProcStart],
    clock: any Clock<Duration> = ContinuousClock()
) -> RosterWatcher {
    RosterWatcher(
        sessionsDirectory: directory,
        sessions: sessions,
        origin: origin,
        interval: .seconds(2),
        procStartForPID: { livePIDs[$0] },
        clock: clock)
}

// MARK: - Appearing, changing, going

@Suite("Roster watcher — announcements")
struct RosterWatcherAnnouncementTests {
    /// A session appearing produces a `peer` line, complete rather than
    /// partial, named `<origin>:<display name> %<pane>` with the pane
    /// discriminator always present.
    @Test func aSessionAppearingIsAnnouncedAsAPeer() async throws {
        try await withRegistry { directory in
            try write(registryRecord(), pid: 4242, in: directory)
            let sink = FrameSink()
            let subject = watcher(
                directory: directory, sessions: FakeSessionDirectory([spawnedSession()]))
            await subject.addLink(link(sink: sink))

            let announced = peers(await sink.drain())
            #expect(announced.count == 1)
            let peer = try #require(announced.first)
            #expect(peer.name == "laptop:useful-swallow %3541")
            #expect(peer.status == "busy")
            #expect(peer.peerProtocol == 1)
        }
    }

    /// The handle is opaque, and the socket path stays in the registry that
    /// minted it — which in production is the same table that resolves an
    /// inbound frame, so this is the boundary rather than a lookup.
    @Test func theAnnouncedHandleIsNotASocketPath() async throws {
        try await withRegistry { directory in
            try write(registryRecord(), pid: 4242, in: directory)
            let sink = FrameSink()
            let handles = MemoizingLocalPeerHandleRegistry()
            let subject = watcher(
                directory: directory, sessions: FakeSessionDirectory([spawnedSession()]))
            await subject.addLink(link(handles: handles, sink: sink))

            let peer = try #require(peers(await sink.drain()).first)
            #expect(!peer.handle.contains("/"))
            #expect(!peer.handle.contains(".sock"))
            #expect(await handles.socketPath(forHandle: peer.handle) == "/tmp/cc-socks/4242.sock")
            #expect(await handles.socketPath(forHandle: "handle-nobody-minted") == nil)
        }
    }

    /// A session exiting produces `peer-gone` for the handle it was announced
    /// under.
    @Test func aSessionExitingIsAnnouncedGone() async throws {
        try await withRegistry { directory in
            try write(registryRecord(), pid: 4242, in: directory)
            let sink = FrameSink()
            let handles = MemoizingLocalPeerHandleRegistry()
            let subject = watcher(
                directory: directory, sessions: FakeSessionDirectory([spawnedSession()]))
            await subject.addLink(link(handles: handles, sink: sink))
            let handle = try #require(peers(await sink.drain()).first?.handle)

            try remove(pid: 4242, in: directory)
            await subject.refresh()

            #expect(goneHandles(await sink.drain()) == [handle])
            // The handle is withdrawn from the table too, so a frame still
            // addressed to it resolves to nothing rather than to a dead socket.
            #expect(await handles.socketPath(forHandle: handle) == nil)
            #expect(await subject.currentEntries().isEmpty)
        }
    }

    /// A status change produces an updated `peer` under the **same** handle —
    /// not a gone-then-new pair, which would republish the session under a new
    /// identity every time it went from idle to busy.
    @Test func aStatusChangeReannouncesTheSamePeer() async throws {
        try await withRegistry { directory in
            try write(registryRecord(status: "busy"), pid: 4242, in: directory)
            let sink = FrameSink()
            let subject = watcher(
                directory: directory, sessions: FakeSessionDirectory([spawnedSession()]))
            await subject.addLink(link(sink: sink))
            let first = try #require(peers(await sink.drain()).first)

            try write(registryRecord(status: "idle"), pid: 4242, in: directory)
            await subject.refresh()

            let frames = await sink.drain()
            #expect(goneHandles(frames).isEmpty)
            let second = try #require(peers(frames).first)
            #expect(second.handle == first.handle)
            #expect(second.status == "idle")
        }
    }

    /// A scan that changes nothing says nothing. `peer` is idempotent, so a
    /// watcher that re-announced every tick would be correct and useless.
    @Test func anUnchangedRosterIsNotReannounced() async throws {
        try await withRegistry { directory in
            try write(registryRecord(), pid: 4242, in: directory)
            let sink = FrameSink()
            let subject = watcher(
                directory: directory, sessions: FakeSessionDirectory([spawnedSession()]))
            await subject.addLink(link(sink: sink))
            #expect(await sink.drain().count == 1)

            await subject.refresh()
            #expect(await sink.drain().isEmpty)
        }
    }

    /// A link registered after the roster already exists is told the whole
    /// roster, which is the design's resync rule: the far side unlinks every
    /// shadow when a stream ends, so a fresh `hello` re-announces from scratch.
    @Test func aLinkRegisteredLaterIsAnnouncedTheWholeRoster() async throws {
        try await withRegistry { directory in
            try write(registryRecord(), pid: 4242, in: directory)
            let subject = watcher(
                directory: directory, sessions: FakeSessionDirectory([spawnedSession()]))
            await subject.refresh()

            let sink = FrameSink()
            await subject.addLink(link(sink: sink))
            #expect(peers(await sink.drain()).count == 1)
        }
    }
}

// MARK: - Scoping

@Suite("Roster watcher — scoping")
struct RosterWatcherScopingTests {
    /// Only TBD-spawned sessions are mirrored — never a plain-terminal
    /// `claude`, never another profile's. The record here is a perfectly valid
    /// live session that TBD's own bookkeeping does not know: no captured
    /// session id matches it, and neither its `cwd` nor its pane joins.
    @Test func aSessionTBDDidNotSpawnIsNeverAnnounced() async throws {
        try await withRegistry { directory in
            try write(
                registryRecord(
                    sessionID: "AAAAAAAA-0000-0000-0000-000000000000",
                    cwd: "/Users/somebody/personal-project",
                    tmux: "main:@7.%7"),
                pid: 4242, in: directory)
            let sink = FrameSink()
            let subject = watcher(
                directory: directory, sessions: FakeSessionDirectory([spawnedSession()]))
            await subject.addLink(link(sink: sink))

            #expect(await sink.drain().isEmpty)
            #expect(await subject.lastScanReport().skippedNotTBDSpawned == 1)
            #expect(await subject.lastScanReport().admitted == 0)
        }
    }

    /// A session is announced only to a link whose remote session resolves to
    /// the same repository. Both scoping rules are enforced at the point of
    /// announcement, so this is the place to assert it.
    @Test func aSessionInAnotherRepoIsNotAnnouncedToThisLink() async throws {
        try await withRegistry { directory in
            try write(registryRecord(), pid: 4242, in: directory)
            try write(
                registryRecord(
                    sessionID: "BBBBBBBB-0000-0000-0000-000000000000",
                    cwd: "/tmp/tbd-roster-fixture/other-repo-worktree",
                    socket: "/tmp/cc-socks/4343.sock",
                    tmux: "main:@99.%99"),
                pid: 4343, in: directory)

            let sessions = FakeSessionDirectory([
                spawnedSession(),
                spawnedSession(
                    repoID: repoB,
                    displayName: "other-repo-worktree",
                    worktreePath: "/tmp/tbd-roster-fixture/other-repo-worktree",
                    pane: "%99",
                    claudeSessionID: "BBBBBBBB-0000-0000-0000-000000000000"),
            ])
            let sink = FrameSink()
            let subject = watcher(directory: directory, sessions: sessions)
            await subject.addLink(link(repoID: repoA, sink: sink))

            let announced = peers(await sink.drain())
            #expect(announced.map(\.name) == ["laptop:useful-swallow %3541"])
            // Both sessions are on the roster; only one is on this link.
            #expect(await subject.currentEntries().count == 2)
        }
    }

    /// A session speaking a protocol the link did not negotiate is not
    /// announced on it: the far side would publish a shadow it could not talk
    /// to.
    @Test func aSessionOnAnotherPeerProtocolIsNotAnnounced() async throws {
        try await withRegistry { directory in
            try write(registryRecord(peerProtocol: 2), pid: 4242, in: directory)
            let sink = FrameSink()
            let subject = watcher(
                directory: directory, sessions: FakeSessionDirectory([spawnedSession()]))
            await subject.addLink(link(peerProtocol: 1, sink: sink))

            #expect(await sink.drain().isEmpty)
        }
    }

    /// The second join: a session whose `SessionStart` hook never gave TBD a
    /// session id is still recognisable from its worktree directory **and** its
    /// pane. Both halves are required — the pane alone is unique only within
    /// one tmux server, and TBD runs one per repository beside whatever servers
    /// the user runs.
    @Test func theCWDAndPaneJoinAdmitsASessionWithNoCapturedSessionID() async throws {
        try await withRegistry { directory in
            try write(registryRecord(), pid: 4242, in: directory)
            let sessions = FakeSessionDirectory([spawnedSession(claudeSessionID: nil)])
            let sink = FrameSink()
            let subject = watcher(directory: directory, sessions: sessions)
            await subject.addLink(link(sink: sink))

            #expect(peers(await sink.drain()).map(\.name) == ["laptop:useful-swallow %3541"])
        }
    }

    /// The same worktree, a different pane: the record describes a session in a
    /// directory TBD manages that is not one of TBD's terminals. Not announced.
    @Test func aMatchingCWDWithAForeignPaneIsNotAnnounced() async throws {
        try await withRegistry { directory in
            try write(registryRecord(tmux: "main:@8888.%8888"), pid: 4242, in: directory)
            let sessions = FakeSessionDirectory([spawnedSession(claudeSessionID: nil)])
            let sink = FrameSink()
            let subject = watcher(directory: directory, sessions: sessions)
            await subject.addLink(link(sink: sink))

            #expect(await sink.drain().isEmpty)
            #expect(await subject.lastScanReport().skippedNotTBDSpawned == 1)
        }
    }
}

// MARK: - A registry is somebody else's format

@Suite("Roster watcher — tolerating the registry")
struct RosterWatcherToleranceTests {
    /// A record missing the keys that are not universal — `status`, `version`,
    /// `tmux`, `pidDomain` — is handled, not dropped and not fatal. The session
    /// is announced, with a status word that is deliberately outside Claude
    /// Code's own vocabulary so it reads as "nobody said" rather than as a
    /// fact.
    @Test func aRecordMissingNonUniversalKeysIsStillAnnounced() async throws {
        try await withRegistry { directory in
            try write(
                registryRecord(status: nil, tmux: nil, version: nil), pid: 4242, in: directory)
            let sink = FrameSink()
            let subject = watcher(
                directory: directory, sessions: FakeSessionDirectory([spawnedSession()]))
            await subject.addLink(link(sink: sink))

            let peer = try #require(peers(await sink.drain()).first)
            #expect(peer.status == LocalPeerRegistryRecord.unknownStatus)
            #expect(peer.status != "idle")
            #expect(peer.name == "laptop:useful-swallow %3541")
        }
    }

    /// A malformed record is skipped, counted, and does not take the scan down
    /// with it: the good record beside it is announced in the same pass.
    @Test func aMalformedRecordIsSkippedWithoutKillingTheScan() async throws {
        try await withRegistry { directory in
            try write(registryRecord(), pid: 4242, in: directory)
            try Data("{ this is not json".utf8)
                .write(to: directory.appendingPathComponent("4343.json"))

            let sink = FrameSink()
            let subject = watcher(
                directory: directory, sessions: FakeSessionDirectory([spawnedSession()]))
            await subject.addLink(link(sink: sink))

            #expect(peers(await sink.drain()).count == 1)
            let report = await subject.lastScanReport()
            #expect(report.skippedMalformed == 1)
            #expect(report.admitted == 1)
            #expect(report.recordsSeen == 2)
            #expect(report.isDegraded)
        }
    }

    /// A record with no socket path or no peer protocol cannot be announced —
    /// there is nothing to address it by and no protocol to claim for it — so
    /// it is counted as incomplete rather than guessed at.
    @Test func aRecordWithNoSocketOrProtocolIsCountedIncomplete() async throws {
        try await withRegistry { directory in
            try write(registryRecord(socket: nil), pid: 4242, in: directory)
            try write(
                registryRecord(sessionID: "CCCCCCCC-0000-0000-0000-000000000000",
                               socket: "/tmp/cc-socks/4343.sock",
                               peerProtocol: nil),
                pid: 4343, in: directory)

            let sink = FrameSink()
            let subject = watcher(
                directory: directory, sessions: FakeSessionDirectory([spawnedSession()]))
            await subject.addLink(link(sink: sink))

            #expect(await sink.drain().isEmpty)
            #expect(await subject.lastScanReport().skippedIncomplete == 2)
        }
    }

    /// Files that are not records are not records: the per-peer token file
    /// (`<pid>.<sha256>.key`), a write-temp, and a name that does not
    /// round-trip as an integer are all invisible to the scan — which is
    /// Claude Code's own loader rule, not a list of things to exclude.
    @Test func nonRecordFilesAreNotCountedAsRecords() async throws {
        try await withRegistry { directory in
            try write(registryRecord(), pid: 4242, in: directory)
            for name in ["4242.abc123.key", ".4242.json.tmp", "0042.json", "notes.json"] {
                try Data("{}".utf8).write(to: directory.appendingPathComponent(name))
            }

            let subject = watcher(
                directory: directory, sessions: FakeSessionDirectory([spawnedSession()]))
            await subject.refresh()

            let report = await subject.lastScanReport()
            #expect(report.recordsSeen == 1)
            #expect(report.skippedMalformed == 0)
        }
    }

    /// A registry directory that cannot be listed is a **partial roster**, not
    /// an error: the profile-unification TBD does is best-effort, and a machine
    /// where no session has ever run has no such directory at all. It is
    /// reported and the scan returns.
    @Test func anAbsentRegistryDirectoryIsReportedNotThrown() async throws {
        try await withRegistry { directory in
            let missing = directory.appendingPathComponent("never-created", isDirectory: true)
            let sink = FrameSink()
            let subject = watcher(
                directory: missing, sessions: FakeSessionDirectory([spawnedSession()]))
            await subject.addLink(link(sink: sink))

            #expect(await sink.drain().isEmpty)
            let report = await subject.lastScanReport()
            #expect(report.directoryUnreadable)
            #expect(report.recordsSeen == 0)
            #expect(report.isDegraded)
        }
    }
}

// MARK: - Liveness

@Suite("Roster watcher — liveness")
struct RosterWatcherLivenessTests {
    /// A record under a dead pid is not announced. Claude Code's reaper deletes
    /// these, but only when something runs `ListAgents`, so the roster cannot
    /// treat "the file is there" as "the session is alive".
    @Test func aRecordUnderADeadPIDIsNotAnnounced() async throws {
        try await withRegistry { directory in
            try write(registryRecord(), pid: 4242, in: directory)
            let sink = FrameSink()
            let subject = watcher(
                directory: directory,
                sessions: FakeSessionDirectory([spawnedSession()]),
                livePIDs: [:])
            await subject.addLink(link(sink: sink))

            #expect(await sink.drain().isEmpty)
            #expect(await subject.lastScanReport().skippedNotLive == 1)
        }
    }

    /// The recycled-pid ghost: the pid is alive, but it is a different process
    /// than the one that wrote the record. Claude Code's reaper checks pid
    /// liveness and nothing else — measured — so this record can sit there
    /// forever, and announcing it would publish a shadow pointing at a stranger.
    @Test func aRecycledPIDGhostIsNotAnnounced() async throws {
        try await withRegistry { directory in
            try write(
                registryRecord(procStart: "Fri Aug 28 17:20:19 2026"), pid: 4242, in: directory)
            let sink = FrameSink()
            let subject = watcher(
                directory: directory, sessions: FakeSessionDirectory([spawnedSession()]))
            await subject.addLink(link(sink: sink))

            #expect(await sink.drain().isEmpty)
            #expect(await subject.lastScanReport().skippedNotLive == 1)
        }
    }
}

// MARK: - The tick

@Suite("Roster watcher — the tick", .clockDriven)
struct RosterWatcherTickTests {
    /// The poll interval is the injected clock's, and a session that appears
    /// between ticks is announced on the next one.
    ///
    /// The registry is written **after** the loop has armed its first sleep, so
    /// the opening scan provably cannot be what announced it, and the advancing
    /// is done by `advanceUntil` rather than by a fixed count — the loop is a
    /// poll-and-re-arm, which is the exact shape a single advance turns into a
    /// hang.
    @Test func theTickRescansOnTheInjectedInterval() async throws {
        try await withRegistry { directory in
            let clock = TestClock<Duration>()
            let sink = FrameSink()
            let subject = watcher(
                directory: directory,
                sessions: FakeSessionDirectory([spawnedSession()]),
                clock: clock)
            await subject.addLink(link(sink: sink))

            let task = Task { await subject.run() }
            defer { task.cancel() }

            // The opening scan runs against an empty registry and arms the
            // interval. Waiting for that arm before writing the record is what
            // makes the tick load-bearing: the session cannot have been picked
            // up by the opening scan.
            await clock.waitForSuspension()
            #expect(await sink.frames.isEmpty)

            try write(registryRecord(), pid: 4242, in: directory)
            let announced = await clock.advanceUntil(
                "the roster to announce a session that appeared between ticks", by: .seconds(2)
            ) {
                !peers(await sink.frames).isEmpty
            }

            #expect(announced)
            #expect(peers(await sink.frames).map(\.name) == ["laptop:useful-swallow %3541"])
        }
    }
}
