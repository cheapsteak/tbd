import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

/// Tier 2: a real rendezvous directory with real (abandoned) unix sockets plus
/// an in-memory database. The holders base, the profiles base, the scratchpad
/// base, the clock, the handshake and the killer are all injected; nothing here
/// resolves a production path and **no process is spawned or signalled**.
///
/// The live half of this sweep — a real `TBDHolder`, really killed, and two
/// really left alone — is `OrphanGCRowlessHolderLiveTests` in
/// `TBDDaemonLiveTests`. This suite carries the gates that need no process:
/// the flag's three states, the grace window, and the row check.
///
/// Rooted directly under `/tmp` so the socket paths fit darwin's 104-byte
/// `sun_path`; removed in `deinit`.
@Suite("OrphanGC sweeps row-less pty holders")
struct OrphanGCRowlessHolderTests: ~Copyable {
    let fm = FileManager.default
    let sandbox: URL
    let holdersBase: URL
    let clock = Date(timeIntervalSince1970: 1_800_000_000)
    let owner = HolderOwnerToken(rawValue: "acme-installation")

    init() {
        sandbox = URL(
            fileURLWithPath: "/tmp/tbd-gcrh-\(UUID().uuidString.prefix(8))", isDirectory: true)
        holdersBase = sandbox.appendingPathComponent("h", isDirectory: true)
        try? fm.createDirectory(at: holdersBase, withIntermediateDirectories: true)
    }

    deinit { try? fm.removeItem(at: sandbox) }

    // MARK: - Fixtures

    /// Records every reclamation instead of performing one, so "left alone" is
    /// asserted as the absence of a call rather than inferred from a return
    /// value. `nothing was signalled` is the only shape four of these tests have.
    actor RecordingReclaimer: RowlessHolderReclaiming {
        struct Call: Equatable { var socketPath: String; var childPID: Int32; var holderPID: Int32? }
        private(set) var calls: [Call] = []
        func reclaim(socketPath: String, childPID: Int32, holderPID: Int32?) async {
            calls.append(Call(socketPath: socketPath, childPID: childPID, holderPID: holderPID))
        }
    }

    private func socketPath(_ id: UUID) -> String {
        holdersBase.appendingPathComponent("\(id.uuidString.lowercased()).sock").path
    }

    /// A bound-then-abandoned socket, backdated so the GC grace window has
    /// elapsed against this suite's fixed clock. A real socket rather than a
    /// plain file so `candidates()` sees what production sees.
    @discardableResult
    private func makeHolderSocket(_ id: UUID, age: TimeInterval = 86_400) -> String {
        let path = socketPath(id)
        #expect(HolderRendezvousFixture.bindAndAbandon(at: path))
        let created = clock.addingTimeInterval(-age)
        try? fm.setAttributes([.creationDate: created, .modificationDate: created],
                              ofItemAtPath: path)
        return path
    }

    private static func described(
        childPID: Int32 = 4242, owner: HolderOwnerToken, holderPID: Int32? = 4241
    ) -> RowlessHolderHandshake {
        .described(
            HolderChildDescription(
                childPID: childPID,
                ttyName: "/dev/ttys999",
                status: .alive,
                launch: HolderLaunchRequest(
                    executable: "/bin/sh", arguments: ["-c", "sleep 300"],
                    workingDirectory: "/tmp", environment: [:], columns: 80, rows: 24),
                owner: owner),
            holderPID: holderPID)
    }

    private func makeGC(
        db: TBDDatabase,
        reclaimer: RecordingReclaimer,
        handshake: @escaping @Sendable (String) async -> RowlessHolderHandshake
    ) -> OrphanGC {
        let fixed = clock
        return OrphanGC(
            db: db, git: GitManager(),
            broadcast: { _ in },
            liveCWDsProvider: { [] },
            scratchpadBase: sandbox.appendingPathComponent("s", isDirectory: true),
            now: { fixed },
            profileDirBase: sandbox.appendingPathComponent("p", isDirectory: true),
            holdersBase: holdersBase,
            // The rendezvous sweep shares this directory and would unlink the
            // fixture out from under these assertions if it ever ran. It cannot:
            // its own flag is off. Pinned anyway so a future default flip does
            // not silently rewrite what this suite measures.
            holderListenerProbe: { _ in true },
            rowlessHolderHandshake: handshake,
            rowlessHolderReclaimer: reclaimer)
    }

    /// An installation that has minted a token and has a holder socket that no
    /// session row claims — the setup every test below varies one thing from.
    private func armedDatabase(enabled: Bool = true) async throws -> TBDDatabase {
        let db = try TBDDatabase(inMemory: true)
        _ = try await db.config.ensureHolderOwnerToken(minting: owner.rawValue)
        if enabled { try await db.config.setGCRowlessHoldersEnabled(true) }
        return db
    }

    // MARK: - The kill

    /// **The discriminating sweep test**, in its process-free form: a holder
    /// that handshakes, proves our owner token, is past the grace window and has
    /// no session row is reclaimed — child pid and holder pid both named.
    @Test func aRowlessHolderWeOwnIsReclaimed() async throws {
        let db = try await armedDatabase()
        let id = UUID()
        let path = makeHolderSocket(id)
        let reclaimer = RecordingReclaimer()
        let mine = owner

        let result = await makeGC(db: db, reclaimer: reclaimer, handshake: { _ in
            Self.described(childPID: 4242, owner: mine, holderPID: 4241)
        }).sweep()

        #expect(await reclaimer.calls == [
            .init(socketPath: path, childPID: 4242, holderPID: 4241)
        ])
        #expect(result.planned.contains("REAP rowless-holder \(path)"))
        #expect(result.reaped >= 1)
    }

    // MARK: - The four ways a holder is left alone

    /// Rule 1 and 2: a completed handshake proves liveness, not ownership. Two
    /// installations share the default `TBD_HOME`, so a healthy foreign session
    /// looks exactly like an orphan of ours until the token is compared.
    @Test func aDifferentOwnerTokenIsLeftAlone() async throws {
        let db = try await armedDatabase()
        let id = UUID()
        let path = makeHolderSocket(id)
        let reclaimer = RecordingReclaimer()

        let result = await makeGC(db: db, reclaimer: reclaimer, handshake: { _ in
            Self.described(owner: HolderOwnerToken(rawValue: "some-other-checkout"))
        }).sweep()

        #expect(await reclaimer.calls.isEmpty, "a foreign holder must never be signalled")
        #expect(result.planned.contains("KEEP foreign-owner \(path)"))
    }

    /// Rule 3: a rejected connection is terminal in both directions. The holder
    /// is alive and busy serving somebody — very often a stale daemon from
    /// another checkout, a known hazard on a development machine.
    @Test func aRejectedConnectionIsLeftAlone() async throws {
        let db = try await armedDatabase()
        let id = UUID()
        let path = makeHolderSocket(id)
        let reclaimer = RecordingReclaimer()

        let result = await makeGC(db: db, reclaimer: reclaimer, handshake: { _ in .rejected })
            .sweep()

        #expect(await reclaimer.calls.isEmpty, "a holder that refused us must never be killed")
        #expect(result.planned.contains("KEEP rejected \(path)"))
    }

    /// An unreadable answer keeps, the direction every gate in this sweep fails
    /// in.
    @Test func anUnreachableHolderIsLeftAlone() async throws {
        let db = try await armedDatabase()
        let id = UUID()
        let path = makeHolderSocket(id)
        let reclaimer = RecordingReclaimer()

        let result = await makeGC(db: db, reclaimer: reclaimer, handshake: { _ in
            .unreachable("timed out")
        }).sweep()

        #expect(await reclaimer.calls.isEmpty)
        #expect(result.planned.contains("KEEP unreachable \(path)"))
    }

    /// Rule 4: the keep-biased young-holder guard. `OrphanGC` runs on demand
    /// from RPC handlers, so a sweep can land between a holder becoming
    /// connectable and its row committing; killing there destroys a session
    /// being born. The old sibling in the same sweep proves the gate is the age
    /// and not the fixture.
    @Test func aHolderInsideTheGraceWindowIsLeftAlone() async throws {
        let db = try await armedDatabase()
        let young = UUID()
        let old = UUID()
        let youngPath = makeHolderSocket(young, age: 60)
        let oldPath = makeHolderSocket(old, age: 86_400)
        let reclaimer = RecordingReclaimer()
        let mine = owner

        let result = await makeGC(db: db, reclaimer: reclaimer, handshake: { _ in
            Self.described(owner: mine)
        }).sweep()

        #expect(result.planned.contains("KEEP grace \(youngPath)"))
        #expect(await reclaimer.calls.map(\.socketPath) == [oldPath],
                "only the holder past the grace window may be reclaimed")
    }

    /// A holder whose session row exists is claimed, and is not this sweep's
    /// business. The row check runs **before** any connect, so a claimed holder
    /// is never even probed — its single client slot belongs to the daemon.
    @Test func aHolderWithASessionRowIsLeftAlone() async throws {
        let db = try await armedDatabase()
        let repo = try await db.repos.create(
            path: "/tmp/gcrh-repo-\(UUID().uuidString)", displayName: "R", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/gcrh-wt-\(UUID().uuidString)", tmuxServer: "tbd-gcrh")
        let terminal = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            transport: .holder, holderPID: 4241, childPID: 4242)
        let path = makeHolderSocket(terminal.id)
        let reclaimer = RecordingReclaimer()
        let mine = owner

        let probed = Probe()
        let result = await makeGC(db: db, reclaimer: reclaimer, handshake: { _ in
            await probed.fire()
            return Self.described(owner: mine)
        }).sweep()

        #expect(await reclaimer.calls.isEmpty, "a claimed holder must never be signalled")
        #expect(await probed.fired == false,
                "a claimed holder must not even be connected to — the slot is the daemon's")
        #expect(result.planned.contains("KEEP has-row \(path)"))
    }

    /// An installation that never minted an owner token has never spawned a
    /// holder, so nothing out there can be ours. Every candidate is kept, and
    /// none is probed.
    @Test func anInstallationWithNoOwnerTokenKillsNothing() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCRowlessHoldersEnabled(true)
        let id = UUID()
        let path = makeHolderSocket(id)
        let reclaimer = RecordingReclaimer()
        let mine = owner

        let result = await makeGC(db: db, reclaimer: reclaimer, handshake: { _ in
            Self.described(owner: mine)
        }).sweep()

        #expect(await reclaimer.calls.isEmpty)
        #expect(result.planned.contains("KEEP no-owner-token \(path)"))
    }

    // MARK: - The gate

    /// The off branch — the state every install ships in. The same fixture the
    /// kill test reclaims is left completely alone, and the sweep does not even
    /// plan it.
    @Test func aSweepWithTheFlagOffKillsNothing() async throws {
        let db = try await armedDatabase(enabled: false)
        #expect(try await db.config.get().gcRowlessHoldersEnabled == false,
                "the shipped default must be off")
        let id = UUID()
        makeHolderSocket(id)
        let reclaimer = RecordingReclaimer()
        let mine = owner

        let result = await makeGC(db: db, reclaimer: reclaimer, handshake: { _ in
            Self.described(owner: mine)
        }).sweep()

        #expect(await reclaimer.calls.isEmpty)
        #expect(result.planned.contains { $0.contains("rowless-holder") } == false)
    }

    /// An explicit `false` is the same as never having chosen, for behavior.
    @Test func anExplicitOptOutKillsNothing() async throws {
        let db = try await armedDatabase(enabled: false)
        try await db.config.setGCRowlessHoldersEnabled(false)
        let id = UUID()
        makeHolderSocket(id)
        let reclaimer = RecordingReclaimer()
        let mine = owner
        _ = await makeGC(db: db, reclaimer: reclaimer, handshake: { _ in
            Self.described(owner: mine)
        }).sweep()
        #expect(await reclaimer.calls.isEmpty)
    }

    /// **The file sweep's flag does not arm the process killer.** Enabling
    /// `gcHolderRendezvousEnabled` alone must leave every holder running: the
    /// two gates are independent opt-ins precisely because one unlinks files and
    /// the other kills processes.
    @Test func theRendezvousFlagDoesNotArmTheProcessKiller() async throws {
        let db = try await armedDatabase(enabled: false)
        try await db.config.setGCHolderRendezvousEnabled(true)
        let id = UUID()
        makeHolderSocket(id)
        let reclaimer = RecordingReclaimer()
        let mine = owner

        let result = await makeGC(db: db, reclaimer: reclaimer, handshake: { _ in
            Self.described(owner: mine)
        }).sweep()

        #expect(await reclaimer.calls.isEmpty,
                "the rendezvous file gate must never license a kill")
        #expect(result.planned.contains { $0.contains("rowless-holder") } == false)
    }

    /// The GC master switch is read on top of the phase flag: both must be on.
    @Test func theMasterSwitchStillGovernsThePhase() async throws {
        let db = try await armedDatabase()
        try await db.config.setGCEnabled(false)
        let id = UUID()
        makeHolderSocket(id)
        let reclaimer = RecordingReclaimer()
        let mine = owner
        _ = await makeGC(db: db, reclaimer: reclaimer, handshake: { _ in
            Self.described(owner: mine)
        }).sweep()
        #expect(await reclaimer.calls.isEmpty)
    }

    /// `dryRun` bypasses the flag, exactly as it bypasses `gcEnabled`: someone
    /// deciding whether to turn a default-off process killer on needs to see
    /// what it would kill first. It plans and signals nothing.
    @Test func aDryRunPlansWithTheFlagOffAndKillsNothing() async throws {
        let db = try await armedDatabase(enabled: false)
        let id = UUID()
        let path = makeHolderSocket(id)
        let reclaimer = RecordingReclaimer()
        let mine = owner

        let result = await makeGC(db: db, reclaimer: reclaimer, handshake: { _ in
            Self.described(owner: mine)
        }).sweep(dryRun: true)

        #expect(result.planned.contains("REAP rowless-holder \(path)"))
        #expect(result.reaped == 0)
        #expect(await reclaimer.calls.isEmpty, "a dry run must never signal a process")
    }
}

/// A one-shot flag a `@Sendable` closure can set from anywhere.
private actor Probe {
    private(set) var fired = false
    func fire() { fired = true }
}
