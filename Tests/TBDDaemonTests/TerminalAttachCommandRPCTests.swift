import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 2 — dry-run tmux, in-memory database, injected socket resolver.
///
/// `terminal.attachCommand` composes a command a human pastes into another
/// emulator. It gates that composition on the SAME `paneSendTarget` probe
/// `terminal.send` runs before it types, so these prove which answers refuse
/// with which state named, which still compose, and — the one that matters most
/// — that the pane id handed back is the pane id the probe actually answered
/// for, never a value resolved a second time.
@Suite("terminal.attachCommand")
struct TerminalAttachCommandRPCTests {

    // MARK: - Fixture

    /// What the fixture's pane answers when asked who it is.
    private enum PaneAnswer: Sendable {
        case missing
        case dead
        /// Alive, carrying no identity at all — a pane spawned before TBD
        /// stamped one, or by something outside TBD.
        case unstamped
        /// Alive, answering with the requested terminal's own id.
        case matching
        /// Alive, answering with the requested id spelled in the other case.
        case matchingLowercased
        /// Alive, answering with somebody else's id.
        case stranger(String)
    }

    /// Lets the dryRun hook — constructed before the terminal row exists —
    /// answer with that terminal's id once it does, and records the pane id the
    /// probe was actually asked about.
    private final class ProbeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _terminalID = ""
        private var _askedPaneIDs: [String] = []
        var terminalID: String {
            get { lock.lock(); defer { lock.unlock() }; return _terminalID }
            set { lock.lock(); defer { lock.unlock() }; _terminalID = newValue }
        }
        var askedPaneIDs: [String] {
            lock.lock(); defer { lock.unlock() }
            return _askedPaneIDs
        }
        func recordAsk(_ paneID: String) {
            lock.lock(); defer { lock.unlock() }
            _askedPaneIDs.append(paneID)
        }
    }

    private struct Fixture {
        let router: RPCRouter
        let worktree: Worktree
        let terminal: Terminal
        let probe: ProbeBox
        let socketDirectory: String
    }

    /// The uid the injected resolver answers with. Deliberately not the real
    /// one, so a socket path assertion cannot pass by accidentally agreeing
    /// with the machine running the test.
    private static let fixtureUID: uid_t = 4242
    private static let fixtureTmpDir = "/tmp/tbd-attach-fixture"

    private func makeFixture(
        answer: PaneAnswer, paneID: String = "%7", windowID: String = "@3"
    ) async throws -> Fixture {
        let probe = ProbeBox()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunPaneSendTarget: { _, askedPaneID in
                probe.recordAsk(askedPaneID)
                switch answer {
                case .missing: return .missing
                case .dead: return .dead(terminalID: probe.terminalID)
                case .unstamped: return .live(terminalID: nil)
                case .matching: return .live(terminalID: probe.terminalID)
                case .matchingLowercased: return .live(terminalID: probe.terminalID.lowercased())
                case .stranger(let other): return .live(terminalID: other)
                }
            })
        let db = try TBDDatabase(inMemory: true)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-attach-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            startTime: Date(),
            tmuxSocketPathResolver: TmuxSocketPathResolver(
                environment: ["TMUX_TMPDIR": Self.fixtureTmpDir], uid: Self.fixtureUID),
            actuationLog: ActuationLog(
                path: directory.appendingPathComponent("actuations.jsonl").path))
        let repo = try await db.repos.create(
            path: "/tmp/acme-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "acme-wt", branch: "main",
            path: FileManager.default.temporaryDirectory.path, tmuxServer: "tbd-acme")
        let terminal = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: windowID, tmuxPaneID: paneID)
        probe.terminalID = terminal.id.uuidString
        return Fixture(
            router: router, worktree: worktree, terminal: terminal, probe: probe,
            socketDirectory: "\(Self.fixtureTmpDir)/tmux-\(Self.fixtureUID)")
    }

    private func attachCommand(
        _ fixture: Fixture, worktreeID: UUID? = nil, terminalID: UUID? = nil
    ) async throws -> RPCResponse {
        await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalAttachCommand,
            params: TerminalAttachCommandParams(
                worktreeID: worktreeID ?? fixture.worktree.id,
                terminalID: terminalID ?? fixture.terminal.id)))
    }

    // MARK: - Composition

    @Test("a live pane that agrees composes the spec's command against the daemon's socket path")
    func livePaneComposes() async throws {
        let fixture = try await makeFixture(answer: .matching)
        let response = try await attachCommand(fixture)
        #expect(response.success, "unexpected error: \(response.error ?? "-")")
        let result = try response.decodeResult(TerminalAttachCommandResult.self)

        let expectedSocket = "\(fixture.socketDirectory)/tbd-acme"
        let expectedSession = ExternalAttachCommand.sessionName(for: fixture.terminal.id)
        #expect(result.socketPath == expectedSocket)
        #expect(result.sessionName == expectedSession)
        #expect(result.windowID == "@3")
        #expect(result.terminalID == fixture.terminal.id)
        // The script is pinned WHOLE in `ExternalAttachCommandTests`; here the
        // contract is only that the handler fed it the coordinates it reports.
        #expect(result.script == ExternalAttachCommand.script(
            socketPath: expectedSocket, sessionName: expectedSession, windowID: "@3"))
    }

    @Test("an unstamped pane composes — absence of identity is not disagreement")
    func unstampedPaneComposes() async throws {
        // A pane spawned before TBD stamped identities answers with nothing.
        // Refusing on nothing would turn the identity check into a regression
        // for every such pane, which is exactly how `terminal.send` and
        // `terminal.wake` already behave.
        let fixture = try await makeFixture(answer: .unstamped)
        let response = try await attachCommand(fixture)
        #expect(response.success, "unexpected error: \(response.error ?? "-")")
        let result = try response.decodeResult(TerminalAttachCommandResult.self)
        #expect(result.paneID == "%7")
    }

    // MARK: - The pane id is the probe's

    @Test("the reported pane id is the one the identity probe answered for")
    func reportedPaneIDIsTheProbedOne() async throws {
        // The point of the test: `askedPaneIDs` is obtainable ONLY from inside
        // the probe. A handler that resolved the pane a second way — from the
        // window, from a fresh tmux query — would report a value this fixture's
        // probe never saw, and the equality below would fail. Reused pane
        // coordinates sending daemon keystrokes into a stranger's session
        // (issue #384) is what a second, possibly-disagreeing resolution costs.
        let fixture = try await makeFixture(answer: .matching, paneID: "%7")
        let response = try await attachCommand(fixture)
        let result = try response.decodeResult(TerminalAttachCommandResult.self)
        #expect(fixture.probe.askedPaneIDs == ["%7"], "the probe must run exactly once")
        #expect(result.paneID == fixture.probe.askedPaneIDs.first)
    }

    @Test("a terminal on a differently-numbered pane reports ITS pane, not a fixture constant")
    func reportedPaneIDFollowsTheTerminal() async throws {
        // Guards the equality above against passing on a hardcoded "%7".
        let fixture = try await makeFixture(answer: .matching, paneID: "%91")
        let result = try await attachCommand(fixture)
            .decodeResult(TerminalAttachCommandResult.self)
        #expect(fixture.probe.askedPaneIDs == ["%91"])
        #expect(result.paneID == "%91")
    }

    // MARK: - Refusals, each naming its own state

    @Test("a missing pane is refused as a window that no longer exists")
    func missingPaneRefused() async throws {
        let fixture = try await makeFixture(answer: .missing)
        let response = try await attachCommand(fixture)
        #expect(!response.success)
        let error = try #require(response.error)
        #expect(error.contains("no longer exists"))
        #expect(response.errorCode == RPCErrorCode.terminalSessionGone.rawValue)
    }

    @Test("a dead pane is refused as a dead process, not as a missing one")
    func deadPaneRefused() async throws {
        let fixture = try await makeFixture(answer: .dead)
        let response = try await attachCommand(fixture)
        #expect(!response.success)
        let error = try #require(response.error)
        #expect(error.contains("is dead"))
        // Distinct from the missing case: attaching to a `remain-on-exit`
        // corpse succeeds at the tmux level and shows a frozen screen, so the
        // two failures need different words.
        #expect(!error.contains("no longer exists"))
        #expect(response.errorCode == RPCErrorCode.terminalSessionGone.rawValue)
    }

    @Test("a pane claiming another terminal's id is refused, naming the stranger")
    func strangerPaneRefused() async throws {
        let stranger = UUID().uuidString
        let fixture = try await makeFixture(answer: .stranger(stranger))
        let response = try await attachCommand(fixture)
        #expect(!response.success)
        let error = try #require(response.error)
        #expect(error.contains(stranger))
        #expect(error.contains("stale"))
        #expect(response.errorCode == RPCErrorCode.terminalSessionGone.rawValue)
    }

    @Test("case-insensitive agreement is agreement, not a stranger")
    func lowercasedIdentityStillAgrees() async throws {
        // tmux hands the pane option back verbatim while Foundation stringifies
        // a UUID uppercase, and hex case is not identity. A case-sensitive
        // compare would refuse every terminal whose pane answered in lowercase.
        let fixture = try await makeFixture(answer: .matchingLowercased)
        #expect(fixture.terminal.id.uuidString
            != fixture.terminal.id.uuidString.lowercased(), "UUIDs stringify uppercase")
        let response = try await attachCommand(fixture)
        #expect(response.success, "unexpected error: \(response.error ?? "-")")
    }

    // MARK: - Unresolvable arguments

    @Test("an unknown terminal id is refused before anything is probed")
    func unknownTerminalRefused() async throws {
        let fixture = try await makeFixture(answer: .matching)
        let response = try await attachCommand(fixture, terminalID: UUID())
        #expect(!response.success)
        #expect(try #require(response.error).contains("No terminal"))
        #expect(fixture.probe.askedPaneIDs.isEmpty)
    }

    @Test("an unknown worktree id is refused")
    func unknownWorktreeRefused() async throws {
        let fixture = try await makeFixture(answer: .matching)
        let response = try await attachCommand(fixture, worktreeID: UUID())
        #expect(!response.success)
        #expect(try #require(response.error).contains("No local worktree"))
    }

    @Test("a terminal that belongs to another worktree is refused rather than preferring one id")
    func mismatchedPairRefused() async throws {
        // The pair names a server and a window. A mismatch would compose a
        // command pointing one repo's socket at another repo's window.
        let fixture = try await makeFixture(answer: .matching)
        let otherRepo = try await fixture.router.db.repos.create(
            path: "/tmp/acme-other-\(UUID().uuidString)", displayName: "other",
            defaultBranch: "main")
        let otherWorktree = try await fixture.router.db.worktrees.create(
            repoID: otherRepo.id, name: "other-wt", branch: "main",
            path: FileManager.default.temporaryDirectory
                .appendingPathComponent("other-wt-\(UUID().uuidString)").path,
            tmuxServer: "tbd-other")
        let response = try await attachCommand(fixture, worktreeID: otherWorktree.id)
        #expect(!response.success)
        #expect(try #require(response.error).contains("belongs to worktree"))
        #expect(fixture.probe.askedPaneIDs.isEmpty, "nothing is probed on a mismatched pair")
    }
}
