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
        claudeSessionID: String? = nil,
        transport: TerminalTransport = .tmux
    ) -> Terminal {
        Terminal(
            id: id,
            worktreeID: worktreeID,
            tmuxWindowID: transport == .tmux ? "@1" : "",
            tmuxPaneID: pane,
            claudeSessionID: claudeSessionID,
            kind: .claude,
            transport: transport)
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

    private static let onRepo = PeerMessagingRepoStatus(
        repoID: UUID(), repoName: "acme", tomlPath: "/opt/peertest/acme/tbd.toml",
        enabled: true)

    private static let offRepo = PeerMessagingRepoStatus(
        repoID: UUID(), repoName: "acme-tools", tomlPath: "/opt/peertest/acme-tools/tbd.toml",
        enabled: false)

    private static func bridge(
        repos: [PeerMessagingRepoStatus]? = [onRepo],
        providers: [PeerProviderBridgeStatus] = [
            PeerProviderBridgeStatus(
                provider: "acme-cloud", declaresMessages: true, bridged: true,
                linkState: "up")
        ],
        shadows: [PeerShadowArtifactRow] = [],
        lastSweep: PeerShadowSweep? = nil
    ) -> PeerBridgeStatus {
        PeerBridgeStatus(
            repos: repos,
            remoteBackendsLive: true,
            providers: providers,
            shadows: shadows,
            lastSweep: lastSweep)
    }

    /// Compose against a fleet, with every pid alive and every advertised
    /// socket present unless the test says otherwise. The process table is
    /// readable and empty unless a test hands one over, so no record is placed
    /// by descent and no warning about the table is raised.
    private static func compose(
        scan: PeerRegistryScan,
        fleet: PeerListFleet,
        socketFilesOnDisk: [String] = [],
        deadPIDs: Set<pid_t> = [],
        procStartOverrides: [pid_t: String] = [:],
        missingSockets: Set<String> = [],
        processes: ProcessTableSnapshot? = ProcessTableSnapshot(entries: [:])
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
            processes: processes,
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
        #expect(behind.contains("tmux %3541"))
        #expect(behind.contains("terminal \(shortPeerID(terminal.id))"))
    }

    /// A holder-backed terminal has no tmux pane — its row is discriminated by
    /// `transport` and carries an empty placeholder `tmuxPaneID` — so the
    /// listing names it by the terminal id alone, the same eight-character
    /// discriminator the roster announces to remote peers, and never renders
    /// the empty pane as a bare `%`.
    @Test func holderRowNamesItsTerminalIDAndNoPane() throws {
        let worktree = Self.worktree(displayName: "lane-a", path: Self.laneAPath)
        let terminalID = try #require(UUID(uuidString: "5A1B2C3D-7E8F-4A0B-9C1D-2E3F4A5B6C7D"))
        let terminal = Self.terminal(
            id: terminalID, worktreeID: worktree.id, pane: "", claudeSessionID: "S-holder",
            transport: .holder)
        let scan = PeerRegistryScan(entries: [
            PeerRegistryEntry(pid: 4010, record: try Self.record(Self.liveSessionFields(
                sessionID: "S-holder", cwd: Self.laneAPath, name: "lane-a",
                pane: nil, socket: "/opt/peertest/socks/4010.sock")))
        ])

        let result = Self.compose(
            scan: scan,
            fleet: PeerListFleet(
                reachable: true, worktrees: [worktree], terminals: [terminal]))

        let row = try #require(result.peers.first)
        #expect(row.kind == .local)
        #expect(row.terminalID == terminalID)
        #expect(row.tmuxPane == nil)

        #expect(peerBehindColumn(row) == "lane-a · terminal 5A1B2C3D")
    }

    /// A holder-backed session's record carries no `tmux`, so there is no pane
    /// to fall back on. With no captured session id and no process tree placing
    /// it in a tab — the table here is empty — the row lists as `external`, and
    /// is never attached to whichever holder terminal happens to share its
    /// worktree: sharing a directory is not descent.
    @Test func holderSessionWithNoCapturedSessionIDListsAsExternal() throws {
        let worktree = Self.worktree(displayName: "lane-a", path: Self.laneAPath)
        let terminal = Self.terminal(
            worktreeID: worktree.id, pane: "", claudeSessionID: nil, transport: .holder)
        let scan = PeerRegistryScan(entries: [
            PeerRegistryEntry(pid: 4011, record: try Self.record(Self.liveSessionFields(
                sessionID: "S-not-yet-captured", cwd: Self.laneAPath, name: "lane-a",
                pane: nil, socket: "/opt/peertest/socks/4011.sock")))
        ])

        let result = Self.compose(
            scan: scan,
            fleet: PeerListFleet(
                reachable: true, worktrees: [worktree], terminals: [terminal]))

        let row = try #require(result.peers.first)
        #expect(row.kind == .external)
        #expect(row.terminalID == nil)
        #expect(row.tmuxPane == nil)
    }

    /// The cwd-and-pane fallback join has to keep working for a tmux session
    /// whose `SessionStart` hook never fired — that is the case the session id
    /// cannot cover.
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
    /// With a repository switched on, that silence is a line somebody reads.
    @Test func aProviderThatDoesNotDeclareMessagesIsNamed() {
        let result = Self.compose(
            scan: PeerRegistryScan(),
            fleet: PeerListFleet(
                reachable: true,
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
        #expect(peerBehindColumn(row).contains("not joined to a TBD tab"))
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

    /// No repository switched on explains an empty shadow list, and the
    /// warning names the exact setting that would change it.
    @Test func noSwitchedOnRepositoryExplainsAnEmptyShadowList() {
        let result = Self.compose(
            scan: PeerRegistryScan(),
            fleet: PeerListFleet(reachable: true, bridge: Self.bridge(repos: [Self.offRepo])))

        #expect(result.peerMessagingRepos == [Self.offRepo])
        #expect(result.warnings.contains {
            $0.contains("no repository has peer messaging switched on")
                && $0.contains("peer_messaging = true")
        })
    }

    /// The other branch: one repository on draws no such warning, and the
    /// listing prints each repository's state.
    @Test func aSwitchedOnRepositoryIsListedAsOn() {
        let result = Self.compose(
            scan: PeerRegistryScan(),
            fleet: PeerListFleet(
                reachable: true, bridge: Self.bridge(repos: [Self.onRepo, Self.offRepo])))

        #expect(!result.warnings.contains { $0.contains("no repository has peer messaging") })
        let text = renderPeerListing(result)
        #expect(text.contains("Peer messaging by repository"))
        #expect(text.contains("  on   acme  /opt/peertest/acme/tbd.toml"))
        #expect(text.contains("  off  acme-tools  /opt/peertest/acme-tools/tbd.toml"))
    }

    /// A `tbd.toml` TBD could not understand is named with its path and the
    /// problem, so a repository someone meant to switch on says why it is not.
    @Test func aTOMLProblemIsNamedWithItsPath() {
        let broken = PeerMessagingRepoStatus(
            repoID: UUID(), repoName: "acme", tomlPath: "/opt/peertest/acme/tbd.toml",
            enabled: false,
            problems: ["[remote_sessions] `peer_messaging` must be true or false"])
        let result = Self.compose(
            scan: PeerRegistryScan(),
            fleet: PeerListFleet(reachable: true, bridge: Self.bridge(repos: [broken])))

        #expect(result.warnings.contains {
            $0.contains("/opt/peertest/acme/tbd.toml") && $0.contains("must be true or false")
        })
    }

    /// A provider that declares `messages`, runs sessions in a switched-on
    /// repository and has no bridge yet is told when its stream opens: at the
    /// next poll, with no restart.
    @Test func aProviderAboutToOpenItsStreamIsNamed() {
        let result = Self.compose(
            scan: PeerRegistryScan(),
            fleet: PeerListFleet(reachable: true, bridge: Self.bridge(providers: [
                PeerProviderBridgeStatus(
                    provider: "acme-cloud", declaresMessages: true, bridged: false,
                    wantsStream: true)
            ])))

        #expect(result.warnings.contains {
            $0.contains("acme-cloud") && $0.contains(peerMessagingStreamOpeningNote)
        })
    }

    /// And the gated branch's other side: a provider whose repositories are all
    /// off has nothing pending, so nothing claims a stream is about to open.
    @Test func aProviderWithOnlySwitchedOffRepositoriesIsNotNamedAsPending() {
        let result = Self.compose(
            scan: PeerRegistryScan(),
            fleet: PeerListFleet(reachable: true, bridge: Self.bridge(providers: [
                PeerProviderBridgeStatus(
                    provider: "acme-cloud", declaresMessages: true, bridged: false,
                    wantsStream: false)
            ])))

        #expect(!result.warnings.contains { $0.contains(peerMessagingStreamOpeningNote) })
    }

    /// Nil is not "off". A daemon that did not report the switches must not be
    /// rendered as one where every repository chose off.
    @Test func anUnreportedSwitchSetDoesNotClaimEveryRepositoryIsOff() {
        let result = Self.compose(
            scan: PeerRegistryScan(),
            fleet: PeerListFleet(reachable: true, bridge: Self.bridge(repos: nil)))

        #expect(result.peerMessagingRepos == nil)
        #expect(!result.warnings.contains { $0.contains("no repository has peer messaging") })
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
                bridge: Self.bridge(repos: [Self.offRepo])))

        // Encoded exactly the way the command encodes it.
        let json = try #require(jsonString(result))
        #expect(json.contains("\"kind\" : \"local\""))
        #expect(json.contains(terminal.id.uuidString))
        #expect(json.contains(worktree.id.uuidString))
        #expect(json.contains("\"pid\" : 4100"))
        #expect(json.contains("\"peerProtocol\" : 1"))
        #expect(json.contains("\"version\" : \"2.1.251\""))
        #expect(json.contains("no repository has peer messaging switched on"))
        // The absent ref is absent from the machine surface too, so nothing
        // reads an always-null field as "this peer has no ref".
        #expect(!json.contains("\"ref\""))
    }

    // MARK: - Holder descent

    /// The moment every holder fixture below says its job was born.
    private static let jobBorn = Date(timeIntervalSince1970: 1_800_000_000)

    /// A holder-backed terminal: `holderPID` forked `childPID`, the tab's job.
    /// A shell by default, because the sessions this join exists for are the
    /// ones TBD did not spawn — a launcher run in a tab, a `claude` typed at a
    /// shell prompt.
    private static func holderTerminal(
        id: UUID = UUID(),
        worktreeID: UUID,
        kind: TerminalKind = .shell,
        holderPID: Int32,
        childPID: Int32,
        claudeSessionID: String? = nil,
        parked: Bool = false
    ) -> Terminal {
        Terminal(
            id: id,
            worktreeID: worktreeID,
            tmuxWindowID: "",
            tmuxPaneID: "",
            createdAt: jobBorn,
            claudeSessionID: claudeSessionID,
            kind: kind,
            hibernatedAt: parked ? jobBorn : nil,
            transport: .holder,
            holderPID: holderPID,
            childPID: childPID)
    }

    /// A process table from `pid: parent` pairs, every process born when the
    /// holder fixtures' jobs were unless `startedAt` says otherwise.
    private static func table(
        _ parents: [pid_t: pid_t], startedAt: [pid_t: Date] = [:]
    ) -> ProcessTableSnapshot {
        ProcessTableSnapshot(entries: parents.reduce(into: [:]) { table, pair in
            table[pair.key] = ProcessTableSnapshot.Entry(
                parent: pair.value, startedAt: startedAt[pair.key] ?? jobBorn)
        })
    }

    /// A live record at `pid` whose session id no terminal captured, with no
    /// pane, in a directory that is not the lane's — so nothing but descent
    /// could place it.
    private static func uncapturedEntry(pid: pid_t) throws -> PeerRegistryEntry {
        PeerRegistryEntry(pid: pid, record: try record(liveSessionFields(
            sessionID: "S-uncaptured-\(pid)", cwd: "/opt/peertest/elsewhere", name: "by-hand",
            pane: nil, socket: "/opt/peertest/socks/\(pid).sock")))
    }

    /// The case this join exists for: a Claude started inside a holder-backed
    /// shell tab — under the tab's shell, under a launcher — joins that tab,
    /// with nothing but the process tree to go on. Its working directory is
    /// deliberately not the lane's, so the join cannot be leaning on it.
    @Test func aSessionDescendedFromAHolderTabsJobJoinsThatTab() throws {
        let worktree = Self.worktree(displayName: "lane-a", path: Self.laneAPath)
        let tab = Self.holderTerminal(worktreeID: worktree.id, holderPID: 9000, childPID: 9001)
        let processes = Self.table([9000: 1, 9001: 9000, 9002: 9001, 9003: 9002])

        let result = Self.compose(
            scan: PeerRegistryScan(entries: [try Self.uncapturedEntry(pid: 9003)]),
            fleet: PeerListFleet(reachable: true, worktrees: [worktree], terminals: [tab]),
            processes: processes)

        let row = try #require(result.peers.first)
        #expect(row.kind == .local)
        #expect(row.terminalID == tab.id)
        #expect(row.worktreeID == worktree.id)
        #expect(row.joinedBy == .holderDescent)
        #expect(row.unjoinedReason == nil)
        #expect(row.tmuxPane == nil)
        #expect(peerBehindColumn(row).contains("found by process descent"))
        #expect(!result.warnings.contains { $0.contains("process table") })
    }

    /// The job itself counts as inside its tab: a Claude-kind holder tab whose
    /// `SessionStart` has not reported yet runs Claude as the job.
    @Test func theTabsJobItselfJoinsItsTab() throws {
        let worktree = Self.worktree(displayName: "lane-a", path: Self.laneAPath)
        let tab = Self.holderTerminal(
            worktreeID: worktree.id, kind: .claude, holderPID: 9000, childPID: 9001)

        let result = Self.compose(
            scan: PeerRegistryScan(entries: [try Self.uncapturedEntry(pid: 9001)]),
            fleet: PeerListFleet(reachable: true, worktrees: [worktree], terminals: [tab]),
            processes: Self.table([9000: 1, 9001: 9000]))

        let row = try #require(result.peers.first)
        #expect(row.kind == .local)
        #expect(row.terminalID == tab.id)
        #expect(row.joinedBy == .holderDescent)
    }

    @Test func aSessionNoHolderTabsJobIsAnAncestorOfStaysExternal() throws {
        let worktree = Self.worktree(displayName: "lane-a", path: Self.laneAPath)
        let tab = Self.holderTerminal(worktreeID: worktree.id, holderPID: 9000, childPID: 9001)
        // A plain-terminal `claude`: under a shell no TBD tab started.
        let processes = Self.table([9000: 1, 9001: 9000, 9500: 1, 9501: 9500])

        let result = Self.compose(
            scan: PeerRegistryScan(entries: [try Self.uncapturedEntry(pid: 9501)]),
            fleet: PeerListFleet(reachable: true, worktrees: [worktree], terminals: [tab]),
            processes: processes)

        let row = try #require(result.peers.first)
        #expect(row.kind == .external)
        #expect(row.terminalID == nil)
        #expect(row.joinedBy == nil)
        #expect(row.unjoinedReason == .noTerminal)
        #expect(peerBehindColumn(row).contains("not joined to a TBD tab"))
    }

    /// The captured session id is the join TBD wrote both sides of, so it wins
    /// even when the process tree points somewhere else.
    @Test func aCapturedSessionIDBeatsDescent() throws {
        let worktree = Self.worktree(displayName: "lane-a", path: Self.laneAPath)
        let named = Self.holderTerminal(
            worktreeID: worktree.id, kind: .claude, holderPID: 9100, childPID: 9101,
            claudeSessionID: "S-named")
        let around = Self.holderTerminal(worktreeID: worktree.id, holderPID: 9000, childPID: 9001)
        let processes = Self.table([9000: 1, 9001: 9000, 9100: 1, 9101: 9100, 9002: 9001])
        let entry = PeerRegistryEntry(pid: 9002, record: try Self.record(Self.liveSessionFields(
            sessionID: "S-named", cwd: Self.laneAPath, name: "lane-a",
            pane: nil, socket: "/opt/peertest/socks/9002.sock")))

        let result = Self.compose(
            scan: PeerRegistryScan(entries: [entry]),
            fleet: PeerListFleet(
                reachable: true, worktrees: [worktree], terminals: [named, around]),
            processes: processes)

        let row = try #require(result.peers.first)
        #expect(row.terminalID == named.id)
        #expect(row.joinedBy == .sessionID)
        // Kept, but not silently: the tree says the session runs elsewhere.
        #expect(result.warnings.contains {
            $0.contains("joined to terminal \(shortPeerID(named.id))")
                && $0.contains("inside terminal \(shortPeerID(around.id))")
        }, "got: \(result.warnings)")
    }

    /// The ordinary case draws no such warning: a session joined by its id
    /// that also descends from that same tab's job agrees with itself.
    @Test func aCapturedJoinTheTreeAgreesWithDrawsNoWarning() throws {
        let worktree = Self.worktree(displayName: "lane-a", path: Self.laneAPath)
        let tab = Self.holderTerminal(
            worktreeID: worktree.id, kind: .claude, holderPID: 9000, childPID: 9001,
            claudeSessionID: "S-tab")
        let entry = PeerRegistryEntry(pid: 9001, record: try Self.record(Self.liveSessionFields(
            sessionID: "S-tab", cwd: Self.laneAPath, name: "lane-a",
            pane: nil, socket: "/opt/peertest/socks/9001.sock")))

        let result = Self.compose(
            scan: PeerRegistryScan(entries: [entry]),
            fleet: PeerListFleet(reachable: true, worktrees: [worktree], terminals: [tab]),
            processes: Self.table([9000: 1, 9001: 9000]))

        #expect(result.peers.first?.joinedBy == .sessionID)
        #expect(!result.warnings.contains { $0.contains("its process runs inside") })
    }

    /// A tab whose own session is joined by its captured id is not handed to a
    /// second session by descent: the second one sits inside the tab, but the
    /// tab already has its answer.
    @Test func aSessionInsideATabJoinedBySessionIDStaysExternal() throws {
        let worktree = Self.worktree(displayName: "lane-a", path: Self.laneAPath)
        let tab = Self.holderTerminal(
            worktreeID: worktree.id, kind: .claude, holderPID: 9000, childPID: 9001,
            claudeSessionID: "S-tab")
        let processes = Self.table([9000: 1, 9001: 9000, 9002: 9001, 9003: 9002])
        let own = PeerRegistryEntry(pid: 9001, record: try Self.record(Self.liveSessionFields(
            sessionID: "S-tab", cwd: Self.laneAPath, name: "lane-a",
            pane: nil, socket: "/opt/peertest/socks/9001.sock")))

        let result = Self.compose(
            scan: PeerRegistryScan(entries: [own, try Self.uncapturedEntry(pid: 9003)]),
            fleet: PeerListFleet(reachable: true, worktrees: [worktree], terminals: [tab]),
            processes: processes)

        let joined = try #require(result.peers.first { $0.pid == 9001 })
        #expect(joined.terminalID == tab.id)
        #expect(joined.joinedBy == .sessionID)
        let nested = try #require(result.peers.first { $0.pid == 9003 })
        #expect(nested.kind == .external)
        #expect(nested.terminalID == nil)
        #expect(nested.unjoinedReason == .terminalJoinedBySessionID)
    }

    /// A Claude tab's identity is the session TBD captured for it. While the
    /// tab's own record is not listed — starting up, or between a `/clear`
    /// and its new record — a session its Claude started underneath (a
    /// `claude -p`) is the only one descent can see, and it must not become
    /// the tab's identity for want of the real one.
    @Test func aClaudeTabsCapturedSessionIsItsIdentityEvenWhenUnlisted() throws {
        let worktree = Self.worktree(displayName: "lane-a", path: Self.laneAPath)
        let tab = Self.holderTerminal(
            worktreeID: worktree.id, kind: .claude, holderPID: 9000, childPID: 9001,
            claudeSessionID: "S-tab")
        let processes = Self.table([9000: 1, 9001: 9000, 9002: 9001, 9003: 9002])

        let result = Self.compose(
            scan: PeerRegistryScan(entries: [try Self.uncapturedEntry(pid: 9003)]),
            fleet: PeerListFleet(reachable: true, worktrees: [worktree], terminals: [tab]),
            processes: processes)

        let row = try #require(result.peers.first)
        #expect(row.kind == .external)
        #expect(row.terminalID == nil)
        #expect(row.unjoinedReason == .terminalCapturedAnotherSession)
    }

    /// The same shape in a SHELL tab that carries a session id still joins:
    /// a shell tab has no captured identity, whatever id its row carries, so
    /// descent is the only answer there is for it.
    @Test func aShellTabCarryingASessionIDStillJoinsByDescent() throws {
        let worktree = Self.worktree(displayName: "lane-a", path: Self.laneAPath)
        let tab = Self.holderTerminal(
            worktreeID: worktree.id, holderPID: 9000, childPID: 9001,
            claudeSessionID: "S-stale")
        let processes = Self.table([9000: 1, 9001: 9000, 9002: 9001, 9003: 9002])

        let result = Self.compose(
            scan: PeerRegistryScan(entries: [try Self.uncapturedEntry(pid: 9003)]),
            fleet: PeerListFleet(reachable: true, worktrees: [worktree], terminals: [tab]),
            processes: processes)

        let row = try #require(result.peers.first)
        #expect(row.kind == .local)
        #expect(row.terminalID == tab.id)
        #expect(row.joinedBy == .holderDescent)
    }

    /// Each way a row stops vouching for its recorded job, and so stops
    /// anchoring the walk: parked, its holder gone, its job no longer the
    /// holder's child, or its job born outside the identity window — the last
    /// two are what a reused pid looks like.
    @Test(arguments: ["parked", "holder dead", "job reparented", "job too young"])
    func aRowThatNoLongerVouchesForItsJobNeverJoins(state: String) throws {
        let worktree = Self.worktree(displayName: "lane-a", path: Self.laneAPath)
        let tab = Self.holderTerminal(
            worktreeID: worktree.id, holderPID: 9000, childPID: 9001,
            parked: state == "parked")
        var parents: [pid_t: pid_t] = [9000: 1, 9001: 9000, 9002: 9001]
        var startedAt: [pid_t: Date] = [:]
        switch state {
        case "holder dead":
            parents[9000] = nil
            parents[9001] = 1
        case "job reparented":
            parents[9001] = 1
        case "job too young":
            startedAt[9001] = Self.jobBorn.addingTimeInterval(
                HolderChildIdentity.startWindow + 60)
        default:
            break
        }

        let result = Self.compose(
            scan: PeerRegistryScan(entries: [try Self.uncapturedEntry(pid: 9002)]),
            fleet: PeerListFleet(reachable: true, worktrees: [worktree], terminals: [tab]),
            processes: Self.table(parents, startedAt: startedAt))

        let row = try #require(result.peers.first)
        #expect(row.kind == .external, "a \(state) row joined a session")
        #expect(row.terminalID == nil)
        #expect(row.unjoinedReason == .noTerminal)
    }

    /// Two sessions inside one tab: the one nearer the tab's job answers for
    /// the tab — here the outer session, with the second started under it —
    /// and the other stays `external`, saying why.
    @Test func ofTwoSessionsInOneTabTheNearerJoins() throws {
        let worktree = Self.worktree(displayName: "lane-a", path: Self.laneAPath)
        let tab = Self.holderTerminal(worktreeID: worktree.id, holderPID: 9000, childPID: 9001)
        let processes = Self.table([9000: 1, 9001: 9000, 9002: 9001, 9003: 9002, 9004: 9003])

        let result = Self.compose(
            scan: PeerRegistryScan(entries: [
                try Self.uncapturedEntry(pid: 9002), try Self.uncapturedEntry(pid: 9004),
            ]),
            fleet: PeerListFleet(reachable: true, worktrees: [worktree], terminals: [tab]),
            processes: processes)

        let outer = try #require(result.peers.first { $0.pid == 9002 })
        #expect(outer.kind == .local)
        #expect(outer.terminalID == tab.id)
        let inner = try #require(result.peers.first { $0.pid == 9004 })
        #expect(inner.kind == .external)
        #expect(inner.terminalID == nil)
        #expect(inner.unjoinedReason == .nearerSessionInTerminal)
        #expect(peerBehindColumn(inner).contains("below a nearer session"))
        // The lead names the missing join, not where the session came from: a
        // session inside a TBD tab cannot also read as one TBD never touched.
        #expect(peerBehindColumn(inner).hasPrefix("not joined to a TBD tab · inside a TBD tab"))
    }

    /// Two sessions equally near one tab's job — siblings under its shell —
    /// cannot be told apart from the process tree, so neither is named the
    /// tab's.
    @Test func twoSessionsEquallyNearOneTabsJobNeitherJoins() throws {
        let worktree = Self.worktree(displayName: "lane-a", path: Self.laneAPath)
        let tab = Self.holderTerminal(worktreeID: worktree.id, holderPID: 9000, childPID: 9001)
        let processes = Self.table([9000: 1, 9001: 9000, 9002: 9001, 9003: 9001])

        let result = Self.compose(
            scan: PeerRegistryScan(entries: [
                try Self.uncapturedEntry(pid: 9002), try Self.uncapturedEntry(pid: 9003),
            ]),
            fleet: PeerListFleet(reachable: true, worktrees: [worktree], terminals: [tab]),
            processes: processes)

        #expect(result.peers.count == 2)
        for row in result.peers {
            #expect(row.kind == .external)
            #expect(row.terminalID == nil)
            #expect(row.unjoinedReason == .tiedInTerminal)
        }
    }

    /// The tmux transport's joins are untouched by a process table in hand: a
    /// pane still joins its tmux terminal, by pane.
    @Test func aTmuxSessionStillJoinsByPaneWithAProcessTableInHand() throws {
        let worktree = Self.worktree(displayName: "lane-a", path: Self.laneAPath)
        let terminal = Self.terminal(worktreeID: worktree.id, pane: "%77")
        let entry = PeerRegistryEntry(pid: 4002, record: try Self.record(Self.liveSessionFields(
            cwd: Self.laneAPath, name: "lane-a", pane: "%77",
            socket: "/opt/peertest/socks/4002.sock")))

        let result = Self.compose(
            scan: PeerRegistryScan(entries: [entry]),
            fleet: PeerListFleet(reachable: true, worktrees: [worktree], terminals: [terminal]),
            processes: Self.table([4001: 1, 4002: 4001]))

        let row = try #require(result.peers.first)
        #expect(row.kind == .local)
        #expect(row.terminalID == terminal.id)
        #expect(row.joinedBy == .tmuxPane)
        #expect(row.tmuxPane == "%77")
    }

    /// No process table, no descent — and the listing says so, rather than
    /// letting a holder session's `external` read as a fact about it.
    @Test func anUnreadableProcessTableLeavesHolderSessionsExternalAndSaysWhy() throws {
        let worktree = Self.worktree(displayName: "lane-a", path: Self.laneAPath)
        let tab = Self.holderTerminal(worktreeID: worktree.id, holderPID: 9000, childPID: 9001)

        let result = Self.compose(
            scan: PeerRegistryScan(entries: [try Self.uncapturedEntry(pid: 9002)]),
            fleet: PeerListFleet(reachable: true, worktrees: [worktree], terminals: [tab]),
            processes: nil)

        let row = try #require(result.peers.first)
        #expect(row.kind == .external)
        #expect(row.unjoinedReason == .processTableUnreadable)
        #expect(result.warnings.contains { $0.contains("process table could not be read") })
    }

    /// The two new fields are additive: present when they say something,
    /// absent otherwise, and every field a program already reads is unchanged.
    @Test func jsonCarriesHowARowWasJoinedAndWhyOneWasNot() throws {
        let worktree = Self.worktree(displayName: "lane-a", path: Self.laneAPath)
        let tab = Self.holderTerminal(worktreeID: worktree.id, holderPID: 9000, childPID: 9001)
        let processes = Self.table([9000: 1, 9001: 9000, 9002: 9001, 9500: 1])

        let result = Self.compose(
            scan: PeerRegistryScan(entries: [
                try Self.uncapturedEntry(pid: 9002), try Self.uncapturedEntry(pid: 9500),
            ]),
            fleet: PeerListFleet(reachable: true, worktrees: [worktree], terminals: [tab]),
            processes: processes)

        let json = try #require(jsonString(result))
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let peers = try #require(object["peers"] as? [[String: Any]])
        let joined = try #require(peers.first { ($0["pid"] as? Int) == 9002 })
        #expect(joined["kind"] as? String == "local")
        #expect(joined["terminalID"] as? String == tab.id.uuidString)
        #expect(joined["worktreeID"] as? String == worktree.id.uuidString)
        #expect(joined["joinedBy"] as? String == "holderDescent")
        #expect(joined["unjoinedReason"] == nil)
        let outside = try #require(peers.first { ($0["pid"] as? Int) == 9500 })
        #expect(outside["kind"] as? String == "external")
        #expect(outside["terminalID"] == nil)
        #expect(outside["joinedBy"] == nil)
        #expect(outside["unjoinedReason"] as? String == "noTerminal")
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
