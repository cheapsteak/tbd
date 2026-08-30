import Foundation
import Testing
import TBDShared

@testable import TBDCLI

/// `tbd peer list` — the join the docs otherwise teach a human to do by hand,
/// plus every way it can be asked to run against a broken machine.
///
/// Everything here goes through the composition the command itself calls, so an
/// assertion is made on the rows and the text a person actually sees rather
/// than on an internal boolean. The two seams a listing cannot have in a test —
/// the kernel's process table and the filesystem — are injected.
@Suite("tbd peer list")
struct PeerListTests {

    // MARK: - Fixtures

    private static let registryPath = "/opt/peertest/sessions"
    private static let laneAPath = "/opt/peertest/lanes/lane-a"
    private static let laneBPath = "/opt/peertest/lanes/lane-b"
    private static let liveProcStart = "Sat Aug 29 22:07:57 2026"

    private static func worktree(
        id: UUID = UUID(),
        displayName: String,
        path: String,
        location: WorktreeLocation = .local
    ) -> Worktree {
        Worktree(
            id: id,
            repoID: UUID(),
            name: displayName,
            displayName: displayName,
            branch: "tbd/\(displayName)",
            path: location.storagePath ?? path,
            tmuxServer: "tbd-test",
            location: location)
    }

    private static func terminal(
        id: UUID = UUID(),
        worktreeID: UUID,
        pane: String,
        claudeSessionID: String? = nil
    ) -> Terminal {
        Terminal(
            id: id,
            worktreeID: worktreeID,
            tmuxWindowID: "@1",
            tmuxPaneID: pane,
            claudeSessionID: claudeSessionID,
            kind: .claude)
    }

    /// A registry record, composed from JSON so the decoder under test is the
    /// thing that produces it — a hand-built value would test a struct nobody
    /// reads off disk.
    private static func record(
        _ fields: [String: Any]
    ) throws -> PeerRegistryRecord {
        let data = try JSONSerialization.data(withJSONObject: fields)
        return try JSONDecoder().decode(PeerRegistryRecord.self, from: data)
    }

    private static func liveSessionFields(
        sessionID: String = UUID().uuidString,
        cwd: String,
        name: String,
        pane: String?,
        socket: String
    ) -> [String: Any] {
        var fields: [String: Any] = [
            "sessionId": sessionID,
            "cwd": cwd,
            "name": name,
            "status": "busy",
            "procStart": liveProcStart,
            "version": "2.1.251",
            "peerProtocol": 1,
            "messagingSocketPath": socket,
        ]
        if let pane { fields["tmux"] = "main:@1.\(pane)" }
        return fields
    }

    /// One row of the durable shadow-peer ledger, as `peer.status` hands it
    /// over. **This is the only thing that makes a record a shadow**, so every
    /// shadow fixture below has to build one.
    private static func shadowRow(
        pid: Int32,
        provider: String = "acme-cloud",
        handle: String = "h-abc",
        name: String,
        remoteSessionID: String?,
        live: Bool = true
    ) -> PeerShadowArtifactRow {
        PeerShadowArtifactRow(
            pid: pid,
            provider: provider,
            handle: handle,
            name: name,
            recordSessionID: "record-\(pid)",
            remoteSessionID: remoteSessionID,
            socketPath: "/opt/peertest/socks/\(pid).sock",
            recordPath: "\(registryPath)/\(pid).json",
            daemonGeneration: "gen-1",
            publishedAt: Date(timeIntervalSince1970: 1_800_000_000),
            live: live)
    }

    private static func bridge(
        messagingEnabled: Bool = true,
        providers: [PeerProviderBridgeStatus] = [
            PeerProviderBridgeStatus(
                provider: "acme-cloud", declaresMessages: true, bridged: true,
                linkState: "up")
        ],
        shadows: [PeerShadowArtifactRow] = [],
        lastSweep: PeerShadowSweep? = nil
    ) -> PeerBridgeStatus {
        PeerBridgeStatus(
            messagingEnabled: messagingEnabled,
            remoteBackendsLive: true,
            providers: providers,
            shadows: shadows,
            lastSweep: lastSweep)
    }

    /// Compose against a fleet, with every pid alive and every advertised
    /// socket present unless the test says otherwise.
    private static func compose(
        scan: PeerRegistryScan,
        fleet: PeerListFleet,
        socketFilesOnDisk: [String] = [],
        deadPIDs: Set<pid_t> = [],
        procStartOverrides: [pid_t: String] = [:],
        missingSockets: Set<String> = []
    ) -> PeerListResult {
        composePeerListing(
            registryPath: registryPath,
            scan: scan,
            fleet: fleet,
            socketFilesOnDisk: socketFilesOnDisk,
            procStartForPID: { pid in
                if deadPIDs.contains(pid) { return nil }
                return procStartOverrides[pid] ?? liveProcStart
            },
            socketExists: { !missingSockets.contains($0) })
    }

    // MARK: - Local rows

    @Test func localRowNamesTheWorktreeTerminalAndPaneBehindIt() throws {
        let worktree = Self.worktree(displayName: "lane-a", path: Self.laneAPath)
        let terminal = Self.terminal(
            worktreeID: worktree.id, pane: "%3541", claudeSessionID: "S-1")
        let scan = PeerRegistryScan(entries: [
            PeerRegistryEntry(pid: 4001, record: try Self.record(Self.liveSessionFields(
                sessionID: "S-1", cwd: Self.laneAPath, name: "lane-a",
                pane: "%3541", socket: "/opt/peertest/socks/4001.sock")))
        ])

        let result = Self.compose(
            scan: scan,
            fleet: PeerListFleet(
                reachable: true, worktrees: [worktree], terminals: [terminal]))

        #expect(result.peers.count == 1)
        let row = try #require(result.peers.first)
        #expect(row.kind == .local)
        #expect(row.name == "lane-a")
        #expect(row.status == "busy")
        #expect(row.worktreeID == worktree.id)
        #expect(row.worktreeDisplayName == "lane-a")
        #expect(row.terminalID == terminal.id)
        #expect(row.tmuxPane == "%3541")
        #expect(row.provider == nil)
        #expect(row.linkState == nil)

        let behind = peerBehindColumn(row)
        #expect(behind.contains("lane-a"))
        #expect(behind.contains("%3541"))
        #expect(behind.contains("terminal \(shortPeerID(terminal.id))"))
    }

    /// The pane join is the one the docs teach, and it has to keep working for
    /// a session whose `SessionStart` hook never fired — that is the case the
    /// session id cannot cover.
    @Test func localRowJoinsOnCwdAndPaneWhenNoSessionIDWasCaptured() throws {
        let worktree = Self.worktree(displayName: "lane-a", path: Self.laneAPath)
        let terminal = Self.terminal(worktreeID: worktree.id, pane: "%77")
        let scan = PeerRegistryScan(entries: [
            PeerRegistryEntry(pid: 4002, record: try Self.record(Self.liveSessionFields(
                cwd: Self.laneAPath, name: "some-slug-name",
                pane: "%77", socket: "/opt/peertest/socks/4002.sock")))
        ])

        let result = Self.compose(
            scan: scan,
            fleet: PeerListFleet(
                reachable: true, worktrees: [worktree], terminals: [terminal]))

        let row = try #require(result.peers.first)
        #expect(row.kind == .local)
        #expect(row.terminalID == terminal.id)
        // The point of the join: the row is placed even though its name matches
        // no worktree, which is precisely the drift the docs warn about.
        #expect(row.name == "some-slug-name")
    }

    /// A pane id belongs to one tmux *server*, and TBD runs one per repository
    /// alongside whatever servers the user runs. A pane match with the wrong
    /// directory must not place a row.
    @Test func paneJoinDoesNotFireAcrossDifferentWorktrees() throws {
        let laneA = Self.worktree(displayName: "lane-a", path: Self.laneAPath)
        let laneB = Self.worktree(displayName: "lane-b", path: Self.laneBPath)
        let terminal = Self.terminal(worktreeID: laneB.id, pane: "%77")
        let scan = PeerRegistryScan(entries: [
            PeerRegistryEntry(pid: 4003, record: try Self.record(Self.liveSessionFields(
                cwd: Self.laneAPath, name: "elsewhere",
                pane: "%77", socket: "/opt/peertest/socks/4003.sock")))
        ])

        let result = Self.compose(
            scan: scan,
            fleet: PeerListFleet(
                reachable: true, worktrees: [laneA, laneB], terminals: [terminal]))

        let row = try #require(result.peers.first)
        #expect(row.kind == .external)
        #expect(row.terminalID == nil)
    }

    // MARK: - Shadow rows

    /// A shadow is recognised by a pid lookup in TBD's own ledger, and the
    /// remote session it stands for and the state of its link both come off
    /// that answer rather than out of the record.
    @Test func shadowRowNamesTheProviderSessionAndItsLinkState() throws {
        let remote = Self.worktree(
            displayName: "api-lane",
            path: "",
            location: .remote(provider: "acme-cloud", sessionID: "sess-42"))
        // A shadow carries no `tmux` key by construction, and no marker of
        // TBD's either — the ledger row below is the whole recognition.
        let scan = PeerRegistryScan(entries: [
            PeerRegistryEntry(pid: 5001, record: try Self.record(Self.liveSessionFields(
                cwd: Self.laneAPath, name: "acme-cloud:api-lane",
                pane: nil, socket: "/opt/peertest/socks/5001.sock")))
        ])

        let result = Self.compose(
            scan: scan,
            fleet: PeerListFleet(
                reachable: true, worktrees: [remote],
                bridge: Self.bridge(shadows: [Self.shadowRow(
                    pid: 5001, name: "acme-cloud:api-lane",
                    remoteSessionID: "sess-42")])))

        let row = try #require(result.peers.first)
        #expect(row.kind == .shadow)
        #expect(row.provider == "acme-cloud")
        #expect(row.providerSessionID == "sess-42")
        #expect(row.linkState == "up")
        // The remote session id is an identity join back to the lane, not a
        // name match.
        #expect(row.worktreeID == remote.id)
        // A shadow is not a local lane: it has no terminal and no pane, and the
        // listing must not invent either.
        #expect(row.terminalID == nil)
        #expect(row.tmuxPane == nil)

        let behind = peerBehindColumn(row)
        #expect(behind.contains("acme-cloud session sess-42"))
        #expect(behind.contains("link up"))
    }

    /// **The mutation check on the classification.** The old rule was a name
    /// match: a record with no `tmux` whose name composed back to a remote
    /// worktree was called a shadow. That rule cannot tell a real shadow from
    /// anything else publishing a record under the same name, so it is gone —
    /// and this is the fixture it used to accept.
    @Test func aRecordNamedLikeAShadowIsNotOneWithoutALedgerRow() throws {
        let remote = Self.worktree(
            displayName: "api-lane",
            path: "",
            location: .remote(provider: "acme-cloud", sessionID: "sess-42"))
        let scan = PeerRegistryScan(entries: [
            PeerRegistryEntry(pid: 5002, record: try Self.record(Self.liveSessionFields(
                cwd: "/opt/peertest/elsewhere", name: "acme-cloud:api-lane",
                pane: nil, socket: "/opt/peertest/socks/5002.sock")))
        ])

        let result = Self.compose(
            scan: scan,
            fleet: PeerListFleet(
                reachable: true, worktrees: [remote], bridge: Self.bridge()))

        let row = try #require(result.peers.first)
        #expect(row.kind == .external)
        #expect(row.provider == nil)
    }

    /// A not-live ledger row is "awaiting reclamation, not a peer" — its own
    /// field says so — and the pid it still names can since have been recycled
    /// onto an ordinary local session. Indexing it would hand that session a
    /// dead link's provider and site it into someone else's lane, so the row is
    /// not consulted and the local join answers instead.
    @Test func aNotLiveLedgerRowDoesNotMakeItsPIDAShadow() throws {
        let worktree = Self.worktree(displayName: "lane-a", path: Self.laneAPath)
        let terminal = Self.terminal(
            worktreeID: worktree.id, pane: "%88", claudeSessionID: "S-R")
        let remote = Self.worktree(
            displayName: "api-lane",
            path: "",
            location: .remote(provider: "acme-cloud", sessionID: "sess-42"))
        // The recycled pid: a genuine local Claude Code session now running
        // under the pid a retired shadow helper used to hold.
        let scan = PeerRegistryScan(entries: [
            PeerRegistryEntry(pid: 5004, record: try Self.record(Self.liveSessionFields(
                sessionID: "S-R", cwd: Self.laneAPath, name: "lane-a",
                pane: "%88", socket: "/opt/peertest/socks/5004.sock")))
        ])

        let result = Self.compose(
            scan: scan,
            fleet: PeerListFleet(
                reachable: true, worktrees: [worktree, remote], terminals: [terminal],
                bridge: Self.bridge(shadows: [Self.shadowRow(
                    pid: 5004, name: "acme-cloud:api-lane",
                    remoteSessionID: "sess-42", live: false)])))

        let row = try #require(result.peers.first)
        #expect(row.kind == .local)
        #expect(row.provider == nil)
        #expect(row.providerSessionID == nil)
        #expect(row.linkState == nil)
        // The lane the row is sited into is the local one it really runs in,
        // not the remote lane the retired row would have named.
        #expect(row.worktreeID == worktree.id)
        #expect(row.terminalID == terminal.id)
    }

    /// A daemon that cannot answer `peer.status` leaves every shadow
    /// unrecognisable, and the listing says so rather than quietly downgrading
    /// a live shadow to an ordinary peer.
    @Test func withNoLedgerAnswerNoRowIsCalledAShadow() throws {
        let remote = Self.worktree(
            displayName: "api-lane",
            path: "",
            location: .remote(provider: "acme-cloud", sessionID: "sess-42"))
        let scan = PeerRegistryScan(entries: [
            PeerRegistryEntry(pid: 5003, record: try Self.record(Self.liveSessionFields(
                cwd: Self.laneAPath, name: "acme-cloud:api-lane",
                pane: nil, socket: "/opt/peertest/socks/5003.sock")))
        ])

        let result = Self.compose(
            scan: scan, fleet: PeerListFleet(reachable: true, worktrees: [remote]))

        #expect(result.peers.first?.kind == .external)
        #expect(result.warnings.contains { $0.contains("did not answer peer.status") })
    }

    /// The stale-shim answer. An old shim never declares `messages`, so TBD
    /// never invokes it — and the whole feature then does nothing, silently.
    /// With the flag on, that silence is a line somebody reads.
    @Test func aProviderThatDoesNotDeclareMessagesIsNamed() {
        let result = Self.compose(
            scan: PeerRegistryScan(),
            fleet: PeerListFleet(
                reachable: true,
                remotePeerMessagingEnabled: true,
                bridge: Self.bridge(providers: [
                    PeerProviderBridgeStatus(
                        provider: "old-shim", declaresMessages: false, bridged: false)
                ])))

        #expect(result.warnings.contains {
            $0.contains("old-shim") && $0.contains("`messages`")
        })
    }

    /// The mirror image: a provider that does declare it and is bridged draws
    /// no complaint. Without this, a warning that fired unconditionally would
    /// pass the test above and mean nothing.
    @Test func aBridgedProviderDrawsNoStaleShimWarning() {
        let result = Self.compose(
            scan: PeerRegistryScan(),
            fleet: PeerListFleet(
                reachable: true,
                remotePeerMessagingEnabled: true,
                bridge: Self.bridge()))

        #expect(!result.warnings.contains { $0.contains("`messages`") })
    }

    // MARK: - External rows

    @Test func aPeerTBDDidNotSpawnIsListedRatherThanDropped() throws {
        let worktree = Self.worktree(displayName: "lane-a", path: Self.laneAPath)
        let scan = PeerRegistryScan(entries: [
            PeerRegistryEntry(pid: 6001, record: try Self.record(Self.liveSessionFields(
                cwd: "/opt/peertest/personal", name: "my-own-claude",
                pane: "%2", socket: "/opt/peertest/socks/6001.sock")))
        ])

        let result = Self.compose(
            scan: scan, fleet: PeerListFleet(reachable: true, worktrees: [worktree]))

        let row = try #require(result.peers.first)
        #expect(row.kind == .external)
        #expect(peerBehindColumn(row).contains("not spawned by TBD"))
        // "Every peer TBD can see" is the command's whole claim: a session it
        // did not spawn is still addressable by every session it did.
        #expect(renderPeerListing(result).contains("my-own-claude"))
    }

    // MARK: - Graceful degradation

    @Test func aDaemonThatDidNotAnswerLeavesRowsUnattributedAndSaysWhy() throws {
        let scan = PeerRegistryScan(entries: [
            PeerRegistryEntry(pid: 7001, record: try Self.record(Self.liveSessionFields(
                cwd: Self.laneAPath, name: "lane-a",
                pane: "%3541", socket: "/opt/peertest/socks/7001.sock")))
        ])

        let result = Self.compose(
            scan: scan, fleet: .unreachable(reason: "the daemon socket is not there"))

        let row = try #require(result.peers.first)
        // Not `external`: nothing was joined, so nothing may be asserted about
        // whether TBD spawned it.
        #expect(row.kind == .unattributed)
        #expect(row.worktreeID == nil)
        let text = renderPeerListing(result)
        #expect(text.contains("the TBD daemon did not answer"))
        #expect(text.contains("the daemon socket is not there"))
        // Still a listing: the registry is readable without the daemon.
        #expect(text.contains("lane-a"))
    }

    @Test func anUnreadableRegistryIsReportedRatherThanFatal() {
        var scan = PeerRegistryScan()
        scan.directoryUnreadable = true

        let result = Self.compose(scan: scan, fleet: PeerListFleet(reachable: true))

        #expect(result.peers.isEmpty)
        let text = renderPeerListing(result)
        #expect(text.contains("the peer registry directory could not be read"))
        #expect(text.contains("No peers found"))
    }

    @Test func aRecordThatWillNotDecodeIsOneSkippedRecordNotAFailedListing() throws {
        var scan = PeerRegistryScan(entries: [
            PeerRegistryEntry(pid: 7002, record: try Self.record(Self.liveSessionFields(
                cwd: Self.laneAPath, name: "lane-a",
                pane: "%1", socket: "/opt/peertest/socks/7002.sock")))
        ])
        scan.malformedFilenames = ["9999.json"]

        let result = Self.compose(scan: scan, fleet: PeerListFleet(reachable: true))

        #expect(result.peers.count == 1)
        #expect(result.orphans.contains {
            $0.kind == .malformedRecord && $0.path == "9999.json"
        })
    }

    @Test func theMessagingGateBeingOffExplainsAnEmptyShadowList() {
        let result = Self.compose(
            scan: PeerRegistryScan(),
            fleet: PeerListFleet(reachable: true, remotePeerMessagingEnabled: false))

        #expect(result.remotePeerMessagingEnabled == false)
        #expect(result.warnings.contains { $0.contains("remote peer messaging is off") })
    }

    /// Nil is not "off". A config the command could not read must not be
    /// rendered as a deliberate choice nobody made.
    @Test func anUnreadableConfigDoesNotClaimTheGateIsOff() {
        let result = Self.compose(
            scan: PeerRegistryScan(), fleet: PeerListFleet(reachable: true))

        #expect(result.remotePeerMessagingEnabled == nil)
        #expect(!result.warnings.contains { $0.contains("remote peer messaging is off") })
    }

    // MARK: - Orphans

    @Test func aRecordUnderADeadPIDIsAnOrphanRatherThanAPeer() throws {
        let scan = PeerRegistryScan(entries: [
            PeerRegistryEntry(pid: 8001, record: try Self.record(Self.liveSessionFields(
                cwd: Self.laneAPath, name: "gone",
                pane: "%1", socket: "/opt/peertest/socks/8001.sock")))
        ])

        let result = Self.compose(
            scan: scan, fleet: PeerListFleet(reachable: true), deadPIDs: [8001])

        #expect(result.peers.isEmpty)
        let orphan = try #require(result.orphans.first)
        #expect(orphan.kind == .deadRecord)
        #expect(orphan.detail.contains("8001"))
    }

    /// The recycled-pid ghost: a live pid that started at a different time than
    /// the record claims. Claude Code's reaper checks pid liveness and nothing
    /// else, so this is the class that accumulates and the one the listing has
    /// to name.
    @Test func aRecycledPIDGhostIsNamedAsAGhostNotListedAsAPeer() throws {
        let scan = PeerRegistryScan(entries: [
            PeerRegistryEntry(pid: 8002, record: try Self.record(Self.liveSessionFields(
                cwd: Self.laneAPath, name: "ghost",
                pane: "%1", socket: "/opt/peertest/socks/8002.sock")))
        ])

        let result = Self.compose(
            scan: scan,
            fleet: PeerListFleet(reachable: true),
            procStartOverrides: [8002: "Fri Aug 28 17:20:19 2026"])

        #expect(result.peers.isEmpty)
        let orphan = try #require(result.orphans.first)
        #expect(orphan.kind == .ghostRecord)
        #expect(orphan.detail.contains(Self.liveProcStart))
        #expect(orphan.detail.contains("Fri Aug 28 17:20:19 2026"))
    }

    @Test func aSocketNoRecordNamesIsReportedAsUnclaimed() throws {
        let scan = PeerRegistryScan(entries: [
            PeerRegistryEntry(pid: 8003, record: try Self.record(Self.liveSessionFields(
                cwd: Self.laneAPath, name: "lane-a",
                pane: "%1", socket: "/opt/peertest/socks/8003.sock")))
        ])

        let result = Self.compose(
            scan: scan,
            fleet: PeerListFleet(reachable: true),
            socketFilesOnDisk: [
                "/opt/peertest/socks/8003.sock",
                "/opt/peertest/socks/1234.sock",
            ])

        // The claimed one is not an orphan; the unclaimed one is.
        #expect(result.orphans.count == 1)
        let orphan = try #require(result.orphans.first)
        #expect(orphan.kind == .unclaimedSocket)
        #expect(orphan.path == "/opt/peertest/socks/1234.sock")
        #expect(renderPeerListing(result).contains("listed, not reclaimed"))
    }

    /// The mutation check the sweep's own tests make, applied to the listing: a
    /// healthy fleet must produce **no** orphans. A detector that flags live
    /// state is worse than one that flags nothing.
    @Test func aHealthyFleetProducesNoOrphans() throws {
        let worktree = Self.worktree(displayName: "lane-a", path: Self.laneAPath)
        let terminal = Self.terminal(
            worktreeID: worktree.id, pane: "%3541", claudeSessionID: "S-9")
        let remote = Self.worktree(
            displayName: "api-lane",
            path: "",
            location: .remote(provider: "acme-cloud", sessionID: "sess-1"))
        let scan = PeerRegistryScan(entries: [
            PeerRegistryEntry(pid: 9001, record: try Self.record(Self.liveSessionFields(
                sessionID: "S-9", cwd: Self.laneAPath, name: "lane-a",
                pane: "%3541", socket: "/opt/peertest/socks/9001.sock"))),
            PeerRegistryEntry(pid: 9002, record: try Self.record(Self.liveSessionFields(
                cwd: Self.laneAPath, name: "acme-cloud:api-lane",
                pane: nil, socket: "/opt/peertest/socks/9002.sock"))),
        ])

        let result = Self.compose(
            scan: scan,
            fleet: PeerListFleet(
                reachable: true, worktrees: [worktree, remote], terminals: [terminal],
                bridge: Self.bridge(shadows: [Self.shadowRow(
                    pid: 9002, name: "acme-cloud:api-lane", remoteSessionID: "sess-1")])),
            socketFilesOnDisk: [
                "/opt/peertest/socks/9001.sock",
                "/opt/peertest/socks/9002.sock",
            ])

        #expect(result.orphans.isEmpty)
        #expect(result.peers.map(\.kind) == [.local, .shadow])
    }

    /// A record whose advertised socket is gone still lists — the record is
    /// what every other session reads — but the row says nothing is listening.
    @Test func aRowWhoseSocketIsMissingSaysSo() throws {
        let scan = PeerRegistryScan(entries: [
            PeerRegistryEntry(pid: 9003, record: try Self.record(Self.liveSessionFields(
                cwd: Self.laneAPath, name: "lane-a",
                pane: "%1", socket: "/opt/peertest/socks/9003.sock")))
        ])

        let result = Self.compose(
            scan: scan,
            fleet: PeerListFleet(reachable: true),
            missingSockets: ["/opt/peertest/socks/9003.sock"])

        let row = try #require(result.peers.first)
        #expect(row.socketPresent == false)
        #expect(peerBehindColumn(row).contains("socket missing"))
    }

    // MARK: - Ordering and output shapes

    @Test func rowsSortLocalThenShadowThenExternal() throws {
        let worktree = Self.worktree(displayName: "lane-a", path: Self.laneAPath)
        let terminal = Self.terminal(
            worktreeID: worktree.id, pane: "%1", claudeSessionID: "S-A")
        let remote = Self.worktree(
            displayName: "api-lane",
            path: "",
            location: .remote(provider: "acme-cloud", sessionID: "sess-1"))
        let scan = PeerRegistryScan(entries: [
            PeerRegistryEntry(pid: 1, record: try Self.record(Self.liveSessionFields(
                cwd: "/opt/peertest/personal", name: "zzz-external",
                pane: "%99", socket: "/opt/peertest/socks/1.sock"))),
            PeerRegistryEntry(pid: 2, record: try Self.record(Self.liveSessionFields(
                cwd: Self.laneAPath, name: "acme-cloud:api-lane",
                pane: nil, socket: "/opt/peertest/socks/2.sock"))),
            PeerRegistryEntry(pid: 3, record: try Self.record(Self.liveSessionFields(
                sessionID: "S-A", cwd: Self.laneAPath, name: "lane-a",
                pane: "%1", socket: "/opt/peertest/socks/3.sock"))),
        ])

        let result = Self.compose(
            scan: scan,
            fleet: PeerListFleet(
                reachable: true, worktrees: [worktree, remote], terminals: [terminal],
                bridge: Self.bridge(shadows: [Self.shadowRow(
                    pid: 2, name: "acme-cloud:api-lane", remoteSessionID: "sess-1")])))

        #expect(result.peers.map(\.kind) == [.local, .shadow, .external])
    }

    @Test func theClosingNoteExplainsWhyNoRefIsPrinted() {
        let result = Self.compose(
            scan: PeerRegistryScan(), fleet: PeerListFleet(reachable: true))
        let text = renderPeerListing(result)
        #expect(text.contains("[ref]"))
        #expect(text.contains("ListAgents"))
    }

    @Test func jsonCarriesTheJoinedFieldsAndTheWarnings() throws {
        let worktree = Self.worktree(displayName: "lane-a", path: Self.laneAPath)
        let terminal = Self.terminal(
            worktreeID: worktree.id, pane: "%3541", claudeSessionID: "S-J")
        let scan = PeerRegistryScan(entries: [
            PeerRegistryEntry(pid: 4100, record: try Self.record(Self.liveSessionFields(
                sessionID: "S-J", cwd: Self.laneAPath, name: "lane-a",
                pane: "%3541", socket: "/opt/peertest/socks/4100.sock")))
        ])

        let result = Self.compose(
            scan: scan,
            fleet: PeerListFleet(
                reachable: true, worktrees: [worktree], terminals: [terminal],
                remotePeerMessagingEnabled: false))

        // Encoded exactly the way the command encodes it.
        let json = try #require(jsonString(result))
        #expect(json.contains("\"kind\" : \"local\""))
        #expect(json.contains(terminal.id.uuidString))
        #expect(json.contains(worktree.id.uuidString))
        #expect(json.contains("\"pid\" : 4100"))
        #expect(json.contains("\"peerProtocol\" : 1"))
        #expect(json.contains("\"version\" : \"2.1.251\""))
        #expect(json.contains("remote peer messaging is off"))
        // The absent ref is absent from the machine surface too, so nothing
        // reads an always-null field as "this peer has no ref".
        #expect(!json.contains("\"ref\""))
    }

    // MARK: - Registry I/O

    @Test func onlyPIDNamedRecordsAreRead() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peer-list-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func write(_ name: String, _ contents: String) throws {
            try Data(contents.utf8).write(to: directory.appendingPathComponent(name))
        }
        let good = """
            {"sessionId":"S","cwd":"/opt/peertest/lanes/lane-a","name":"lane-a",\
            "status":"idle","messagingSocketPath":"/opt/peertest/socks/321.sock",\
            "tmux":"main:@1.%1","peerProtocol":1}
            """
        try write("321.json", good)
        // The third per-peer artifact, and a write-temp: neither round-trips as
        // a pid, so neither may reach the listing.
        try write("321.abc123.key", "token")
        try write(".321.json.\(UUID().uuidString).tmp", good)
        try write("notes.txt", "hello")
        try write("444.json", "{ this is not json")

        let scan = readPeerRegistry(at: directory)

        #expect(scan.directoryUnreadable == false)
        #expect(scan.entries.map(\.pid) == [321])
        #expect(scan.malformedFilenames == ["444.json"])
        #expect(scan.entries.first?.record.name == "lane-a")
        #expect(scan.entries.first?.record.tmuxPaneID == "%1")
    }

    @Test func aMissingRegistryDirectoryReadsAsUnreadableRatherThanThrowing() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peer-list-absent-\(UUID().uuidString)", isDirectory: true)

        let scan = readPeerRegistry(at: directory)

        #expect(scan.directoryUnreadable)
        #expect(scan.entries.isEmpty)
    }

    /// The socket directory is derived from the records, never guessed — so
    /// with no records nothing is scanned and nothing is reported, rather than
    /// a clean bill nobody checked.
    @Test func socketScanIsDerivedFromTheRecordsAndCollectsOnlySockets() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peer-socks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for name in ["100.sock", "200.sock", "100.abcdef.key"] {
            try Data("x".utf8).write(to: directory.appendingPathComponent(name))
        }

        let record = try Self.record([
            "messagingSocketPath": directory.appendingPathComponent("100.sock").path,
        ])
        let entry = PeerRegistryEntry(pid: 100, record: record)

        let found = peerSocketFiles(namedBy: [entry])
        #expect(found.count == 2)
        #expect(found.allSatisfy { $0.hasSuffix(".sock") })

        #expect(peerSocketFiles(namedBy: []).isEmpty)
    }

    // MARK: - Pane parsing

    @Test func paneParsingNormalisesAndRefusesNonPaneShapes() throws {
        let withPercent = try Self.record(["tmux": "main:@3541.%3541"])
        let withoutPercent = try Self.record(["tmux": "main:@3541.3541"])
        // A field that has changed shape must read as "no pane", never as a
        // pane nothing can match.
        let notAPane = try Self.record(["tmux": "main:@3541.pane-x"])
        let empty = try Self.record(["tmux": ""])
        let absent = try Self.record([:])

        #expect(withPercent.tmuxPaneID == "%3541")
        #expect(withoutPercent.tmuxPaneID == "%3541")
        #expect(notAPane.tmuxPaneID == nil)
        #expect(empty.tmuxPaneID == nil)
        #expect(absent.tmuxPaneID == nil)
    }

    @Test func recordFilenamesMustRoundTripAsAPID() {
        #expect(PeerJoinKeys.pid(fromRecordFilename: "4021.json") == 4021)
        #expect(PeerJoinKeys.pid(fromRecordFilename: "04021.json") == nil)
        #expect(PeerJoinKeys.pid(fromRecordFilename: "0.json") == nil)
        #expect(PeerJoinKeys.pid(fromRecordFilename: "-1.json") == nil)
        #expect(PeerJoinKeys.pid(fromRecordFilename: "4021.sock") == nil)
        #expect(PeerJoinKeys.pid(fromRecordFilename: "4021.abc.key") == nil)
    }

    // MARK: - Absent fields

    @Test func aRecordWithNoNameOrStatusIsListedUnderWordsNobodyCouldMistakeForFacts() throws {
        let scan = PeerRegistryScan(entries: [
            PeerRegistryEntry(pid: 9500, record: try Self.record([
                "messagingSocketPath": "/opt/peertest/socks/9500.sock",
            ]))
        ])

        let result = Self.compose(scan: scan, fleet: PeerListFleet(reachable: true))

        let row = try #require(result.peers.first)
        #expect(row.name == PeerRow.unnamed)
        #expect(row.status == PeerRow.unknownStatus)
        // Not one of Claude Code's own status words, which would read as a fact.
        #expect(!["idle", "busy", "waiting", "shell"].contains(row.status))
    }
}
