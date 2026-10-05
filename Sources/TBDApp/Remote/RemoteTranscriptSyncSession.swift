import Foundation
import Observation
import TBDShared

/// Which session a transcript pane syncs, and whether it syncs right now.
///
/// `RemoteTranscriptLivePane` feeds this the facts it observes, and this class
/// makes every decision from them, so those decisions are testable without a
/// view:
///
/// - **Whether to sync** – only while the pane is on screen (mounted and its
///   session is the selected one) **and** the app is active. Either one going
///   false stops the driver; both true again restarts it.
/// - **Which session** – `start(_:)` always stops the current driver before
///   making the next one, so a selection change never leaves the previous
///   session's driver polling behind the new one.
@MainActor
@Observable
final class RemoteTranscriptSyncSession {
    typealias DriverFactory = @MainActor (RemoteSessionSelection) -> RemoteTranscriptSyncDriver
    typealias DriverHook = @MainActor (RemoteTranscriptSyncDriver) -> Void

    /// The driver for the current session, nil while stopped. Observed, so the
    /// pane re-renders from the new driver's snapshot after a switch.
    private(set) var driver: RemoteTranscriptSyncDriver?

    @ObservationIgnored private(set) var isOnScreen: Bool
    @ObservationIgnored private(set) var appActive: Bool
    @ObservationIgnored private let makeDriver: DriverFactory
    @ObservationIgnored private let didStart: DriverHook
    @ObservationIgnored private let didStop: DriverHook

    init(
        isOnScreen: Bool,
        appActive: Bool,
        makeDriver: @escaping DriverFactory,
        didStart: @escaping DriverHook = { _ in },
        didStop: @escaping DriverHook = { _ in }
    ) {
        self.isOnScreen = isOnScreen
        self.appActive = appActive
        self.makeDriver = makeDriver
        self.didStart = didStart
        self.didStop = didStop
    }

    /// The one rule: sync only while the pane is on screen and the app active.
    static func shouldSync(isOnScreen: Bool, appActive: Bool) -> Bool {
        isOnScreen && appActive
    }

    var shouldSync: Bool { Self.shouldSync(isOnScreen: isOnScreen, appActive: appActive) }

    /// Sync `selection` from now on. Stops the current driver first.
    func start(
        _ selection: RemoteSessionSelection,
        agentState: RemoteTranscriptSyncDriver.AgentStateMark?
    ) {
        stop()
        let driver = makeDriver(selection)
        self.driver = driver
        didStart(driver)
        driver.noteAgentState(agentState)
        driver.setActive(shouldSync)
    }

    /// Stop syncing altogether — the pane went away.
    func stop() {
        guard let driver else { return }
        driver.stop()
        didStop(driver)
        self.driver = nil
    }

    func setOnScreen(_ onScreen: Bool) {
        isOnScreen = onScreen
        driver?.setActive(shouldSync)
    }

    func setAppActive(_ active: Bool) {
        appActive = active
        driver?.setActive(shouldSync)
    }

    func noteAgentState(_ mark: RemoteTranscriptSyncDriver.AgentStateMark?) {
        driver?.noteAgentState(mark)
    }
}
