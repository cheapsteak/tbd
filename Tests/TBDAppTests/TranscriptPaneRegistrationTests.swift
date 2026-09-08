import Foundation
import Testing
@testable import TBDApp

/// Tests for the single gate that decides whether a live transcript pane
/// registers with the poll scheduler and reads its session file in-process, or
/// falls back to the daemon's `terminal.transcript` poll.
@MainActor
@Suite("transcript pane registration")
struct TranscriptPaneRegistrationTests {

    @Test("a session with a usable path registers")
    func registersWithAPath() async {
        let scheduler = TranscriptPollScheduler(source: TranscriptSource())
        let pane = TranscriptPaneToken()
        await TranscriptPaneRegistration.apply(
            sessionID: "s1", path: "/tmp/whatever",
            tier: .foreground, token: pane, scheduler: scheduler)
        #expect(await scheduler.registeredSessionIDs == ["s1"])
        await scheduler.deregister(sessionID: "s1", token: pane)
    }

    @Test("a nil or empty path never registers")
    func missingPathDoesNotRegister() async {
        let scheduler = TranscriptPollScheduler(source: TranscriptSource())
        let pane = TranscriptPaneToken()
        await TranscriptPaneRegistration.apply(
            sessionID: "s1", path: nil,
            tier: .foreground, token: pane, scheduler: scheduler)
        await TranscriptPaneRegistration.apply(
            sessionID: "s2", path: "",
            tier: .foreground, token: pane, scheduler: scheduler)
        #expect(await scheduler.registeredSessionIDs.isEmpty)
    }

    /// The same pane on both sides — it is the path under it that vanished, so
    /// it releases the hold it took, and the session stops being polled.
    @Test("losing the path deregisters a pane that had registered")
    func losingThePathDeregistersAnExistingRegistration() async {
        let scheduler = TranscriptPollScheduler(source: TranscriptSource())
        let pane = TranscriptPaneToken()
        await TranscriptPaneRegistration.apply(
            sessionID: "s1", path: "/tmp/whatever",
            tier: .foreground, token: pane, scheduler: scheduler)
        #expect(await scheduler.registeredSessionIDs == ["s1"])
        await TranscriptPaneRegistration.apply(
            sessionID: "s1", path: nil,
            tier: .foreground, token: pane, scheduler: scheduler)
        #expect(await scheduler.registeredSessionIDs.isEmpty)
    }

    @Test("without a path the transport falls back to the daemon")
    func transportFallsBackToTheDaemonWithoutAPath() {
        #expect(TranscriptPaneTransport.resolve(path: nil) == .daemonPoll,
                "a nil path must fall through to the daemon, which resolves the file server-side")
        #expect(TranscriptPaneTransport.resolve(path: "") == .daemonPoll,
                "an empty path must fall through to the daemon, not strand the pane")
    }

    @Test("a usable path chooses the app-side transport")
    func transportChoosesAppSideWithAPath() {
        #expect(TranscriptPaneTransport.resolve(path: "/tmp/session.jsonl")
                == .appSide(path: "/tmp/session.jsonl"))
    }

    /// An empty stream path means "no stream file", the same as nil — otherwise
    /// the registration would have every tick stat `""` forever.
    @Test("an empty stream path registers as no stream path at all")
    func emptyStreamPathIsCarriedAsNil() async {
        let scheduler = TranscriptPollScheduler(source: TranscriptSource())
        let pane = TranscriptPaneToken()
        await TranscriptPaneRegistration.apply(
            sessionID: "s1", path: "/tmp/whatever", streamPath: "",
            tier: .foreground, token: pane, scheduler: scheduler)
        #expect(await scheduler.registeredSessionIDs == ["s1"])
        #expect(await scheduler.registeredStreamPath(sessionID: "s1") == nil)
        await scheduler.deregister(sessionID: "s1", token: pane)
    }

    /// The other half, so the normalisation above cannot pass by dropping every
    /// stream path.
    @Test("a usable stream path is carried through to the registration")
    func usableStreamPathIsCarried() async {
        let scheduler = TranscriptPollScheduler(source: TranscriptSource())
        let pane = TranscriptPaneToken()
        await TranscriptPaneRegistration.apply(
            sessionID: "s1", path: "/tmp/whatever", streamPath: "/tmp/stream.jsonl",
            tier: .foreground, token: pane, scheduler: scheduler)
        #expect(await scheduler.registeredStreamPath(sessionID: "s1") == "/tmp/stream.jsonl")
        await scheduler.deregister(sessionID: "s1", token: pane)
    }
}
