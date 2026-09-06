import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared
import TestSupport

/// One live Claude terminal, a dry-run tmux that records what it was asked to
/// paste and press, and a router over an in-memory database.
///
/// The recording seams are `TmuxManager`'s own `dryRun*` hooks — the shape
/// `TerminalSendDispatchTests` already uses — so nothing about the production
/// path is stubbed out: the handler runs in full and the doubles only answer
/// the questions tmux and the process table would have.
///
/// Shared deliberately, by the delivery suite that introduced it and by the
/// authority, gate and holder suites that follow: one fixture over one handler
/// means a rail added for any of them is a rail all of them run through.
struct SendHarness {
    let router: RPCRouter
    let db: TBDDatabase
    let terminal: Terminal
    let tmux: TmuxDouble

    /// The foreground rail asks the process table whether the session's agent
    /// owns the pane. A live Claude row must answer yes, or every text send in
    /// every suite built on this harness is refused before it reaches the pane.
    struct StubInspector: PaneProcessInspecting {
        let foregroundByAgent: [String: Int32]
        func foregroundAgentPID(panePID: Int32, matching agentName: String) -> Int32? {
            foregroundByAgent[agentName]
        }
        /// The wake rail's question, which no send this harness makes ever
        /// asks. Answering the pane's own pid is "an idle shell".
        func paneForegroundPID(panePID: Int32) -> Int32? { panePID }
    }

    /// Collects what reached the pane. A lock-guarded class rather than an
    /// actor, because `TmuxManager`'s hooks are synchronous `@Sendable`
    /// closures.
    final class TmuxDouble: @unchecked Sendable {
        private let lock = NSLock()
        private var _pastes: [String] = []
        private var _keys: [String] = []
        var pastedBodies: [String] {
            lock.lock()
            defer { lock.unlock() }
            return _pastes
        }
        var sentKeys: [String] {
            lock.lock()
            defer { lock.unlock() }
            return _keys
        }
        func recordPaste(_ bytes: Data) {
            lock.lock()
            defer { lock.unlock() }
            _pastes.append(String(bytes: bytes, encoding: .utf8) ?? "")
        }
        /// Keys arrive as argv, because `sendKey` in dryRun hands the whole
        /// `send-keys` command to `dryRunRecorder` rather than to a key-shaped
        /// hook. The key is the last argument.
        func recordArgv(_ args: [String]) {
            guard args.contains("send-keys"), let key = args.last else { return }
            lock.lock()
            defer { lock.unlock() }
            _keys.append(key)
        }
    }

    /// A throwaway actuation log per harness. `ActuationLog` takes a PATH, not a
    /// database. It lands under the run's fenced scratch dir, which
    /// `scripts/test.sh` removes even when the test process is killed; a
    /// per-test `temporaryDirectory` would leak.
    private static func scratchLogPath() -> String {
        let directory = URL(
            fileURLWithPath: fencedScratchRoot(prefix: "tbd-send-harness"), isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("actuations.jsonl").path
    }

    static func make(
        transport: TerminalTransport = .tmux,
        kind: TerminalKind = .claude,
        // Overrides the inspector's answer, per agent name, so a test can ask
        // for "no foreground agent here" — the foreground rail's negative case
        // — without touching anything else about the harness. Defaulted to the
        // live-agent answer every other call site relies on.
        foregroundByAgent: [String: Int32] = ["claude": 4242, "codex": 4242],
        // The two halves of the envelope-suppression check, defaulted to the
        // fail-closed answers the production router defaults to: no recorded
        // sidecar client, and the real process reader. A suite that does not
        // pass them authenticates nobody, so every send it makes carries the
        // envelope.
        recordedAppIdentity: @escaping @Sendable () async -> ProcessIdentity? = { nil },
        processSignaller: any ProcessSignaller = ProductionProcessSignaller(),
        // Wires a real `HolderInjectionCourier` whose viewer is always
        // detached (so `deliver` takes the direct-write branch, never the
        // sidecar) and whose write lands here instead of any pty, so a holder
        // test can assert the exact bytes `performHolderSend` composed rather
        // than only that some rail did or didn't refuse it. `nil` (the
        // default) leaves `holderInjectionCourier` unset, which is what every
        // other holder test relies on to reach `holderInputUnavailable`.
        holderDeliveryRecorder: (@Sendable (Data) -> Void)? = nil
    ) async throws -> SendHarness {
        let double = TmuxDouble()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { double.recordArgv($0) },
            // Alive, carrying no identity: the branch that proceeds. The target
            // check is `TerminalSendTargetCheckTests`' business, not this
            // harness's.
            dryRunPaneSendTarget: { _, _ in .live(terminalID: nil) },
            // The foreground rail skips itself when the pane pid is "0", which
            // is what `dryRun` answers by default. Supplying a real-looking pid
            // means the rail RUNS and the harness proves it gets through it,
            // rather than passing because the rail never fired.
            dryRunPanePID: { _, _ in "4242" },
            dryRunPasteBytes: { _, _, bytes in double.recordPaste(bytes) })
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            paneProcessInspector: StubInspector(foregroundByAgent: foregroundByAgent),
            recordedAppIdentity: recordedAppIdentity,
            processSignaller: processSignaller,
            actuationLog: ActuationLog(path: Self.scratchLogPath()))
        if let holderDeliveryRecorder {
            router.holderInjectionCourier = HolderInjectionCourier(
                sendFrame: { _ in },
                viewerAttachment: { _ in nil },
                writeDirectly: { _, bytes in holderDeliveryRecorder(bytes) })
        }

        let repo = try await db.repos.create(
            path: "/tmp/acme-\(UUID().uuidString)", displayName: "acme",
            defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "acme-wt", branch: "main",
            path: FileManager.default.temporaryDirectory.path, tmuxServer: "tbd-acme")
        // A holder row carries an empty pane id by construction; a tmux row
        // carries a real one. Spelled out rather than defaulted, because the
        // holder refusal tests turn on exactly this.
        let terminal = try await db.terminals.create(
            worktreeID: worktree.id,
            tmuxWindowID: transport == .holder ? "" : "@3",
            tmuxPaneID: transport == .holder ? "" : "%7",
            claudeSessionID: "sess-1",
            kind: kind,
            transport: transport,
            childPID: transport == .holder ? 4242 : nil)
        return SendHarness(router: router, db: db, terminal: terminal, tmux: double)
    }

    /// The one identity the envelope-suppression check accepts, and a harness
    /// wired to accept it.
    ///
    /// Shared here rather than restated per suite: the parts-delivery and holder
    /// suites need an AUTHENTICATED connection only to reach a suppressed
    /// disposition, while `EnvelopeSuppressionAuthTests` keeps its own stub
    /// because its subject is the ways the check FAILS.
    enum AuthenticatedApp {
        static let pid: Int32 = 909
        static let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        static let commandLine = "/Applications/TBD.app/Contents/MacOS/TBDApp"

        /// What a caller passes to `send` to arrive as the app.
        static var connection: RPCConnectionContext { RPCConnectionContext(peerPID: pid) }

        static var identity: ProcessIdentity {
            ProcessIdentity(pid: pid, startedAt: startedAt, commandLine: commandLine)
        }

        /// Answers the re-verification with `.same` for that one pid. Inert on
        /// the signalling half: a stub that could kill something is a stub that
        /// will, on a mistake.
        struct Signaller: ProcessSignaller {
            func isAlive(_ pid: Int32) -> Bool { true }
            func startTime(_ pid: Int32) -> Date? { AuthenticatedApp.startedAt }
            func commandLine(_ pid: Int32) -> String? { AuthenticatedApp.commandLine }
            func stat(_ pid: Int32) -> String? { nil }
            func children(ofServerPID serverPID: Int32) -> [Int32] { [] }
            func terminate(_ pid: Int32) {}
            func forceKill(_ pid: Int32) {}
        }
    }

    /// A harness on which `AuthenticatedApp.connection` authenticates, so a send
    /// that asks for `envelope: .suppressed` actually gets it.
    static func makeAuthenticated(
        transport: TerminalTransport = .tmux,
        kind: TerminalKind = .claude,
        holderDeliveryRecorder: (@Sendable (Data) -> Void)? = nil
    ) async throws -> SendHarness {
        try await make(
            transport: transport,
            kind: kind,
            recordedAppIdentity: { AuthenticatedApp.identity },
            processSignaller: AuthenticatedApp.Signaller(),
            holderDeliveryRecorder: holderDeliveryRecorder)
    }

    /// `connection` is what the daemon would have learned from the socket the
    /// request arrived on. Defaulted to nil — "not established" — which is what
    /// every non-socket caller of the router gets, and the answer that keeps the
    /// envelope.
    func send(
        _ params: TerminalSendParams,
        actor: ActuationActor?,
        connection: RPCConnectionContext? = nil
    ) async throws -> RPCResponse {
        try await router.handleTerminalSend(
            try JSONEncoder().encode(params), actor: actor, connection: connection)
    }
}
