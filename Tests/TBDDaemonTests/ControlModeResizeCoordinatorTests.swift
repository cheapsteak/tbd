import Foundation
import TBDShared
import Testing
@testable import TBDDaemonLib

/// Unit tests for the resize arbiter (M3.1). No tmux: `commandProvider` hands
/// back a real `TmuxControlCommandClient` whose `writeLine` records the stream
/// writes synchronously, and the test drives reply blocks by hand through
/// `client.handle(...)` — the correlator is exercised, only its stdout is faked.
@Suite("ControlModeResizeCoordinator")
struct ControlModeResizeCoordinatorTests {

    /// Thread-safe, synchronous recorder of stream writes in call order.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _writes: [String] = []
        func record(_ line: String) { lock.lock(); _writes.append(line); lock.unlock() }
        var writes: [String] { lock.lock(); defer { lock.unlock() }; return _writes }
    }

    /// Thread-safe monotonic call counter for the provider seam.
    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// One-shot async gate: `wait()` parks until `open()`; opening first is fine.
    private actor ProviderGate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            opened = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }

    /// Coordinator whose single server "srv" resolves to a client backed by
    /// `recorder`; an unknown server resolves to nil. The client is returned so
    /// tests can feed reply blocks (`%end`/`%error`) back into it.
    private func makeCoordinator()
        -> (ControlModeResizeCoordinator, Recorder, TmuxControlCommandClient) {
        let recorder = Recorder()
        let client = TmuxControlCommandClient(
            writeLine: { recorder.record($0) },
            onFatalError: {})
        let coordinator = ControlModeResizeCoordinator(
            commandProvider: { server in server == "srv" ? client : nil })
        return (coordinator, recorder, client)
    }

    /// Complete the next `count` pending commands with `%end` (success), FIFO.
    private func succeed(_ client: TmuxControlCommandClient, _ count: Int) async {
        for _ in 0..<count {
            await client.handle(.commandSucceeded(number: 0, fromClient: true, lines: []))
        }
    }

    @Test("resize sends ONE write: resize-window then the list-windows fence")
    func oneWriteResizeThenFence() async throws {
        let (coordinator, recorder, _) = makeCoordinator()
        await coordinator.resize(server: "srv", windowID: "@0", cols: 100, rows: 30)

        #expect(recorder.writes.count == 1)
        let write = try #require(recorder.writes.first)
        #expect(write == "resize-window -t @0 -x 100 -y 30\nlist-windows -F '#{window_id}'")
    }

    @Test("the fence is open (layout changes suppressed) until list-windows completes")
    func fenceOpenUntilListWindowsCompletes() async throws {
        let (coordinator, _, client) = makeCoordinator()
        await coordinator.resize(server: "srv", windowID: "@0", cols: 100, rows: 30)

        // Before any reply: our own resize is still echoing → suppress.
        #expect(coordinator.shouldApplyLayoutChange(server: "srv", windowID: "@0") == false)

        // Complete the resize-window block: fence still open.
        await succeed(client, 1)
        #expect(coordinator.shouldApplyLayoutChange(server: "srv", windowID: "@0") == false)

        // Complete the list-windows fence: now external changes are real again.
        await succeed(client, 1)
        #expect(coordinator.shouldApplyLayoutChange(server: "srv", windowID: "@0") == true)
    }

    @Test("suppression is per-window: another window is unaffected")
    func suppressionIsPerWindow() async throws {
        let (coordinator, _, _) = makeCoordinator()
        await coordinator.resize(server: "srv", windowID: "@0", cols: 100, rows: 30)
        #expect(coordinator.shouldApplyLayoutChange(server: "srv", windowID: "@0") == false)
        #expect(coordinator.shouldApplyLayoutChange(server: "srv", windowID: "@1") == true)
    }

    @Test("two overlapping resizes need BOTH fences to close before layout applies")
    func overlappingResizesStackTheCounter() async throws {
        let (coordinator, _, client) = makeCoordinator()
        await coordinator.resize(server: "srv", windowID: "@0", cols: 100, rows: 30)
        await coordinator.resize(server: "srv", windowID: "@0", cols: 120, rows: 40)

        // FIFO order: [resize1, fence1, resize2, fence2]. counter == 2.
        #expect(coordinator.shouldApplyLayoutChange(server: "srv", windowID: "@0") == false)

        // resize1, fence1, resize2 completed → one fence still open.
        await succeed(client, 3)
        #expect(coordinator.shouldApplyLayoutChange(server: "srv", windowID: "@0") == false)

        // fence2 completes → counter back to 0.
        await succeed(client, 1)
        #expect(coordinator.shouldApplyLayoutChange(server: "srv", windowID: "@0") == true)
    }

    @Test("a fence FAILURE also decrements — a dead window must not suppress forever")
    func fenceFailureStillDecrements() async throws {
        let (coordinator, _, client) = makeCoordinator()
        await coordinator.resize(server: "srv", windowID: "@0", cols: 100, rows: 30)

        // resize-window succeeds, then list-windows FAILS (tolerated %error).
        await client.handle(.commandSucceeded(number: 0, fromClient: true, lines: []))
        await client.handle(.commandFailed(number: 0, fromClient: true, lines: ["no server"]))

        #expect(coordinator.shouldApplyLayoutChange(server: "srv", windowID: "@0") == true)
    }

    @Test("an unknown server (nil client) does not crash and leaves the counter untouched")
    func unknownServerIsNoop() async throws {
        let (coordinator, recorder, _) = makeCoordinator()
        await coordinator.resize(server: "nope", windowID: "@0", cols: 100, rows: 30)
        #expect(recorder.writes.isEmpty)
        // No fence opened → layout changes for that window still apply.
        #expect(coordinator.shouldApplyLayoutChange(server: "nope", windowID: "@0") == true)
    }

    @Test("concurrent resizes are latest-wins across the provider hop — the older size never lands last (R7-M1)")
    func concurrentResizeIsLatestWins() async throws {
        // SocketServer spawns an unstructured Task per RPC, so two resize()
        // calls for one window can overlap; the OLDER call's provider hop
        // resolving LAST must not put the older geometry on the wire last.
        let recorder = Recorder()
        let client = TmuxControlCommandClient(
            writeLine: { recorder.record($0) },
            onFatalError: {})
        let gate = ProviderGate()
        let calls = CallCounter()
        let coordinator = ControlModeResizeCoordinator(
            commandProvider: { _ in
                // The FIRST (older) call parks until the test releases it;
                // the second resolves immediately and sends first.
                if calls.next() == 1 { await gate.wait() }
                return client
            })

        // Older resize: stamped first, then suspends in the provider hop.
        let older = Task { await coordinator.resize(server: "srv", windowID: "@0", cols: 80, rows: 24) }
        #expect(await waitUntil({ calls.count == 1 }, timeout: .seconds(15)),
                "older resize never reached the provider")

        // Newer resize: resolves and sends while the older is still parked.
        await coordinator.resize(server: "srv", windowID: "@0", cols: 120, rows: 40)
        #expect(recorder.writes.count == 1)
        #expect(recorder.writes.first?.hasPrefix("resize-window -t @0 -x 120 -y 40\n") == true)

        // Release the older call: it must DROP (a newer size was stamped
        // since), not send 80x24 after 120x40.
        await gate.open()
        await older.value
        #expect(recorder.writes.count == 1,
                "the superseded resize must be dropped, not sent after the newer one")

        // Fence bookkeeping stays balanced: only the sent resize opened a
        // fence, so completing its two blocks closes suppression fully.
        await succeed(client, 2)
        #expect(coordinator.shouldApplyLayoutChange(server: "srv", windowID: "@0") == true)
    }

    @Test("garbage geometry is clamped into sane bounds before it reaches tmux")
    func clampsGeometry() async throws {
        let (coordinator, recorder, _) = makeCoordinator()
        await coordinator.resize(server: "srv", windowID: "@0", cols: 10, rows: 9999)
        let write = try #require(recorder.writes.first)
        // The clamp bounds ARE the shared geometry envelope (R6-M5): the
        // app-side gate refuses to send below the same floor, so app and
        // daemon can never disagree about the minimum sendable size again.
        #expect(write.hasPrefix(
            "resize-window -t @0 -x \(ControlModeGeometry.minCols) -y \(ControlModeGeometry.maxRows)\n"))
        #expect(ControlModeGeometry.minCols == 20)
        #expect(ControlModeGeometry.maxRows == 300)
    }
}
