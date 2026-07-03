import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("LoginSessionCoordinator")
struct LoginSessionCoordinatorTests {

    // MARK: - Auto-login pending set (consume-once)

    @Test("consumePendingAutoLogin returns true exactly once per registration")
    func consumeOnce() async {
        let coordinator = LoginSessionCoordinator()
        let id = UUID()
        await coordinator.registerPendingAutoLogin(terminalID: id)

        #expect(await coordinator.consumePendingAutoLogin(terminalID: id) == true)
        // Second trigger (hook vs. spawn-fallback race) must lose.
        #expect(await coordinator.consumePendingAutoLogin(terminalID: id) == false)
    }

    @Test("consumePendingAutoLogin for an unregistered terminal is false")
    func consumeUnregistered() async {
        let coordinator = LoginSessionCoordinator()
        #expect(await coordinator.consumePendingAutoLogin(terminalID: UUID()) == false)
    }

    @Test("cancelPendingAutoLogin drops the pending send")
    func cancelDropsPending() async {
        let coordinator = LoginSessionCoordinator()
        let id = UUID()
        await coordinator.registerPendingAutoLogin(terminalID: id)
        await coordinator.cancelPendingAutoLogin(terminalID: id)
        #expect(await coordinator.consumePendingAutoLogin(terminalID: id) == false)
    }

    // MARK: - Login-identity watcher

    /// Thread-safe recorder for watcher callbacks.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _loginCount = 0
        private var _identity: String?
        var loginCount: Int {
            lock.lock(); defer { lock.unlock() }
            return _loginCount
        }
        func recordLogin() {
            lock.lock(); defer { lock.unlock() }
            _loginCount += 1
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
