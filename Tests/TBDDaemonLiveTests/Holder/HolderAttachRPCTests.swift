import Darwin
import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// `attach.request` and `attach.ready` for a holder-backed row, driven through
/// the router rather than the registry.
///
/// The suite next door exercises the ownership rules; this one exercises the
/// layer around them, which owns the two things a registry test cannot see:
/// **the descriptor's lifetime** — vended, then closed, and closed again on
/// every failure path — and **the branch that decides a request is a holder
/// request at all.** Both are the kind of code that looks obviously right and
/// leaks anyway.
///
/// **Tier 3.** A real `TBDHolder`, a real pty, a real `socketpair` standing in
/// for the app's sidecar, and a real `SCM_RIGHTS` hand-over across it.
@Suite(.serialized)
struct HolderAttachRPCTests {

    private static let echoJob = "while IFS= read -r line; do printf 'GOT:%s\\n' \"$line\"; done"

    // MARK: - The vend

    @Test func aHolderAttachVendsThePtyAndAnswersWithItsScreen() async throws {
        let harness = try await RPCHarness.start(command: Self.echoJob)
        defer { harness.tearDown() }

        try await harness.fixture.reader.write(Data("BEFORE-RPC\n".utf8))
        #expect(await pollUntil("the job's answer before the attach") {
            await harness.fixture.reader.renderScreen().contains("GOT:BEFORE-RPC")
        })

        let attachID = UUID()
        let response = await harness.router.handle(
            try RPCRequest(
                method: RPCMethod.attachRequest,
                params: AttachRequestParams(
                    worktreeID: harness.worktreeID, paneID: "", windowID: "",
                    attachID: attachID, terminalID: harness.terminalID)))
        #expect(response.success)
        let result = try response.decodeResult(AttachRequestResult.self)
        #expect(result.status == "pending")
        #expect(result.generation != nil)
        let preamble = try #require(result.snapshotPreamble)
        #expect(String(bytes: preamble, encoding: .utf8)?.contains("GOT:BEFORE-RPC") == true)

        // The descriptor really crossed the sidecar, carrying the identity the
        // app demuxes on.
        let (vendedFD, header) = try SidecarTestSupport.receiveVend(from: harness.appSide)
        defer { Darwin.close(vendedFD) }
        #expect(header.worktreeID == harness.worktreeID)
        #expect(header.attachID == attachID)
        #expect(vendedFD >= 0)

        // And it is a live pty: the daemon has stopped reading, so everything
        // the job says now belongs to whoever holds this.
        try harness.write(fd: vendedFD, "AFTER-RPC\n")
        #expect(readPTYUntil(fd: vendedFD, contains: "GOT:AFTER-RPC") != nil)
        #expect(await !harness.fixture.reader.isDraining)
    }

    /// The daemon's own copy of the descriptor is closed once the kernel has
    /// duplicated it into the app — on the success path and on the failure path
    /// alike.
    ///
    /// Measured by counting this process's open descriptors across repeated
    /// attaches, because that is the only thing that can see the leak: a
    /// forgotten `close` produces a perfectly working attach and a file table
    /// that grows by one per tab switch, for the life of the daemon.
    @Test func repeatedAttachesLeakNoDescriptors() async throws {
        let harness = try await RPCHarness.start(command: Self.echoJob)
        defer { harness.tearDown() }

        // One round first: the first attach through any of this allocates
        // whatever it allocates once, and counting from before that would
        // measure the warm-up rather than the leak.
        try await harness.attachAndAcknowledge()
        let baseline = openDescriptorCount()
        let rounds = 6
        for _ in 0..<rounds {
            try await harness.attachAndAcknowledge()
        }
        let leaked = openDescriptorCount() - baseline
        // The count is process-global and other suites run in parallel, so a
        // small slack absorbs their noise. It is far below what the bug costs:
        // a dropped close leaks one descriptor per attach, so six rounds put
        // six over the line while a couple of unrelated sockets do not.
        #expect(
            leaked <= 2,
            """
            \(rounds) attach round trips left \(leaked) descriptors behind; a vended pty the \
            daemon forgets to close keeps that terminal alive for the life of the process
            """)
    }

    /// A vend that could not be delivered closes the descriptor and puts the
    /// daemon back on the pty.
    ///
    /// The sidecar has no client at all here, so `send` fails without ever
    /// reaching `sendmsg` — which is exactly the evidence
    /// `.descriptorNeverDelivered` rests on. Leaving the drain suspended for
    /// this failure would strand a session whose descriptor never left the
    /// process.
    @Test func aVendWithNoSidecarClientResumesTheDrain() async throws {
        let harness = try await RPCHarness.start(command: Self.echoJob, connectSidecar: false)
        defer { harness.tearDown() }

        let response = await harness.router.handle(
            try RPCRequest(
                method: RPCMethod.attachRequest,
                params: AttachRequestParams(
                    worktreeID: harness.worktreeID, paneID: "", windowID: "",
                    attachID: UUID(), terminalID: harness.terminalID)))
        #expect(!response.success)

        try await harness.fixture.reader.write(Data("RESUMED\n".utf8))
        #expect(
            await pollUntil("the daemon to be draining again after a failed vend") {
                await harness.fixture.reader.renderScreen().contains("GOT:RESUMED")
            },
            "a vend that never left the process left the session unread")
        #expect(await harness.registry.viewerAttachment(for: harness.terminalID) == nil)
    }

    /// The failure path closes its descriptor too — the arm that is easy to get
    /// wrong, because an attach that failed looks finished.
    ///
    /// Counted over several rounds with slack rather than exactly, for the
    /// reason the success-path twin gives: the file table is process-global and
    /// other suites run beside this one.
    @Test func repeatedFailedVendsLeakNoDescriptors() async throws {
        let harness = try await RPCHarness.start(command: Self.echoJob, connectSidecar: false)
        defer { harness.tearDown() }

        let request = try RPCRequest(
            method: RPCMethod.attachRequest,
            params: AttachRequestParams(
                worktreeID: harness.worktreeID, paneID: "", windowID: "",
                attachID: UUID(), terminalID: harness.terminalID))
        #expect(!(await harness.router.handle(request)).success)
        let baseline = openDescriptorCount()
        let rounds = 6
        for _ in 0..<rounds {
            #expect(!(await harness.router.handle(request)).success)
        }
        let leaked = openDescriptorCount() - baseline
        #expect(
            leaked <= 2,
            """
            \(rounds) failed vends left \(leaked) descriptors behind; the copy that could not be \
            delivered is still this process's to close
            """)
    }

    /// What a failed vend proves about where the descriptor is.
    ///
    /// A short `sendmsg` is POSIX-legal and `FDChannel.sendFD` finishes the
    /// frame with a second write, so a throw from *that* leaves the app holding
    /// a live dup. It is the one send failure that must not resume the drain,
    /// and provoking it for real would mean filling a socket buffer mid-frame —
    /// so the mapping itself is asserted, which is where the decision lives.
    @Test func onlyASendThatNeverDeliveredTheDescriptorLicensesAResume() {
        #expect(
            RPCRouter.cancelReason(forVendFailure: FDChannelError.sendFailed(EPIPE))
                == .descriptorNeverDelivered)
        #expect(
            RPCRouter.cancelReason(forVendFailure: FDVendingServerError.notConnected)
                == .descriptorNeverDelivered)
        #expect(
            RPCRouter.cancelReason(
                forVendFailure: FDChannelError.descriptorSentFrameIncomplete(EPIPE))
                == .unacknowledged,
            """
            a send that got the descriptor out and then failed was treated as undelivered, so the \
            daemon would go back on a pty the app may already be reading
            """)
    }

    // MARK: - The branch

    /// A request that names no terminal is a control-mode request, and must not
    /// touch the holder path — the off-branch of the gate.
    ///
    /// Asserted on the session rather than on the response: the tmux side of
    /// this router is a dry run and its answer is uninteresting, while "did
    /// anything quiesce this reader" is exactly what the branch decides.
    @Test func aRequestWithoutATerminalIDLeavesHolderSessionsAlone() async throws {
        let harness = try await RPCHarness.start(command: Self.echoJob)
        defer { harness.tearDown() }

        _ = await harness.router.handle(
            try RPCRequest(
                method: RPCMethod.attachRequest,
                params: AttachRequestParams(
                    worktreeID: harness.worktreeID, paneID: "%0", windowID: "@0",
                    attachID: UUID())))

        #expect(await harness.fixture.reader.isDraining)
        #expect(await harness.registry.viewerAttachment(for: harness.terminalID) == nil)
        try await harness.fixture.reader.write(Data("STILL-MINE\n".utf8))
        #expect(await pollUntil("the daemon to still be draining its session") {
            await harness.fixture.reader.renderScreen().contains("GOT:STILL-MINE")
        })
    }

    /// Naming a terminal is not enough: the row's transport is the gate, so a
    /// tmux-backed row goes down the tmux path even when the app names it.
    @Test func aRequestNamingATmuxRowTakesTheControlModePath() async throws {
        let harness = try await RPCHarness.start(command: Self.echoJob)
        defer { harness.tearDown() }
        let tmuxRow = try await harness.db.terminals.create(
            worktreeID: harness.worktreeID, tmuxWindowID: "@7", tmuxPaneID: "%7")

        let response = await harness.router.handle(
            try RPCRequest(
                method: RPCMethod.attachRequest,
                params: AttachRequestParams(
                    worktreeID: harness.worktreeID, paneID: "%7", windowID: "@7",
                    attachID: UUID(), terminalID: tmuxRow.id)))

        // The answer has to be the control-mode path's, and only the answer can
        // say so: a tmux row sent down the holder path finds no reader for that
        // terminal and fails, while leaving this session's own reader draining
        // — so asserting on the session alone would pass either way. This
        // bridge's gate is off, which is what the tmux path replies then.
        #expect(response.success)
        #expect(
            try response.decodeResult(AttachRequestResult.self).status == "unavailable",
            """
            a tmux-backed row was answered by the holder path; the row's transport is the gate, \
            not the presence of a terminal id in the request
            """)
        #expect(await harness.fixture.reader.isDraining)
        #expect(await harness.registry.viewerAttachment(for: harness.terminalID) == nil)
    }

    /// With no registry wired — mock mode, or a daemon built without the
    /// transport — the answer is "unavailable" rather than an error, which is
    /// what puts the app back on its placard instead of into a retry loop.
    @Test func aHolderAttachWithoutARegistryIsUnavailable() async throws {
        let harness = try await RPCHarness.start(command: Self.echoJob)
        defer { harness.tearDown() }
        harness.router.holderRegistry = nil

        let response = await harness.router.handle(
            try RPCRequest(
                method: RPCMethod.attachRequest,
                params: AttachRequestParams(
                    worktreeID: harness.worktreeID, paneID: "", windowID: "",
                    attachID: UUID(), terminalID: harness.terminalID)))
        #expect(response.success)
        #expect(try response.decodeResult(AttachRequestResult.self).status == "unavailable")
        #expect(await harness.fixture.reader.isDraining)
    }

    // MARK: - The acknowledgement

    @Test func anAcknowledgementWithoutAGenerationIsRefused() async throws {
        let harness = try await RPCHarness.start(command: Self.echoJob)
        defer { harness.tearDown() }
        let vend = try await harness.attach()
        defer { Darwin.close(vend.fd) }

        // Nothing names the attach being acknowledged, and confirming the wrong
        // one would release a reader a live attach depends on.
        let response = await harness.router.handle(
            try RPCRequest(
                method: RPCMethod.attachReady,
                params: AttachReadyParams(
                    worktreeID: harness.worktreeID, paneID: "", generation: nil,
                    terminalID: harness.terminalID)))
        #expect(!response.success)
        #expect(await harness.registry.viewerAttachment(for: harness.terminalID) == nil)
    }

    @Test func anAcknowledgementNamingAnotherAttachIsRefused() async throws {
        let harness = try await RPCHarness.start(command: Self.echoJob)
        defer { harness.tearDown() }
        let vend = try await harness.attach()
        defer { Darwin.close(vend.fd) }

        let response = await harness.router.handle(
            try RPCRequest(
                method: RPCMethod.attachReady,
                params: AttachReadyParams(
                    worktreeID: harness.worktreeID, paneID: "",
                    generation: vend.generation &+ 17, terminalID: harness.terminalID)))
        #expect(!response.success)
        #expect(await harness.registry.viewerAttachment(for: harness.terminalID) == nil)
    }

    @Test func anAcknowledgementHandsTheSessionOver() async throws {
        let harness = try await RPCHarness.start(command: Self.echoJob)
        defer { harness.tearDown() }
        let vend = try await harness.attach()
        defer { Darwin.close(vend.fd) }

        let response = await harness.router.handle(
            try RPCRequest(
                method: RPCMethod.attachReady,
                params: AttachReadyParams(
                    worktreeID: harness.worktreeID, paneID: "",
                    generation: vend.generation, terminalID: harness.terminalID)))
        #expect(response.success)
        #expect(await harness.registry.viewerAttachment(for: harness.terminalID) == vend.generation)
        #expect(await harness.registry.reader(for: harness.terminalID) == nil)

        // The viewer's descriptor outlives the daemon's, which is the point of
        // handing over a dup rather than the reader's own.
        try harness.write(fd: vend.fd, "MINE-NOW\n")
        #expect(readPTYUntil(fd: vend.fd, contains: "GOT:MINE-NOW") != nil)
    }
}

// MARK: - Harness

/// A router with a live holder session behind it and a socketpair standing in
/// for the app's fd sidecar.
private struct RPCHarness {
    let router: RPCRouter
    let db: TBDDatabase
    let fixture: AttachRPCFixture
    let worktreeID: UUID
    /// The app's end of the sidecar. -1 when the test wants a vend to fail.
    let appSide: Int32

    var registry: HolderRegistry { fixture.registry }
    var terminalID: UUID { fixture.terminalID }

    static func start(command: String, connectSidecar: Bool = true) async throws -> RPCHarness {
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            actuationLog: makeTestActuationLog())
        let repo = try await db.repos.create(
            path: "/tmp/holder-attach-rpc", displayName: "holder-attach-rpc", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "holder-attach-rpc", branch: "main",
            path: "/tmp/holder-attach-rpc", tmuxServer: "tbd-holder-attach-rpc")

        let fixture = try await AttachRPCFixture.start(command: command)
        // The row the daemon resolves. Its tmux coordinates are empty by
        // construction, which is why `transport` is the only thing that can
        // discriminate it.
        _ = try await db.terminals.create(
            id: fixture.terminalID, worktreeID: worktree.id, tmuxWindowID: "", tmuxPaneID: "",
            transport: .holder)

        var appSide: Int32 = -1
        let vending = FDVendingServer(retryAttempts: 1)
        if connectSidecar {
            var pair: [Int32] = [-1, -1]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
                throw FDChannelError.sendFailed(errno)
            }
            await vending.adoptConnection(fd: pair[0])
            appSide = pair[1]
        }
        // The control-mode bridge is present only for its fd sidecar, which is
        // the one piece of it the holder path borrows. Its gate is deliberately
        // off: a holder attach must not depend on tmux's version.
        router.controlMode = TmuxControlModeBridge(
            supervisor: TmuxControlSupervisor(), environment: [:], fdVending: vending,
            readyTimeout: .seconds(600))
        router.holderRegistry = fixture.registry

        return RPCHarness(
            router: router, db: db, fixture: fixture, worktreeID: worktree.id, appSide: appSide)
    }

    /// One `attach.request`, with the vended descriptor received off the
    /// sidecar the way the app receives it.
    func attach() async throws -> (fd: Int32, generation: UInt64) {
        let response = await router.handle(
            try RPCRequest(
                method: RPCMethod.attachRequest,
                params: AttachRequestParams(
                    worktreeID: worktreeID, paneID: "", windowID: "", attachID: UUID(),
                    terminalID: terminalID)))
        let result = try response.decodeResult(AttachRequestResult.self)
        let (fd, _) = try SidecarTestSupport.receiveVend(from: appSide)
        return (fd, try #require(result.generation))
    }

    /// Attach, acknowledge, then give the session back so the next round can
    /// attach it again — the shape a tab switch makes.
    func attachAndAcknowledge() async throws {
        let vend = try await attach()
        _ = await router.handle(
            try RPCRequest(
                method: RPCMethod.attachReady,
                params: AttachReadyParams(
                    worktreeID: worktreeID, paneID: "", generation: vend.generation,
                    terminalID: terminalID)))
        Darwin.close(vend.fd)
        // Stands in for the detach the app has not learned to send yet: drop
        // the viewer's claim and re-adopt, which is what puts a reader back.
        await registry.release(terminalID: terminalID)
        _ = try await registry.adopt(terminal: fixture.terminalRow)
    }

    func write(fd: Int32, _ text: String) throws {
        try writePTY(fd: fd, text)
    }

    func tearDown() {
        if appSide >= 0 { Darwin.close(appSide) }
        fixture.tearDown()
    }
}

/// The live holder half of the harness: a real holder, and a registry that has
/// adopted it. Deliberately a separate type from the suite next door's fixture
/// — that one belongs to its own file's tests, and sharing it would couple two
/// suites' teardown.
private struct AttachRPCFixture {
    let process: HolderProcessFixture
    let registry: HolderRegistry
    let reader: HolderReader

    var terminalID: UUID { process.sessionID }

    var terminalRow: TBDShared.Terminal {
        TBDShared.Terminal(
            id: process.sessionID, worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "",
            transport: .holder)
    }

    static func start(command: String) async throws -> AttachRPCFixture {
        let process = try await HolderProcessFixture.start(
            launch: HolderProcessFixture.launch(command: command))
        await process.client.close()
        let registry = HolderRegistry(
            owner: process.owner,
            environment: HolderProcessFixture.environment(home: process.home),
            listTerminals: { [] })
        let row = TBDShared.Terminal(
            id: process.sessionID, worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "",
            transport: .holder)
        return AttachRPCFixture(
            process: process, registry: registry, reader: try await registry.adopt(terminal: row))
    }

    /// Waits for the release rather than firing and forgetting it — see the
    /// same note on the sibling suite's fixture.
    func tearDown() {
        let registry = self.registry
        let released = DispatchSemaphore(value: 0)
        Task.detached {
            await registry.releaseAll()
            released.signal()
        }
        if released.wait(timeout: .now() + 10) == .timedOut {
            Issue.record("the registry's readers were still releasing 10s after the test ended")
        }
        process.tearDown()
    }
}

/// How many descriptors this process currently has open.
///
/// Probed with `fcntl(F_GETFD)` across the table rather than read from a
/// directory, because `/dev/fd` on darwin opens a descriptor of its own to
/// answer and would count itself.
private func openDescriptorCount() -> Int {
    var open = 0
    var limit = rlimit()
    let ceiling = getrlimit(RLIMIT_NOFILE, &limit) == 0
        ? Int32(min(limit.rlim_cur, 4096))
        : 4096
    for fd in 0..<ceiling where fcntl(fd, F_GETFD) >= 0 {
        open += 1
    }
    return open
}
