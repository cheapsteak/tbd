import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("LoginSessionCoordinator")
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
    private func waitFor(
        _ condition: @Sendable () -> Bool,
        timeout: Duration = .seconds(5)
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
            paneText: { recorder.paneText },
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
            paneText: { recorder.paneText },
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
            paneText: { recorder.paneText },
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
            paneText: { recorder.paneText },
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
            terminalID: id, paneText: { recorder.paneText }, typeLogin: sendAndFinish
        )
        await coordinator.startAutoLoginPump(
            terminalID: id, paneText: { recorder.paneText }, typeLogin: sendAndFinish
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
            paneText: { recorder.paneText },
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
}
