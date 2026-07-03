import Foundation
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

    @Test("garbage geometry is clamped into sane bounds before it reaches tmux")
    func clampsGeometry() async throws {
        let (coordinator, recorder, _) = makeCoordinator()
        await coordinator.resize(server: "srv", windowID: "@0", cols: 10, rows: 9999)
        let write = try #require(recorder.writes.first)
        #expect(write.hasPrefix("resize-window -t @0 -x 20 -y 300\n"))
    }
}
