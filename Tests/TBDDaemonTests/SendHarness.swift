import Clocks
import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared
import TBDKernel
import TestSupport

/// One live Claude terminal, a courier that records what it was asked to
/// write, and a router over an in-memory database.
///
/// The row is holder-backed, the one transport TBD types into, and the courier
/// is a real `HolderInjectionCourier` whose viewer is always detached, so every
/// delivery takes the direct-write branch and lands in `delivered` instead of a
/// pty. Nothing about the production path is stubbed out: the handler runs in
/// full and the doubles only answer the questions the holder and the process
/// table would have.
///
/// Shared deliberately, by the delivery suite that introduced it and by the
/// authority, gate and holder suites that follow: one fixture over one handler
/// means a rail added for any of them is a rail all of them run through.
struct SendHarness {
    let router: RPCRouter
    let db: TBDDatabase
    let terminal: Terminal
    let delivered: DeliveryDouble

    /// What reached the child, read back as the message and the keys a person
    /// would have typed. A lock-guarded class rather than an actor, because
    /// the courier's write is a synchronous `@Sendable` closure.
    ///
    /// Each write is decoded on the shape `HolderSendComposition.compose` and
    /// the paced key path give it:
    ///   - A write that opens a bracketed paste is one pasted body, the bytes
    ///     between the markers; a `\r` after the end marker is an Enter.
    ///   - A write that is exactly one named key's bytes is that key — which
    ///     is also how an empty-text submit's lone `\r` reads, as an Enter
    ///     and no paste.
    ///   - Anything else is a bare body, its one trailing `\r` an Enter.
    ///
    /// `writes` keeps the raw bytes for a suite that wants the framing itself.
    final class DeliveryDouble: @unchecked Sendable {
        private let lock = NSLock()
        private var _writes: [Data] = []
        private var _pastes: [String] = []
        private var _keys: [String] = []
        var writes: [Data] { lock.withLock { _writes } }
        var pastedBodies: [String] { lock.withLock { _pastes } }
        var sentKeys: [String] { lock.withLock { _keys } }

        /// The key names a send in these suites presses, tried in this order
        /// against a write. `Enter` first, so a lone `\r` reads as Enter.
        private static let namedKeys = [
            "Enter", "Escape", "Tab", "BTab", "BSpace", "Space",
            "Up", "Down", "Right", "Left", "Home", "End", "C-c", "C-d", "C-u",
        ]

        func record(_ bytes: Data) {
            let (body, keys) = Self.decode([UInt8](bytes))
            lock.withLock {
                _writes.append(bytes)
                if let body { _pastes.append(body) }
                _keys.append(contentsOf: keys)
            }
        }

        private static func decode(_ write: [UInt8]) -> (body: String?, keys: [String]) {
            let start = [UInt8](HolderSendComposition.pasteStart)
            let end = [UInt8](HolderSendComposition.pasteEnd)
            let enter = HolderSendComposition.submitByte
            if write.starts(with: start),
               let close = firstIndex(of: end, in: write, from: start.count) {
                let body = String(decoding: write[start.count..<close], as: UTF8.self)
                let tail = write[(close + end.count)...]
                return (body, tail.elementsEqual([enter]) ? ["Enter"] : [])
            }
            if let name = namedKeys.first(where: { name in
                HolderNamedKeys.bytes(for: name, modes: nil).map { [UInt8]($0) } == write
            }) {
                return (nil, [name])
            }
            if write.last == enter {
                return (String(decoding: write.dropLast(), as: UTF8.self), ["Enter"])
            }
            return (String(decoding: write, as: UTF8.self), [])
        }

        private static func firstIndex(
            of needle: [UInt8], in haystack: [UInt8], from offset: Int
        ) -> Int? {
            guard haystack.count >= needle.count, offset <= haystack.count - needle.count
            else { return nil }
            return (offset...(haystack.count - needle.count)).first {
                haystack[$0..<($0 + needle.count)].elementsEqual(needle)
            }
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
        // `.tmux` builds a row TBD no longer types into, for the suites that
        // pin its refusal.
        transport: TerminalTransport = .holder,
        kind: TerminalKind = .claude,
        // The two halves of the envelope-suppression check, defaulted to the
        // fail-closed answers the production router defaults to: no recorded
        // sidecar client, and the real process reader. A suite that does not
        // pass them authenticates nobody, so every send it makes carries the
        // envelope.
        recordedAppIdentity: @escaping @Sendable () async -> ProcessIdentity? = { nil },
        processSignaller: any ProcessSignaller = ProductionProcessSignaller(),
        // Also handed every courier write, after `delivered` records it, for a
        // holder suite that keeps its own recorder of the exact bytes
        // `performHolderSend` composed.
        holderDeliveryRecorder: (@Sendable (Data) -> Void)? = nil,
        // `false` leaves `holderInjectionCourier` unset: the no-input-path
        // state `performHolderSend` turns into `holderInputUnavailable`.
        installsCourier: Bool = true,
        // Behavior seam for the router's waits. Defaulted to `ImmediateClock`,
        // so no suite built on this harness spends wall time; a suite that
        // wants to PIN a wait passes an `EventDrivenTestClock` instead.
        clock: any Clock<Duration> = ImmediateClock()
    ) async throws -> SendHarness {
        let double = DeliveryDouble()
        let tmux = TmuxManager(dryRun: true)
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            recordedAppIdentity: recordedAppIdentity,
            processSignaller: processSignaller,
            actuationLog: ActuationLog(path: Self.scratchLogPath()),
            clock: clock)
        if installsCourier {
            router.holderInjectionCourier = HolderInjectionCourier(
                sendFrame: { _ in },
                viewerAttachment: { _ in nil },
                writeDirectly: { _, bytes in
                    double.record(bytes)
                    holderDeliveryRecorder?(bytes)
                })
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
        return SendHarness(router: router, db: db, terminal: terminal, delivered: double)
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
            func terminate(_ pid: Int32) {}
            func forceKill(_ pid: Int32) {}
        }
    }

    /// A harness on which `AuthenticatedApp.connection` authenticates, so a send
    /// that asks for `envelope: .suppressed` actually gets it.
    static func makeAuthenticated(
        transport: TerminalTransport = .holder,
        kind: TerminalKind = .claude,
        holderDeliveryRecorder: (@Sendable (Data) -> Void)? = nil,
        clock: any Clock<Duration> = ImmediateClock()
    ) async throws -> SendHarness {
        try await make(
            transport: transport,
            kind: kind,
            recordedAppIdentity: { AuthenticatedApp.identity },
            processSignaller: AuthenticatedApp.Signaller(),
            holderDeliveryRecorder: holderDeliveryRecorder,
            clock: clock)
    }

    /// Installs a real `HolderRegistry` on this harness's router and, when
    /// `status` is non-nil, records it for this harness's terminal as a
    /// holder's own report would have.
    ///
    /// The registry is real rather than a double because `HolderRegistry` is a
    /// concrete actor with no protocol behind it, and because the production
    /// read under test is literally `holderRegistry?.lastKnownStatus(for:)` —
    /// a router-level seam would replace the very expression a wrong `nil`
    /// registry or a wrong terminal id would show up in. It holds no reader
    /// and no spawner, so `holderModeReading`'s registry fallback still
    /// answers nil exactly as it does with no registry at all, and nothing
    /// here reaches a socket.
    ///
    /// Passing `nil` (the default) is the "a holder was adopted but has never
    /// reported a status" state, which is a different input from leaving
    /// `router.holderRegistry` unset — the state every other holder suite
    /// runs in.
    @discardableResult
    func installHolderRegistry(reporting status: HolderChildStatus? = nil) async
        -> HolderRegistry {
        // Bound to a local rather than captured through `self`: the closure is
        // `@Sendable` and this harness is not.
        let row = terminal
        let registry = HolderRegistry(
            owner: HolderOwnerToken(rawValue: "acme-installation"),
            // A rendezvous root with nothing in it, under the run's fenced
            // scratch dir. Nothing here connects, but a registry that derived
            // its paths from the real `TBD_HOME` would be one edit away from
            // doing so.
            environment: ["TBD_HOME": fencedScratchRoot(prefix: "tbd-send-harness-holder")],
            listTerminals: { [row] })
        if let status {
            await registry.recordStatusForTesting(status, for: row.id)
        }
        router.holderRegistry = registry
        return registry
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
