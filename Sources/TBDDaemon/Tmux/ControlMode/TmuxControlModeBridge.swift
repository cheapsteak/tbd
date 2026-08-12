import Foundation
import TBDShared

/// Bundles the per-daemon `TmuxControlSupervisor` with tmux version resolution
/// so every `ensureServer()` call site can open a gated control-mode
/// connection through a single shared owner.
///
/// `Daemon` constructs exactly one of these at startup and hands the same
/// value to `WorktreeLifecycle` and `RPCRouter`. When the control-mode gate is
/// off (the default), `enableIfGated(serverName:)` is a no-op, so behavior is
/// unchanged.
struct TmuxControlModeBridge: Sendable {
    /// The single per-daemon supervisor. Connections are keyed by server name
    /// and `ensureConnection` is idempotent, so all call sites share one.
    let supervisor: TmuxControlSupervisor
    /// Resolves PATH first and the live saved fallback second on every gate
    /// and capabilities decision.
    let tmuxExecutableResolver: TmuxExecutableResolver
    /// Environment the gate reads. Injectable so tests can flip the gate.
    let environment: [String: String]
    /// Sidecar over which attach handlers vend pane fds.
    let fdVending: FDVendingServer
    /// How long an attach may sit un-acked before the daemon cancels it
    /// (spec, pane lifecycle: "App fails to send attach.ready within timeout
    /// (e.g. 5 s) → daemon cancels attach"). Injectable for tests.
    let readyTimeout: Duration
    /// Routes app → daemon input frames to `send-keys -H` on the correct
    /// server's FIFO correlator (M2.2). A reference type shared by every copy
    /// of this (value) struct, so the daemon's `setOnInput` sink and the attach
    /// handlers' register/unregister all touch the same router.
    let inputRouter: ControlModeInputRouter
    /// Arbitrates window resizes with echo suppression (M3.1, addendum §4). Like
    /// `inputRouter`, a reference type shared across every copy of this struct,
    /// so the `pane.resize` handler and the supervisor's layout-change filter
    /// touch the same coordinator.
    let resizeCoordinator: ControlModeResizeCoordinator
    /// Reads the persisted Settings opt-in (`config.control_mode_enabled`,
    /// M5). A provider closure — not a snapshot bool — so every gate decision
    /// re-reads the flag and a Settings toggle affects the NEXT attach
    /// without a daemon restart. Existing attached panes are never torn down
    /// or migrated on toggle: the flag applies to newly created panes only.
    let persistedFlagProvider: @Sendable () async -> Bool
    /// Resolves the FIFO command correlator for a server — the attach replay
    /// orchestrator's command seam (M4.3). Defaults to the supervisor's live
    /// clients; injectable so orchestration tests can substitute a fake-backed
    /// client (same seam shape as the input router / resize coordinator).
    let commandProvider: @Sendable (String) async -> TmuxControlCommandClient?
    /// Heals steady-state queue overflows with the Phase B M3 pause+recapture
    /// repair cycle. A reference type (actor) shared across every copy of
    /// this value struct, wired to `PaneFanout.onOverflowRepair` in this
    /// init; injectable seam like `inputRouter`/`resizeCoordinator`.
    let repairCoordinator: PaneRepairCoordinator
    /// Clock behind every delay in the control-mode subsystem: the attach
    /// ready-timer below and (threaded down) the repair coordinator's
    /// reader-catch-up pacing. Defaulted, so no call site changes; tests pass
    /// a `TestClock` and drive virtual time instead of sleeping.
    let clock: any Clock<Duration>

    init(supervisor: TmuxControlSupervisor,
         tmuxExecutableResolver: TmuxExecutableResolver = TmuxExecutableResolver(),
         environment: [String: String] = ProcessInfo.processInfo.environment,
         fdVending: FDVendingServer,
         readyTimeout: Duration = .seconds(5),
         inputRouter: ControlModeInputRouter? = nil,
         resizeCoordinator: ControlModeResizeCoordinator? = nil,
         persistedFlagProvider: @escaping @Sendable () async -> Bool = { false },
         commandProvider: (@Sendable (String) async -> TmuxControlCommandClient?)? = nil,
         repairCoordinator: PaneRepairCoordinator? = nil,
         clock: any Clock<Duration> = ContinuousClock()) {
        self.supervisor = supervisor
        self.clock = clock
        self.tmuxExecutableResolver = tmuxExecutableResolver
        self.environment = environment
        self.fdVending = fdVending
        self.readyTimeout = readyTimeout
        self.persistedFlagProvider = persistedFlagProvider
        self.commandProvider = commandProvider
            ?? { [supervisor] server in await supervisor.command(server: server) }
        // Default-wire the router to this supervisor's correlators so callers
        // (and tests) that don't care about input get a correctly-wired router
        // for free; the daemon can still inject one it also holds a handle to.
        self.inputRouter = inputRouter
            ?? ControlModeInputRouter(commandProvider: { [supervisor] server in
                await supervisor.command(server: server)
            })
        self.resizeCoordinator = resizeCoordinator
            ?? ControlModeResizeCoordinator(commandProvider: { [supervisor] server in
                await supervisor.command(server: server)
            })
        // Install the echo-suppression filter on the supervisor BEFORE any
        // `ensureConnection` (this init runs at daemon startup, well before the
        // first attach) so the drain loop consults it from the first event. The
        // setter is nonisolated, so this synchronous init can call it directly.
        let coordinator = self.resizeCoordinator
        supervisor.setLayoutChangeFilter { server, windowID in
            coordinator.shouldApplyLayoutChange(server: server, windowID: windowID)
        }
        // Wire the M3 overflow-repair signal, also BEFORE any connection
        // starts (same startup guarantee as the layout filter): the very
        // first routed byte can already overflow a wedged pipe.
        // Only the default-constructed coordinator inherits our clock; an
        // injected one carries whatever clock it was built with. (No call
        // site injects one today — tests that need a fake-clocked coordinator
        // construct it directly rather than going through the bridge.)
        self.repairCoordinator = repairCoordinator
            ?? PaneRepairCoordinator(
                supervisor: supervisor, commandProvider: self.commandProvider, clock: clock)
        let repair = self.repairCoordinator
        supervisor.fanout.onOverflowRepair = { key, generation in
            Task { await repair.repairIfNeeded(key: key, generation: generation) }
        }
    }

    /// Current tmux version. Both the effective path and the version are
    /// detected at use so Settings changes and in-place executable upgrades
    /// take effect without a daemon restart.
    func currentTmuxVersion() async -> TmuxVersion? {
        guard let executablePath = tmuxExecutableResolver.resolve()?.path else { return nil }
        return await TmuxVersion.detect(tmuxBinary: executablePath)
    }

    /// Effective gate decision and the version used for it, evaluated from one
    /// snapshot so capability fields cannot disagree with the enabled state.
    /// Capability queries report tmux support even while control mode is off,
    /// so this path intentionally detects the version before applying the gate.
    func currentGateState() async -> (enabled: Bool, tmuxVersion: TmuxVersion?) {
        let version = await currentTmuxVersion()
        let enabled = ControlModeGate.shouldEnable(
            environment: environment,
            persistedFlag: await persistedFlagProvider(),
            tmuxVersion: version
        )
        return (enabled, version)
    }

    /// Effective gate decision, evaluated fresh on every call:
    /// `(env opt-in || persisted flag) && tmux >= 3.2`. The persisted flag is
    /// read through `persistedFlagProvider`, so a Settings toggle takes
    /// effect on the next decision without a daemon restart. Hot-path gate
    /// checks avoid resolving or launching tmux while both opt-ins are off.
    func gateEnabled() async -> Bool {
        let persistedFlag = await persistedFlagProvider()
        guard ControlModeGate.optedIn(environment: environment) || persistedFlag else {
            return false
        }
        return ControlModeGate.shouldEnable(
            environment: environment,
            persistedFlag: persistedFlag,
            tmuxVersion: await currentTmuxVersion()
        )
    }

    /// Open a logging-only `tmux -CC` connection for `serverName` when the
    /// control-mode gate passes (see `gateEnabled`). Idempotent.
    func enableIfGated(serverName: String) async {
        guard await gateEnabled() else { return }
        await supervisor.ensureConnection(serverName: serverName)
    }
}
