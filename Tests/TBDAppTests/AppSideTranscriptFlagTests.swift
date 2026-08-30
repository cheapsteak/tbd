import Foundation
import Testing
@testable import TBDApp

/// Tests for the `appSideTranscriptRead` UserDefaults flag and the single
/// registration gate it drives.
///
/// Isolation matters: TBDApp ships as an unbundled SPM executable, so its
/// `UserDefaults.standard` domain is the developer's real `TBDApp.plist` — the
/// same domain a running production TBDApp reads via `@AppStorage`. Every test
/// below drives the helper through a per-test `UserDefaults(suiteName:)` and
/// tears that domain down afterwards.
@MainActor
@Suite("appSideTranscriptRead flag")
struct AppSideTranscriptFlagTests {

    private func withSuite(_ body: (UserDefaults) -> Void) {
        let name = "TBDAppTests.AppSideTranscript.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    @Test("defaults to off when nobody has chosen")
    func defaultsOff() {
        withSuite { defaults in
            #expect(AppState.appSideTranscriptReadEnabled(defaults: defaults) == false)
            #expect(AppState.appSideTranscriptReadDefault == false)
        }
    }

    @Test("an explicit choice is distinguishable from never having chosen")
    func explicitChoiceIsDistinguishable() {
        withSuite { defaults in
            #expect(defaults.object(forKey: AppState.appSideTranscriptReadKey) == nil,
                    "unset must read as nil, not as false")
            defaults.set(false, forKey: AppState.appSideTranscriptReadKey)
            #expect(defaults.object(forKey: AppState.appSideTranscriptReadKey) as? Bool == false)
            #expect(AppState.appSideTranscriptReadEnabled(defaults: defaults) == false)
            defaults.set(true, forKey: AppState.appSideTranscriptReadKey)
            #expect(AppState.appSideTranscriptReadEnabled(defaults: defaults) == true)
        }
    }

    @Test("with the flag off nothing registers, so no file is ever read")
    func flagOffDoesNotRegister() async {
        let scheduler = TranscriptPollScheduler(source: TranscriptSource())
        await TranscriptPaneRegistration.apply(
            enabled: false, sessionID: "s1", path: "/tmp/whatever",
            tier: .foreground, token: TranscriptPaneToken(), scheduler: scheduler)
        #expect(await scheduler.registeredSessionIDs.isEmpty)
    }

    @Test("with the flag on the session registers")
    func flagOnRegisters() async {
        let scheduler = TranscriptPollScheduler(source: TranscriptSource())
        let pane = TranscriptPaneToken()
        await TranscriptPaneRegistration.apply(
            enabled: true, sessionID: "s1", path: "/tmp/whatever",
            tier: .foreground, token: pane, scheduler: scheduler)
        #expect(await scheduler.registeredSessionIDs == ["s1"])
        await scheduler.deregister(sessionID: "s1", token: pane)
    }

    @Test("a nil or empty path never registers, even with the flag on")
    func missingPathDoesNotRegister() async {
        let scheduler = TranscriptPollScheduler(source: TranscriptSource())
        let pane = TranscriptPaneToken()
        await TranscriptPaneRegistration.apply(
            enabled: true, sessionID: "s1", path: nil,
            tier: .foreground, token: pane, scheduler: scheduler)
        await TranscriptPaneRegistration.apply(
            enabled: true, sessionID: "s2", path: "",
            tier: .foreground, token: pane, scheduler: scheduler)
        #expect(await scheduler.registeredSessionIDs.isEmpty)
    }

    @Test("the flag alone does not choose the app-side transport: a path is required")
    func transportFallsBackToTheDaemonWithoutAPath() {
        #expect(TranscriptPaneTransport.resolve(appSideEnabled: true, path: nil) == .daemonPoll,
                "a nil path must fall through to the daemon, which resolves the file server-side")
        #expect(TranscriptPaneTransport.resolve(appSideEnabled: true, path: "") == .daemonPoll,
                "an empty path must fall through to the daemon, not strand the pane")
    }

    @Test("the flag plus a usable path chooses the app-side transport")
    func transportChoosesAppSideWithAPath() {
        #expect(TranscriptPaneTransport.resolve(appSideEnabled: true, path: "/tmp/session.jsonl")
                == .appSide(path: "/tmp/session.jsonl"))
    }

    @Test("with the flag off the daemon transport is chosen whatever the path")
    func transportIgnoresThePathWhenTheFlagIsOff() {
        #expect(TranscriptPaneTransport.resolve(appSideEnabled: false, path: "/tmp/session.jsonl")
                == .daemonPoll)
        #expect(TranscriptPaneTransport.resolve(appSideEnabled: false, path: nil) == .daemonPoll)
    }

    /// The same pane on both sides — it is the flag under it that changed, so
    /// it releases the hold it took, and the session stops being polled.
    @Test("turning the flag off deregisters a pane that had registered")
    func flagOffDeregistersAnExistingRegistration() async {
        let scheduler = TranscriptPollScheduler(source: TranscriptSource())
        let pane = TranscriptPaneToken()
        await TranscriptPaneRegistration.apply(
            enabled: true, sessionID: "s1", path: "/tmp/whatever",
            tier: .foreground, token: pane, scheduler: scheduler)
        #expect(await scheduler.registeredSessionIDs == ["s1"])
        await TranscriptPaneRegistration.apply(
            enabled: false, sessionID: "s1", path: "/tmp/whatever",
            tier: .foreground, token: pane, scheduler: scheduler)
        #expect(await scheduler.registeredSessionIDs.isEmpty)
    }
}
