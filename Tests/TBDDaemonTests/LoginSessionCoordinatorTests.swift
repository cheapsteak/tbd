import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("LoginSessionCoordinator", .clockDriven)
struct LoginSessionCoordinatorTests {

    /// Thread-safe recorder shared by pump/watcher tests.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _sendCount = 0
        private var _loginCount = 0
        private var _paneText = ""
        private var _identity: String?

        var sendCount: Int {
            lock.lock(); defer { lock.unlock() }
            return _sendCount
        }
        func recordSend() {
            lock.lock(); defer { lock.unlock() }
            _sendCount += 1
        }
        var loginCount: Int {
            lock.lock(); defer { lock.unlock() }
            return _loginCount
        }
        func recordLogin() {
            lock.lock(); defer { lock.unlock() }
            _loginCount += 1
        }
        var paneText: String {
            lock.lock(); defer { lock.unlock() }
            return _paneText
        }
        func setPaneText(_ value: String) {
            lock.lock(); defer { lock.unlock() }
            _paneText = value
        }
        var identity: String? {
            lock.lock(); defer { lock.unlock() }
            return _identity
        }
        func setIdentity(_ value: String?) {
            lock.lock(); defer { lock.unlock() }
            _identity = value
        }
    }

    /// Poll until `condition` is true or `timeout` elapses.
    ///
    /// The deadline is the shared saturated-pass budget, not a literal: what it
    /// waits for is produced by the coordinator's own detached pump task, which
    /// runs on the cooperative pool behind the whole fast pass regardless of
    /// how the test was started (`gateHoldingTask` in
    /// `Tests/TestSupport/BoundedGateSupport.swift`). Five seconds is far below
    /// that pass's healthy per-test latency.
    private func waitFor(
        _ condition: @Sendable () -> Bool,
        timeout: Duration = TestDeadlines.saturatedPass
    ) async -> Bool {
        var elapsed: Duration = .zero
        let step: Duration = .milliseconds(10)
        while elapsed < timeout {
            if condition() { return true }
            try? await Task.sleep(for: step)
            elapsed += step
        }
        return condition()
    }

    /// Fast pump timings for tests.
    private func fastDelays(timeout: Duration = .seconds(2)) -> LoginSessionCoordinator.Delays {
        .init(
            pumpInitialDelay: .zero,
            pumpPollInterval: .milliseconds(5),
            pumpPostSendDelay: .milliseconds(5),
            pumpTimeout: timeout,
            identityPollInterval: .milliseconds(5),
            identityPollTimeout: .milliseconds(50)
        )
    }

    private static let readyPane = """
        ⚠ 1 MCP server needs authentication · run /mcp
        Not logged in · Run /login
        ❯
        ⏵⏵ bypass permissions on (shift+tab to cycle)
        """
    private static let dialogPane = """
        Login
        Select login method:
        ❯ 1. Claude account with subscription
        """

    // MARK: - Pane classification

    @Test("classifyPane: boot screen → notReady")
    func classifyNotReady() {
        #expect(LoginSessionCoordinator.classifyPane("") == .notReady)
        #expect(LoginSessionCoordinator.classifyPane("Loading…") == .notReady)
    }

    @Test("classifyPane: interactive prompt → promptReady")
    func classifyReady() {
        #expect(LoginSessionCoordinator.classifyPane(Self.readyPane) == .promptReady)
        #expect(LoginSessionCoordinator.classifyPane("Not logged in · Run /login") == .promptReady)
    }

    @Test("classifyPane: login picker → loginDialogVisible")
    func classifyDialog() {
        #expect(LoginSessionCoordinator.classifyPane(Self.dialogPane) == .loginDialogVisible)
    }

    // MARK: - Auto-login pump

    @Test("pump waits for readiness, types /login once, verifies dialog, stops")
    func pumpHappyPath() async {
        let coordinator = LoginSessionCoordinator(delays: fastDelays())
        let recorder = Recorder()
        let id = UUID()
        // Pane starts not-ready; typing flips it straight to the dialog.
        await coordinator.registerPendingAutoLogin(terminalID: id)
        await coordinator.startAutoLoginPump(
            terminalID: id,
            paneText: { .text(recorder.paneText) },
            typeLogin: {
                recorder.recordSend()
                recorder.setPaneText(Self.dialogPane)
            }
        )

        // Still booting — no sends.
        try? await Task.sleep(for: .milliseconds(30))
        #expect(recorder.sendCount == 0)

        recorder.setPaneText(Self.readyPane)
        #expect(await waitFor({ recorder.sendCount == 1 }))

        // Verified done: pending cleared, no extra sends.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(recorder.sendCount == 1)
        #expect(await coordinator.isPendingAutoLogin(terminalID: id) == false)
    }

    @Test("pump re-sends when the first /login is swallowed (unverified)")
    func pumpRetriesSwallowedSend() async {
        let coordinator = LoginSessionCoordinator(delays: fastDelays())
        let recorder = Recorder()
        let id = UUID()
        recorder.setPaneText(Self.readyPane)
        await coordinator.registerPendingAutoLogin(terminalID: id)
        await coordinator.startAutoLoginPump(
            terminalID: id,
            paneText: { .text(recorder.paneText) },
            typeLogin: {
                recorder.recordSend()
                // First send vanishes (TUI not consuming input yet);
                // second send takes.
                if recorder.sendCount >= 2 {
                    recorder.setPaneText(Self.dialogPane)
                }
            }
        )

        #expect(await waitFor({ recorder.sendCount == 2 }))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(recorder.sendCount == 2)
    }

    @Test("pump caps sends at maxSends even if the dialog never appears")
    func pumpCapsSends() async {
        let coordinator = LoginSessionCoordinator(delays: fastDelays(timeout: .milliseconds(200)))
        let recorder = Recorder()
        let id = UUID()
        recorder.setPaneText(Self.readyPane)
        await coordinator.registerPendingAutoLogin(terminalID: id)
        await coordinator.startAutoLoginPump(
            terminalID: id,
            maxSends: 3,
            paneText: { .text(recorder.paneText) },
            typeLogin: { recorder.recordSend() }
        )

        // The pump reaches the cap…
        #expect(await waitFor({ recorder.sendCount == 3 }))
        // …then runs to its timeout without ever exceeding it. The pump's
        // defer clears the registration when it exits, so poll that.
        var elapsed: Duration = .zero
        while await coordinator.isPendingAutoLogin(terminalID: id), elapsed < .seconds(5) {
            try? await Task.sleep(for: .milliseconds(10))
            elapsed += .milliseconds(10)
        }
        #expect(await coordinator.isPendingAutoLogin(terminalID: id) == false)
        #expect(recorder.sendCount == 3)
    }

    @Test("pump requires registration and is single-flighted per terminal")
    func pumpGuards() async {
        let coordinator = LoginSessionCoordinator(delays: fastDelays())
        let recorder = Recorder()
        recorder.setPaneText(Self.readyPane)

        // Unregistered terminal → pump refuses to start.
        await coordinator.startAutoLoginPump(
            terminalID: UUID(),
            paneText: { .text(recorder.paneText) },
            typeLogin: { recorder.recordSend() }
        )
        try? await Task.sleep(for: .milliseconds(50))
        #expect(recorder.sendCount == 0)

        // Double-start on the same registered terminal → one pump only.
        let id = UUID()
        await coordinator.registerPendingAutoLogin(terminalID: id)
        let sendAndFinish: @Sendable () async -> Void = {
            recorder.recordSend()
            recorder.setPaneText(Self.dialogPane)
        }
        await coordinator.startAutoLoginPump(
            terminalID: id, paneText: { .text(recorder.paneText) }, typeLogin: sendAndFinish
        )
        await coordinator.startAutoLoginPump(
            terminalID: id, paneText: { .text(recorder.paneText) }, typeLogin: sendAndFinish
        )
        #expect(await waitFor({ recorder.sendCount >= 1 }))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(recorder.sendCount == 1)
    }

    @Test("cancelPendingAutoLogin stops an active pump before it types")
    func pumpCancelled() async {
        let coordinator = LoginSessionCoordinator(delays: fastDelays())
        let recorder = Recorder()
        let id = UUID()
        // Not ready yet — pump idles in the poll loop.
        await coordinator.registerPendingAutoLogin(terminalID: id)
        await coordinator.startAutoLoginPump(
            terminalID: id,
            paneText: { .text(recorder.paneText) },
            typeLogin: { recorder.recordSend() }
        )
        await coordinator.cancelPendingAutoLogin(terminalID: id)
        // Pane becomes ready AFTER the cancel — the pump must not type.
        recorder.setPaneText(Self.readyPane)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(recorder.sendCount == 0)
    }

    // MARK: - Login-identity watcher

    @Test("watcher fires onLogin exactly once when identity appears, then stops")
    func watcherFiresOnLogin() async {
        let coordinator = LoginSessionCoordinator()
        let recorder = Recorder()
        let profileID = UUID()

        await coordinator.watchLoginIdentity(
            profileID: profileID,
            interval: .milliseconds(10),
            timeout: .seconds(5),
            identity: { recorder.identity },
            onLogin: { recorder.recordLogin() }
        )

        // No login yet — give the watcher a few polls.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(recorder.loginCount == 0)

        recorder.setIdentity("adam@example.com")
        #expect(await waitFor({ recorder.loginCount == 1 }))

        // Stops after firing: no further callbacks accumulate.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(recorder.loginCount == 1)
    }

    @Test("watcher is single-flighted per profile while active")
    func watcherSingleFlight() async {
        let coordinator = LoginSessionCoordinator()
        let recorder = Recorder()
        let profileID = UUID()

        // Register twice while no login exists — the first watcher stays
        // alive (polling), so the second registration must hit the
        // single-flight guard and become a no-op.
        await coordinator.watchLoginIdentity(
            profileID: profileID,
            interval: .milliseconds(10),
            timeout: .seconds(5),
            identity: { recorder.identity },
            onLogin: { recorder.recordLogin() }
        )
        await coordinator.watchLoginIdentity(
            profileID: profileID,
            interval: .milliseconds(10),
            timeout: .seconds(5),
            identity: { recorder.identity },
            onLogin: { recorder.recordLogin() }
        )

        recorder.setIdentity("adam@example.com")
        #expect(await waitFor({ recorder.loginCount >= 1 }))
        // The duplicate registration must not produce a second callback.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(recorder.loginCount == 1)
    }

    @Test("watcher times out without firing, and the profile can be re-watched afterwards")
    func watcherTimeoutAndRewatch() async {
        let coordinator = LoginSessionCoordinator()
        let recorder = Recorder()
        let profileID = UUID()

        await coordinator.watchLoginIdentity(
            profileID: profileID,
            interval: .milliseconds(5),
            timeout: .milliseconds(20),
            identity: { recorder.identity },
            onLogin: { recorder.recordLogin() }
        )
        // Let it time out (identity stays nil).
        try? await Task.sleep(for: .milliseconds(100))
        #expect(recorder.loginCount == 0)

        // A fresh watch after expiry must work (single-flight guard cleared).
        recorder.setIdentity("adam@example.com")
        await coordinator.watchLoginIdentity(
            profileID: profileID,
            interval: .milliseconds(5),
            timeout: .seconds(5),
            identity: { recorder.identity },
            onLogin: { recorder.recordLogin() }
        )
        #expect(await waitFor({ recorder.loginCount == 1 }))
    }

    // MARK: - Pane readings from a holder's typed screen

    /// Builds the screen a holder-backed login tab's reader would answer with.
    private static func screen(
        lines: [String],
        source: TerminalScreen.Source,
        contentObserved: Bool
    ) throws -> TerminalScreen {
        try TerminalScreen(
            lines: lines,
            viewportStart: 0,
            cursor: TerminalScreen.Cursor(row: 0, column: 0, visible: true),
            size: TerminalScreen.Size(columns: 80, rows: 24),
            modes: TerminalScreen.ChildModes(
                bracketedPaste: true, applicationCursor: false, alternateScreen: false),
            modesObserved: true,
            contentObserved: contentObserved,
            source: source,
            ageMilliseconds: 0)
    }

    @Test("paneReading: no reader answered → not evidence")
    func paneReadingWithoutAReader() {
        #expect(
            LoginSessionCoordinator.paneReading(from: nil)
                == .notEvidence("no live holder reader"))
    }

    /// A viewer holds the pty, so the daemon's emulator is not the live screen
    /// — and a grid that is not the live screen proves nothing about now.
    /// Asserted against ready-looking text, which is what makes the refusal
    /// meaningful.
    @Test("paneReading: a screen a viewer is behind → not evidence, ready text or not")
    func paneReadingBehindAViewer() throws {
        for source in [TerminalScreen.Source.staleDaemon, .viewer] {
            let reading = LoginSessionCoordinator.paneReading(
                from: try Self.screen(
                    lines: Self.readyPane.components(separatedBy: "\n"),
                    source: source, contentObserved: true))
            #expect(
                reading
                    == .notEvidence(
                        "a viewer holds the pty, so the daemon's emulator is not the live screen"),
                "a \(source.rawValue) screen was not refused")
        }
    }

    /// The daemon is rendering live, but its emulator was built over a child
    /// that was already running: every cell the child has not repainted since
    /// is something this grid invented.
    @Test("paneReading: a live but unobserved screen → not evidence")
    func paneReadingUnobservedContent() throws {
        let reading = LoginSessionCoordinator.paneReading(
            from: try Self.screen(
                lines: Self.readyPane.components(separatedBy: "\n"),
                source: .daemon, contentObserved: false))
        #expect(
            reading
                == .notEvidence(
                    "the daemon's emulator was built over a running child and has not seen "
                        + "the whole screen"))
    }

    @Test("paneReading: a live, fully observed screen is the text the classifier judges")
    func paneReadingObservedDaemon() throws {
        let lines = Self.readyPane.components(separatedBy: "\n")
        let reading = LoginSessionCoordinator.paneReading(
            from: try Self.screen(lines: lines, source: .daemon, contentObserved: true))
        #expect(reading == .text(lines.joined(separator: "\n")))
        guard case .text(let text) = reading else { return }
        #expect(LoginSessionCoordinator.classifyPane(text) == .promptReady)
    }

    // MARK: - The pump on virtual time

    /// A mutable `PaneReading` the pump reads and the test flips between
    /// advances. Lock-guarded rather than an actor: the pump's `paneText` is a
    /// `@Sendable` closure the test hands over once and never awaits.
    private final class ReadingBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: LoginSessionCoordinator.PaneReading
        init(_ initial: LoginSessionCoordinator.PaneReading) { value = initial }
        var reading: LoginSessionCoordinator.PaneReading {
            lock.lock(); defer { lock.unlock() }
            return value
        }
        func set(_ next: LoginSessionCoordinator.PaneReading) {
            lock.lock(); defer { lock.unlock() }
            value = next
        }
    }

    /// Whole-second pacing so every advance in a chain is one named interval.
    /// The initial delay is zero on purpose: a zero-deadline sleep registers
    /// nothing on `EventDrivenTestClock`, which keeps it out of the chain.
    private static let virtualDelays = LoginSessionCoordinator.Delays(
        pumpInitialDelay: .zero,
        pumpPollInterval: .seconds(1),
        pumpPostSendDelay: .seconds(2),
        pumpTimeout: .seconds(60),
        identityPollInterval: .seconds(2),
        identityPollTimeout: .seconds(4)
    )

    /// The holder's reason for waiting is the pump's, exactly: a screen that is
    /// not evidence takes the same poll arm a boot screen does — no send, no
    /// timeout, just another read.
    ///
    /// Every assertion here is read after an *arming* wait rather than after a
    /// bare advance: the pump arms its next sleep only once the iteration
    /// before it has finished reading (and, on the send iteration, typing), so
    /// the arming is the event that proves the effect landed.
    @Test("pump: a screen that is not evidence is waited out, not typed at")
    func pumpWaitsOutScreensItMayNotJudge() async throws {
        let clock = EventDrivenTestClock()
        let coordinator = LoginSessionCoordinator(delays: Self.virtualDelays, clock: clock)
        let recorder = Recorder()
        let box = ReadingBox(.notEvidence("a viewer holds the pty"))
        let id = UUID()

        await coordinator.registerPendingAutoLogin(terminalID: id)
        await coordinator.startAutoLoginPump(
            terminalID: id,
            paneText: { box.reading },
            typeLogin: { recorder.recordSend() }
        )

        // Two reads of a screen nobody may judge, and nothing typed.
        try await clock.requireAdvanceWhenArmed(by: Self.virtualDelays.pumpPollInterval)
        try await clock.requireSleeperArmed()
        #expect(recorder.sendCount == 0)

        // A live, fully observed ready screen: the next poll types once.
        box.set(.text(Self.readyPane))
        try await clock.requireAdvanceWhenArmed(by: Self.virtualDelays.pumpPollInterval)
        try await clock.requireSleeperArmed()
        #expect(recorder.sendCount == 1)

        // The dialog is up, so the verify read ends the pump.
        box.set(.text(Self.dialogPane))
        try await clock.requireAdvanceWhenArmed(by: Self.virtualDelays.pumpPostSendDelay)
        let stopped = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            await coordinator.isPendingAutoLogin(terminalID: id) == false
        }
        #expect(stopped == .satisfied, "the pump never cleared its registration")
        #expect(recorder.sendCount == 1)
    }

    /// The send cap, on virtual time: a ready screen that never becomes the
    /// dialog is typed at exactly `maxSends` times and then only polled.
    @Test("pump: an unverified send is retried up to the cap and no further")
    func pumpRetriesToTheCapOnVirtualTime() async throws {
        let clock = EventDrivenTestClock()
        let coordinator = LoginSessionCoordinator(delays: Self.virtualDelays, clock: clock)
        let recorder = Recorder()
        let box = ReadingBox(.text(Self.readyPane))
        let id = UUID()

        await coordinator.registerPendingAutoLogin(terminalID: id)
        await coordinator.startAutoLoginPump(
            terminalID: id,
            maxSends: 3,
            paneText: { box.reading },
            typeLogin: { recorder.recordSend() }
        )

        // Each advance waits for the post-send sleep the previous iteration
        // armed, which is the proof its send had already been made.
        try await clock.requireAdvanceWhenArmed(by: Self.virtualDelays.pumpPostSendDelay)
        try await clock.requireAdvanceWhenArmed(by: Self.virtualDelays.pumpPostSendDelay)
        try await clock.requireAdvanceWhenArmed(by: Self.virtualDelays.pumpPostSendDelay)
        // The cap is reached, so this iteration takes the poll arm instead.
        try await clock.requireSleeperArmed()
        #expect(recorder.sendCount == 3)

        try await clock.requireAdvanceWhenArmed(by: Self.virtualDelays.pumpPollInterval)
        try await clock.requireSleeperArmed()
        #expect(recorder.sendCount == 3)

        // Leave nothing parked on a clock nobody will advance again: the
        // cancellation is observed on the next iteration, which this advance
        // releases.
        await coordinator.cancelPendingAutoLogin(terminalID: id)
        try await clock.requireAdvanceWhenArmed(by: Self.virtualDelays.pumpPollInterval)
    }
}
