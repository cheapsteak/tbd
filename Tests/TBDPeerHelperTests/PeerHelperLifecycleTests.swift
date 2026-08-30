import Darwin
import Foundation
import TBDShared
import Testing

/// The shadow peer helper's exit paths, driven against the real binary.
///
/// **The requirement these pin is the sharpest one in the design**: "Both
/// halves **MUST** close and unlink on link loss"
/// (`docs/specs/2026-08-29-remote-peer-messaging-design.md` § "Failure
/// semantics"). A listening socket cannot decline — `connect()` succeeds while
/// the listener exists and the protocol is connect-write-close with no
/// handshake — so a helper that stops working without unlinking reports success
/// to every sender forever, and Claude Code's reaper never collects it because
/// the reaper checks pid liveness and nothing else.
///
/// Until this suite existed, that requirement was "covered" only by a
/// daemon-side test asserting that a fake's counter incremented. **Nothing
/// anywhere bound a socket, published a record, and checked that both were
/// gone afterwards** — so a helper that unlinked nothing passed the whole
/// suite, which is exactly the shape both bugs this suite was written for had.
///
/// `.serialized` because each test spawns a real child and waits on real
/// filesystem effects; the suite stays in the fast parallel pass because every
/// helper lives for milliseconds and every wait is a bounded poll
/// (`Tests/CLAUDE.md` § "Test tiers").
@Suite(.serialized)
struct PeerHelperLifecycleTests {

    /// The load-bearing path: the kernel closes stdin even for a `SIGKILL`ed
    /// daemon, so this is the only cleanup that survives the daemon losing the
    /// chance to run any code at all.
    @Test func stdinEOFUnlinksTheSocketAndTheRecord() async throws {
        let helper = try SpawnedPeerHelper(name: "acme:eof-shadow")
        defer { helper.tearDown() }

        #expect(
            await helper.waitForPublication(),
            "the helper never published both artifacts: socket \(helper.socketPath), "
                + "record \(helper.recordPath)")

        // The record has to describe the process that actually owns the socket:
        // the registry loader parses the pid out of the *filename*, so the
        // filename, the `pid` field and the socket's own name must agree.
        let stored = try helper.store.read(pid: helper.pid)
        let record = try #require(stored, "no record at \(helper.recordPath)")
        #expect(record.pid == helper.pid)
        #expect(record.messagingSocketPath == helper.socketPath)
        #expect(record.name == "acme:eof-shadow")
        #expect(record.status == "idle")
        #expect(record.pidDomain == ShadowPeerRecord.localPIDDomain)
        #expect(record.peerFeatures.isEmpty)
        #expect(record.version == nil)

        helper.closeStdin()

        #expect(await helper.waitForExit(), "the helper outlived its stdin close")
        #expect(
            helper.exitStatus == 0,
            "stdin EOF must exit through the ordinary return, which is what runs the "
                + "unlink defers; got \(String(describing: helper.exitStatus))")
        #expect(
            await helper.waitForReclamation(),
            "socket present: \(helper.socketExists), record present: \(helper.recordExists)")
    }

    /// **The regression test for the self-pipe deadlock.**
    ///
    /// The helper's shutdown ran `drain(fd:)` as `while read(fd, …) > 0`, over a
    /// pipe created blocking whose write end this process holds open for life.
    /// The first read took the signal byte; the second blocked forever. Darwin's
    /// `signal(3)` installs handlers with `SA_RESTART`, so a later signal
    /// restarted that read rather than failing it with `EINTR` — the helper
    /// could not even be signalled out of its own signal handler.
    ///
    /// The consequence is what makes this worth a test rather than a comment:
    /// `return 0` and both unlink `defer`s were unreachable on the signal path,
    /// so any SIGTERM — a logout, a stray `pkill`, a shell hangup — left a
    /// helper wedged **alive**, socket still bound and record still published.
    /// Every local session then saw a peer whose `connect()` succeeded and whose
    /// messages were silently discarded.
    ///
    /// Two assertions carry the regression, and both are needed. `waitForExit`
    /// catches the wedge; `exitStatus == 0` catches the subtler
    /// alternative, a helper that dies *from* the signal (default disposition,
    /// or an escalation to SIGKILL) and so exits without running any `defer`.
    @Test(arguments: [SIGTERM, SIGINT, SIGHUP])
    func aTerminationSignalUnlinksTheSocketAndTheRecord(_ received: Int32) async throws {
        let helper = try SpawnedPeerHelper(name: "acme:signal-shadow")
        defer { helper.tearDown() }

        #expect(await helper.waitForPublication(), "the helper never published")
        #expect(helper.socketExists)
        #expect(helper.recordExists)

        #expect(kill(helper.pid, received) == 0)

        #expect(
            await helper.waitForExit(),
            "signal \(received) did not end the helper — it is wedged alive with its socket "
                + "still bound and its record still published, which is a peer that lies "
                + "about being reachable")
        #expect(
            helper.exitStatus == 0,
            "signal \(received) must reach the same ordinary return stdin EOF does, so the "
                + "unlink defers run; got \(String(describing: helper.exitStatus))")
        #expect(
            await helper.waitForReclamation(),
            "signal \(received) left socket present: \(helper.socketExists), "
                + "record present: \(helper.recordExists)")
    }

    /// The third exit: the far side withdrew this shadow while the daemon is
    /// still alive. A different fact from EOF, and the same cleanup.
    @Test func aPeerGoneLineWithdrawsTheShadowAndUnlinksBoth() async throws {
        let helper = try SpawnedPeerHelper(name: "acme:withdrawn-shadow")
        defer { helper.tearDown() }

        #expect(await helper.waitForPublication(), "the helper never published")

        try helper.send(.peerGone(handle: helper.handle))

        #expect(await helper.waitForExit(), "a peer-gone line for this handle must end it")
        #expect(helper.exitStatus == 0)
        #expect(
            await helper.waitForReclamation(),
            "socket present: \(helper.socketExists), record present: \(helper.recordExists)")
    }

    /// A helper is answerable for exactly one shadow, so a line about any other
    /// handle is the daemon's business. Written as its own test because the
    /// `guard handle == options.handle` it pins has no other observable effect:
    /// drop the guard and this helper tears itself down on a line meant for a
    /// sibling.
    @Test func aLineNamingAnotherHandleIsIgnored() async throws {
        let helper = try SpawnedPeerHelper(name: "acme:minding-its-own-business")
        defer { helper.tearDown() }

        #expect(await helper.waitForPublication(), "the helper never published")

        try helper.send(.peerGone(handle: "not-\(helper.handle)"))
        try helper.send(.peer(PeerBridgePeer(
            handle: "not-\(helper.handle)", name: "acme:somebody-else", status: "busy",
            peerProtocol: PeerBridgeFrameCodec.peerProtocol)))

        #expect(await helper.lineEmitted(during: 0.5) == nil)
        #expect(helper.isRunning, "a line for another handle must not end this helper")
        #expect(helper.socketExists)
        #expect(helper.recordExists)

        let stored = try helper.store.read(pid: helper.pid)
        let record = try #require(stored)
        #expect(record.name == "acme:minding-its-own-business")
        #expect(record.status == "idle")
    }

    /// A `peer` line rewrites the record in place — and, critically, rewrites it
    /// with **the same key set**.
    ///
    /// The key set is the contract and it is a whitelist: one key Claude Code
    /// does not define makes the record survive on disk and vanish from every
    /// listing (measured, `docs/specs/2026-08-29-remote-peer-messaging-design.md`
    /// § "What was measured"). A rewrite is the one moment the composed set
    /// could drift without anybody noticing, because the shadow keeps working
    /// until the next rewrite and then silently stops being visible.
    @Test func aControlFrameRewritesTheRecordWithoutChangingItsKeySet() async throws {
        let helper = try SpawnedPeerHelper(name: "acme:before", status: "idle")
        defer { helper.tearDown() }

        #expect(await helper.waitForPublication(), "the helper never published")

        let stored = try helper.store.read(pid: helper.pid)
        let before = try #require(stored)
        let keysBefore = try helper.recordKeys()

        try helper.send(.peer(PeerBridgePeer(
            handle: helper.handle, name: "acme:after", status: "busy",
            peerProtocol: PeerBridgeFrameCodec.peerProtocol)))

        let updated = await helper.waitForRecord { $0.status == "busy" }
        let after = try #require(updated, "the record's status never followed the peer line")
        #expect(after.name == "acme:after")
        #expect(after.status == "busy")

        // Identity survives a rewrite. A shadow republished under a fresh
        // session id is a shadow every peer that had settled into addressing it
        // is now addressing something else.
        #expect(after.pid == before.pid)
        #expect(after.sessionID == before.sessionID)
        #expect(after.messagingSocketPath == before.messagingSocketPath)
        #expect(after.procStart == before.procStart)
        #expect(after.cwd == before.cwd)

        let keysAfter = try helper.recordKeys()
        #expect(
            keysAfter == keysBefore,
            "the rewrite changed the record's key set: added "
                + "\(keysAfter.subtracting(keysBefore).sorted()), removed "
                + "\(keysBefore.subtracting(keysAfter).sorted())")
        #expect(
            keysAfter.isSubset(of: ShadowPeerRecord.claudeCodeDefinedKeys),
            "the record carries a key Claude Code does not define, which makes it invisible "
                + "to every listing while surviving on disk: "
                + "\(keysAfter.subtracting(ShadowPeerRecord.claudeCodeDefinedKeys).sorted())")
        // Two keys are forbidden outright rather than merely undefined: a shadow
        // has no local terminal, and it has no session on Anthropic's relay.
        #expect(!keysAfter.contains("tmux"))
        #expect(!keysAfter.contains("bridgeSessionId"))
    }
}
