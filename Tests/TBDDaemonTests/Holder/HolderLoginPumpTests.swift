import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// The auto-`/login` pump's holder arm: what it reads, what it refuses to
/// judge, and the exact bytes it writes.
///
/// No real holder, no pty and no attach. The two seams the router keeps for
/// exactly this — `holderScreenOracle` for the screen, an injection courier
/// whose write lands in a log instead of a pty — reach all four readings the
/// pump branches on and let the assertions be on bytes rather than on counts.
///
/// The pump itself runs on `EventDrivenTestClock`, so every wait in these
/// tests is an arming handshake: the pump arms its next sleep only after the
/// iteration before it has finished reading and typing, which is what makes a
/// synchronous read of the write log sound.
@Suite("Holder login pump", .clockDriven)
struct HolderLoginPumpTests {

    // MARK: - Fixture

    /// What Claude paints once its TUI accepts input and nobody is logged in.
    private static let readyLines = [
        "Not logged in · Run /login",
        "> ",
    ]
    /// The `/login` method picker.
    private static let dialogLines = [
        "Login",
        "Select login method:",
    ]

    /// The bytes each half of a `/login` submit is expected to be.
    private static let loginBytes = Data("/login".utf8)
    private static let enterBytes = Data([0x0d])

    /// The screen the oracle answers with, flipped between advances.
    private final class ScreenBox: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String]
        private let source: TerminalScreen.Source
        private let contentObserved: Bool
        /// `false` makes the oracle answer "no reader", which is the pump's
        /// fourth reading.
        private let present: Bool

        init(
            lines: [String],
            source: TerminalScreen.Source = .daemon,
            contentObserved: Bool = true,
            present: Bool = true
        ) {
            self.lines = lines
            self.source = source
            self.contentObserved = contentObserved
            self.present = present
        }

        func set(lines: [String]) {
            lock.lock(); defer { lock.unlock() }
            self.lines = lines
        }

        func screen() throws -> TerminalScreen? {
            lock.lock(); defer { lock.unlock() }
            guard present else { return nil }
            return try TerminalScreen(
                lines: lines,
                viewportStart: 0,
                cursor: TerminalScreen.Cursor(row: 0, column: 0, visible: true),
                size: TerminalScreen.Size(columns: 80, rows: 24),
                modes: TerminalScreen.ChildModes(
                    bracketedPaste: false, applicationCursor: false, alternateScreen: false),
                modesObserved: true,
                contentObserved: contentObserved,
                source: source,
                ageMilliseconds: 0)
        }
    }

    /// Every write the courier made, in order. A lock-guarded class because
    /// the courier's `writeDirectly` is a synchronous-bodied `@Sendable`
    /// closure.
    private final class WriteLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _writes: [Data] = []
        var writes: [Data] {
            lock.lock(); defer { lock.unlock() }
            return _writes
        }
        func record(_ bytes: Data) {
            lock.lock(); defer { lock.unlock() }
            _writes.append(bytes)
        }
    }

    /// Whole-second pacing so each advance is one named interval. A zero
    /// initial delay registers no sleeper on this clock, which keeps it out of
    /// every chain below.
    private static let delays = LoginSessionCoordinator.Delays(
        pumpInitialDelay: .zero,
        pumpPollInterval: .seconds(1),
        pumpPostSendDelay: .seconds(2),
        pumpTimeout: .seconds(60),
        identityPollInterval: .seconds(2),
        identityPollTimeout: .seconds(4)
    )

    private struct Fixture {
        let router: RPCRouter
        let terminal: Terminal
        let clock: EventDrivenTestClock
        let screens: ScreenBox
        let writes: WriteLog

        /// The production closures for this row, driven through the production
        /// pump. `server` is never consulted on the holder arm.
        func startPump(maxSends: Int = 3) async {
            let closures = router.loginPumpClosures(for: terminal, server: "tbd-acme")
            await router.loginSessions.registerPendingAutoLogin(terminalID: terminal.id)
            await router.loginSessions.startAutoLoginPump(
                terminalID: terminal.id,
                maxSends: maxSends,
                paneText: closures.paneText,
                typeLogin: closures.typeLogin)
        }

        /// Release the pump's last sleeper with its registration cancelled, so
        /// nothing is left parked on a clock nobody will advance again.
        func drain() async throws {
            await router.loginSessions.cancelPendingAutoLogin(terminalID: terminal.id)
            try await clock.requireAdvanceWhenArmed(by: Self.anyPendingInterval)
        }

        /// Long enough to pass either of the pump's two sleeps.
        private static let anyPendingInterval: Duration = .seconds(60)
    }

    private static func makeFixture(
        screens: ScreenBox,
        wireCourier: Bool = true
    ) async throws -> Fixture {
        let clock = EventDrivenTestClock()
        let writes = WriteLog()
        let tmux = TmuxManager(dryRun: true)
        let db = try TBDDatabase(inMemory: true)
        let configDirManager = makeIsolatedConfigDirManager(tag: "holder-login-pump")
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(),
                configDirManager: configDirManager),
            tmux: tmux,
            configDirManager: configDirManager,
            loginSessions: LoginSessionCoordinator(delays: delays, clock: clock),
            actuationLog: makeTestActuationLog())
        router.holderScreenOracle = { _ in try screens.screen() }
        if wireCourier {
            router.holderInjectionCourier = HolderInjectionCourier(
                sendFrame: { _ in },
                viewerAttachment: { _ in nil },
                writeDirectly: { _, bytes in writes.record(bytes) })
        }

        let repo = try await db.repos.create(
            path: "/tmp/acme-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "acme-wt", branch: "main",
            path: FileManager.default.temporaryDirectory.path, tmuxServer: "tbd-acme")
        // A holder row carries empty tmux coordinates by construction; the
        // login label is what the spawn path writes for this tab.
        let terminal = try await db.terminals.create(
            worktreeID: worktree.id,
            tmuxWindowID: "",
            tmuxPaneID: "",
            label: TerminalLabel.login,
            claudeSessionID: "login-1",
            kind: .claude,
            transport: .holder,
            childPID: 4242)
        return Fixture(
            router: router, terminal: terminal, clock: clock, screens: screens, writes: writes)
    }

    // MARK: - Screens the pump may not judge

    /// A grid built over a child that was already running shows whatever the
    /// child has not repainted since — including a caret it may no longer
    /// have. Ready-looking text there must still buy nothing.
    @Test("an unobserved daemon screen is polled, never typed at")
    func unobservedScreenIsNeverTypedAt() async throws {
        let fixture = try await Self.makeFixture(
            screens: ScreenBox(lines: Self.readyLines, source: .daemon, contentObserved: false))
        await fixture.startPump()

        try await fixture.clock.requireAdvanceWhenArmed(by: Self.delays.pumpPollInterval)
        try await fixture.clock.requireSleeperArmed()
        try await fixture.clock.requireAdvanceWhenArmed(by: Self.delays.pumpPollInterval)
        try await fixture.clock.requireSleeperArmed()

        #expect(fixture.writes.writes.isEmpty)
        try await fixture.drain()
    }

    /// A viewer holds the pty, so the daemon's emulator is frozen at the
    /// attach and its text describes whenever that was.
    @Test("a screen frozen behind a viewer's attach is polled, never typed at")
    func staleDaemonScreenIsNeverTypedAt() async throws {
        let fixture = try await Self.makeFixture(
            screens: ScreenBox(lines: Self.readyLines, source: .staleDaemon))
        await fixture.startPump()

        try await fixture.clock.requireAdvanceWhenArmed(by: Self.delays.pumpPollInterval)
        try await fixture.clock.requireSleeperArmed()
        try await fixture.clock.requireAdvanceWhenArmed(by: Self.delays.pumpPollInterval)
        try await fixture.clock.requireSleeperArmed()

        #expect(fixture.writes.writes.isEmpty)
        try await fixture.drain()
    }

    /// Nothing is reading this session's pty for the daemon, so there is no
    /// screen at all.
    @Test("no reader at all is polled, never typed at")
    func absentScreenIsNeverTypedAt() async throws {
        let fixture = try await Self.makeFixture(
            screens: ScreenBox(lines: Self.readyLines, present: false))
        await fixture.startPump()

        try await fixture.clock.requireAdvanceWhenArmed(by: Self.delays.pumpPollInterval)
        try await fixture.clock.requireSleeperArmed()

        #expect(fixture.writes.writes.isEmpty)
        try await fixture.drain()
    }

    // MARK: - The screen the pump may judge

    /// The whole act, in bytes: the body and the submit as two separate
    /// writes, in that order, and nothing more once the dialog is up.
    @Test("a live, fully observed ready screen is typed /login then Enter, once")
    func observedReadyScreenIsTypedOnce() async throws {
        let screens = ScreenBox(lines: Self.readyLines)
        let fixture = try await Self.makeFixture(screens: screens)
        await fixture.startPump()

        // The post-send sleep arms only after both writes have been made.
        try await fixture.clock.requireSleeperArmed()
        #expect(fixture.writes.writes == [Self.loginBytes, Self.enterBytes])

        // The verify read sees the dialog, so the pump stops.
        screens.set(lines: Self.dialogLines)
        try await fixture.clock.requireAdvanceWhenArmed(by: Self.delays.pumpPostSendDelay)
        let stopped = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            await fixture.router.loginSessions.isPendingAutoLogin(
                terminalID: fixture.terminal.id) == false
        }
        #expect(stopped == .satisfied, "the pump never cleared its registration")
        #expect(fixture.writes.writes == [Self.loginBytes, Self.enterBytes])
    }

    /// A send the TUI swallowed is retried, capped, and the cap is on the
    /// `/login` pairs rather than on the writes.
    @Test("a dialog that never appears is retried to the cap and no further")
    func retriesAreCapped() async throws {
        let fixture = try await Self.makeFixture(screens: ScreenBox(lines: Self.readyLines))
        await fixture.startPump()

        // Each advance waits for the post-send sleep the previous iteration
        // armed, which is the proof its pair of writes had already been made.
        try await fixture.clock.requireAdvanceWhenArmed(by: Self.delays.pumpPostSendDelay)
        try await fixture.clock.requireAdvanceWhenArmed(by: Self.delays.pumpPostSendDelay)
        try await fixture.clock.requireAdvanceWhenArmed(by: Self.delays.pumpPostSendDelay)
        // The cap is reached, so this iteration takes the poll arm instead.
        try await fixture.clock.requireSleeperArmed()

        #expect(
            fixture.writes.writes
                == [
                    Self.loginBytes, Self.enterBytes,
                    Self.loginBytes, Self.enterBytes,
                    Self.loginBytes, Self.enterBytes,
                ])

        try await fixture.clock.requireAdvanceWhenArmed(by: Self.delays.pumpPollInterval)
        try await fixture.clock.requireSleeperArmed()
        #expect(fixture.writes.writes.count == 6)
        try await fixture.drain()
    }

    // MARK: - No injection path

    /// A daemon with no courier cannot type, and says so rather than
    /// crashing. The pump keeps its shape: it still polls, and it still ends
    /// on its own timeout rather than on a failed write.
    @Test("a daemon with no injection path writes nothing and keeps polling")
    func missingCourierWritesNothing() async throws {
        let fixture = try await Self.makeFixture(
            screens: ScreenBox(lines: Self.readyLines), wireCourier: false)
        await fixture.startPump()

        try await fixture.clock.requireAdvanceWhenArmed(by: Self.delays.pumpPostSendDelay)
        try await fixture.clock.requireAdvanceWhenArmed(by: Self.delays.pumpPostSendDelay)
        try await fixture.clock.requireSleeperArmed()

        #expect(fixture.writes.writes.isEmpty)
        #expect(
            await fixture.router.loginSessions.isPendingAutoLogin(terminalID: fixture.terminal.id))
        try await fixture.drain()
    }
}
