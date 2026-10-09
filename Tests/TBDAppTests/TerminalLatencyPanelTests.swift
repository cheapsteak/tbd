import AppKit
import Darwin
import Foundation
import SwiftTerm
import TBDShared
import Testing

@testable import TBDApp

/// The panel's half of the terminal latency instrument, exercised against a
/// real `Coordinator` rather than a stand-in closure.
///
/// The refusals this file covers are the ones a hand-written probe closure
/// cannot assert: they are decided by the panel's own outbound path and by its
/// attach state, so the only way to know they fire is to drive the closure the
/// panel actually registered. The pattern — a headless `Coordinator()` and a
/// `TBDTerminalView` over a socket pair standing in for the vended pty — is
/// `HolderInjectionDeliveryTests`'.
///
/// The diagnostic is injected, never resolved from the process-wide gate:
/// resolving it reads `UserDefaults.standard`, which on this unbundled
/// executable is the developer's real `TBDApp.plist`, and arms a watch on the
/// real runtime directory.
@MainActor
@Suite("Terminal latency panel")
struct TerminalLatencyPanelTests {

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ line: String) {
            lock.lock()
            storage.append(line)
            lock.unlock()
        }

        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private func makeSocketPair() throws -> (Int32, Int32) {
        var pair: [Int32] = [-1, -1]
        try pair.withUnsafeMutableBufferPointer { buf in
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress) == 0 else {
                throw FDChannelError.sendFailed(errno)
            }
        }
        return (pair[0], pair[1])
    }

    private func readAvailable(from fd: Int32, within milliseconds: Int32 = 200) -> Data {
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        var remaining = milliseconds
        while remaining > 0 {
            var watched = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&watched, 1, 10) > 0 else { remaining -= 10; continue }
            let read = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if read <= 0 { break }
            out.append(contentsOf: buffer[0..<read])
            break
        }
        return out
    }

    private func request(terminalID: UUID, seq: UInt64) -> Data {
        Data(#"{"terminalID": "\#(terminalID.uuidString)", "seq": \#(seq)}"#.utf8)
    }

    /// Stands in for the daemon's attach RPCs. `readyError` is the refusal the
    /// daemon gives a descriptor it has not accounted for; `readyGate` holds
    /// the ack open instead, which is the window the daemon is still the
    /// session's writer in.
    private struct StubAttach: HolderAttaching {
        let attachment: HolderAttachment
        var readyError: (any Error)?
        var readyGate: ReadyGate?

        func attach(
            worktreeID: UUID, paneID: String, terminalID: UUID
        ) async throws -> HolderAttachment { attachment }

        func ready(
            worktreeID: UUID, paneID: String, terminalID: UUID, generation: UInt64
        ) async throws {
            if let readyError { throw readyError }
            if let readyGate {
                await readyGate.noteEntered()
                await readyGate.waitForRelease()
            }
        }

        func detach(
            worktreeID: UUID, paneID: String, terminalID: UUID, generation: UInt64,
            snapshotPreamble: Data
        ) async throws {}
    }

    private struct ReadyRefused: Error {}

    /// A `ready` the test opens and closes by hand.
    ///
    /// Both halves are needed: the test has to know the panel has REACHED the
    /// ack before it asks anything of it, and the panel has to stay there until
    /// the test is done looking. Main-actor confined, because everything it
    /// coordinates — the panel's attach task and the test body — already is.
    @MainActor
    private final class ReadyGate {
        private var enteredWaiter: CheckedContinuation<Void, Never>?
        private var didEnter = false
        private var releaseWaiter: CheckedContinuation<Void, Never>?
        private var didRelease = false

        func noteEntered() {
            didEnter = true
            enteredWaiter?.resume()
            enteredWaiter = nil
        }

        func waitUntilEntered() async {
            if didEnter { return }
            await withCheckedContinuation { enteredWaiter = $0 }
        }

        func release() {
            didRelease = true
            releaseWaiter?.resume()
            releaseWaiter = nil
        }

        func waitForRelease() async {
            if didRelease { return }
            await withCheckedContinuation { releaseWaiter = $0 }
        }
    }

    /// One turn of the main queue. `feedSnapshot` and its handback twin lower
    /// their ingest flag from a `DispatchQueue.main.async` block rather than on
    /// return, so this is how a test gets to the other side of one.
    private func mainQueueTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor
    private struct Panel {
        /// Held for the panel's lifetime: `Coordinator.appState` is weak, and
        /// a released one makes `panelKind()` answer nil — which the diagnostic
        /// correctly refuses as `notshell`, for the wrong reason entirely.
        let state: AppState
        let coordinator: TerminalPanelRepresentable.Coordinator
        let diagnostic: TerminalLatencyDiagnostic
        let lines: Lines
        let worktreeID: UUID
        let terminalID: UUID
        let sessionEnd: Int32
        let view: TBDTerminalView
        let defaults: UserDefaults
        let suiteName: String
        /// Non-nil only for a panel whose attach was left in flight, so the
        /// test can release the gate and then join it.
        let attaching: Task<Void, Never>?

        func refusal(_ reason: String) -> String {
            "echorefused terminal=\(terminalID.uuidString) reason=\(reason)"
        }

        /// Rewrite the terminal's row with a different kind. The probe's kind
        /// resolver reads `AppState` at REQUEST time, which is what makes the
        /// same panel answer differently before and after this.
        func setKind(_ kind: TerminalKind) {
            state.terminals[worktreeID] = [Terminal(
                id: terminalID,
                worktreeID: worktreeID,
                tmuxWindowID: "",
                tmuxPaneID: "",
                label: "Shell",
                kind: kind,
                transport: .holder
            )]
        }

        func tearDown() {
            coordinator.cleanup()
            Darwin.close(sessionEnd)
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    /// A holder-backed panel wired as production wires one, with the latency
    /// diagnostic on. `vending` replaces the pty with a descriptor whose writes
    /// always fail; `readyError` makes the daemon refuse the attach ack;
    /// `readyGate` leaves the attach suspended AT the ack, and the returned
    /// panel's `attaching` task is what finishes it.
    @MainActor
    private func makePanel(
        vending: Int32? = nil,
        readyError: (any Error)? = nil,
        readyGate: ReadyGate? = nil,
        kind: TerminalKind = .shell
    ) async throws -> Panel {
        let (sessionEnd, paired) = try makeSocketPair()
        let vended = vending ?? paired
        if vending != nil { Darwin.close(paired) }
        _ = fcntl(vended, F_SETFL, fcntl(vended, F_GETFL, 0) | O_NONBLOCK)

        let worktreeID = UUID()
        let terminalID = UUID()
        let state = AppState()
        state.terminals[worktreeID] = [Terminal(
            id: terminalID,
            worktreeID: worktreeID,
            tmuxWindowID: "",
            tmuxPaneID: "",
            label: "Shell",
            kind: kind,
            transport: .holder
        )]

        let suiteName = "TBDAppTests.TerminalLatencyPanel.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let view = TBDTerminalView(
            frame: CGRect(x: 0, y: 0, width: 600, height: 300),
            font: TBDTerminalView.defaultMonospaceFont,
            appearance: AppearanceSettings(defaults: defaults))

        let lines = Lines()
        let diagnostic = TerminalLatencyDiagnostic(now: { 0 }, emit: { lines.append($0) })

        let coordinator = TerminalPanelRepresentable.Coordinator()
        coordinator.appState = state
        coordinator.panelID = terminalID
        // `makeNSView` does this in production, and the probe's first guard
        // reads it: this reference is weak, so the fixture holds the view too.
        coordinator.terminalView = view
        coordinator.latencyDiagnosticForTesting = diagnostic
        coordinator.holderAttachClient = StubAttach(
            attachment: HolderAttachment(
                ptyFD: vended, generation: 7, snapshotPreamble: Data()),
            readyError: readyError,
            readyGate: readyGate)

        // With a gate the attach is LEFT RUNNING on purpose: it suspends
        // inside `ready`, which is the window under test, and awaiting it here
        // would never return.
        var attaching: Task<Void, Never>?
        if readyGate == nil {
            await coordinator.startHolderClient(terminalView: view)
        } else {
            attaching = Task { @MainActor in
                await coordinator.startHolderClient(terminalView: view)
            }
        }

        return Panel(
            state: state, coordinator: coordinator, diagnostic: diagnostic, lines: lines,
            worktreeID: worktreeID, terminalID: terminalID, sessionEnd: sessionEnd, view: view,
            defaults: defaults, suiteName: suiteName, attaching: attaching)
    }

    // MARK: - The write the panel could not place

    /// The positive control, and the reason the refusal below is evidence: on a
    /// live panel the probe's token really does leave through the panel's own
    /// outbound path and really does reach the session's descriptor.
    @Test("a live panel's probe writes its token to the session and refuses nothing")
    func probeWritesTheTokenThroughThePanel() async throws {
        let panel = try await makePanel()
        defer { panel.tearDown() }

        panel.diagnostic.handleRequest(request(terminalID: panel.terminalID, seq: 11))

        #expect(panel.lines.all.isEmpty)
        #expect(readAvailable(from: panel.sessionEnd) == Data("lp11z\r".utf8))
    }

    /// A write the panel swallowed is not a measurement of the transport.
    ///
    /// The queue answers `.unwritable` when the bytes reached nothing — a pty
    /// whose child has exited answers that way for every keystroke — and a
    /// read-only descriptor is that state for a panel that is otherwise live.
    /// Before the fix the probe discarded that answer and returned `nil`, so
    /// the request was recorded as a token in flight and the run's only trace
    /// of it was an `echolost` line blaming the transport.
    @Test("a probe whose write reaches no transport is refused as unwritable")
    func probeOnAnUnwritablePanelIsRefused() async throws {
        let readOnly = Darwin.open("/dev/null", O_RDONLY)
        try #require(readOnly >= 0)
        let panel = try await makePanel(vending: readOnly)
        defer { panel.tearDown() }

        panel.diagnostic.handleRequest(request(terminalID: panel.terminalID, seq: 12))

        #expect(
            panel.lines.all
                == ["echorefused terminal=\(panel.terminalID.uuidString) reason=unwritable"])
    }

    /// And the refusal retires the token it armed, so the next request does not
    /// report a loss for bytes no transport was ever given.
    @Test("an unwritable probe leaves no pending token for the next request to lose")
    func unwritableProbeLeavesNoPendingToken() async throws {
        let readOnly = Darwin.open("/dev/null", O_RDONLY)
        try #require(readOnly >= 0)
        let panel = try await makePanel(vending: readOnly)
        defer { panel.tearDown() }

        panel.diagnostic.handleRequest(request(terminalID: panel.terminalID, seq: 1))
        panel.diagnostic.handleRequest(request(terminalID: panel.terminalID, seq: 2))

        #expect(panel.lines.all.filter { $0.hasPrefix("echolost ") }.isEmpty)
    }

    // MARK: - An attach that came apart

    /// The PASSIVE tap is installed before the attach is acknowledged — it only
    /// observes bytes the panel is already being given — so every path that
    /// gives up after that point has to withdraw it, from the view and from the
    /// holder both. The probe is never registered on this path at all: a claim
    /// standing for a panel with no session answers a later request by writing
    /// into nothing and reports the silence as the transport's.
    @Test("an attach refused at ready withdraws the panel's tap and registers no probe")
    func refusedReadyWithdrawsTheRegistration() async throws {
        let panel = try await makePanel(readyError: ReadyRefused())
        defer { panel.tearDown() }

        #expect(panel.diagnostic.registrationCount == 0)
        #expect(panel.view.latencyTap == nil)

        panel.diagnostic.handleRequest(request(terminalID: panel.terminalID, seq: 3))
        #expect(panel.lines.all == [panel.refusal("unknownterminal")])
    }

    /// The ack is what transfers the pty. Until it lands the daemon is still
    /// the session's writer and still draining it, so a request answered in
    /// that window would put the probe's bytes through `holderWriteFD` into a
    /// descriptor this panel does not own yet.
    ///
    /// Its own positive control is the second half: the same panel, the same
    /// request, once the ack has landed — so the refusal is the window and not
    /// a panel that never worked.
    @Test("a request landing before the attach ack is refused, and lands once it is acked")
    func probeBeforeReadyIsRefusedAndAfterItIsWritten() async throws {
        let gate = ReadyGate()
        let panel = try await makePanel(readyGate: gate)
        defer { panel.tearDown() }
        await gate.waitUntilEntered()

        panel.diagnostic.handleRequest(request(terminalID: panel.terminalID, seq: 5))
        #expect(panel.lines.all == [panel.refusal("unknownterminal")])
        #expect(readAvailable(from: panel.sessionEnd).isEmpty)

        gate.release()
        await panel.attaching?.value

        #expect(panel.diagnostic.registrationCount == 1)
        panel.diagnostic.handleRequest(request(terminalID: panel.terminalID, seq: 6))
        #expect(panel.lines.all == [panel.refusal("unknownterminal")])
        #expect(readAvailable(from: panel.sessionEnd) == Data("lp6z\r".utf8))
    }

    // MARK: - The panel that is registered but cannot answer

    /// A terminal this app has not resolved to a plain shell is refused, and
    /// the refusal is decided by the coordinator's own `panelKind()` reading
    /// `AppState` at request time — not by a kind snapshotted at registration.
    /// Failing closed is the point: the cost of being wrong is keystrokes in
    /// somebody's agent session.
    @Test("an agent panel is refused as notshell, and the same panel answers once it is a shell")
    func agentPanelIsRefusedAsNotShell() async throws {
        let panel = try await makePanel(kind: .claude)
        defer { panel.tearDown() }

        panel.diagnostic.handleRequest(request(terminalID: panel.terminalID, seq: 7))
        #expect(panel.lines.all == [panel.refusal("notshell")])
        #expect(readAvailable(from: panel.sessionEnd).isEmpty)

        panel.setKind(.shell)
        panel.diagnostic.handleRequest(request(terminalID: panel.terminalID, seq: 8))
        #expect(panel.lines.all == [panel.refusal("notshell")])
        #expect(readAvailable(from: panel.sessionEnd) == Data("lp8z\r".utf8))
    }

    /// A snapshot preamble is replayed history being fed into a muted window:
    /// `send(source:data:)` drops what it is handed for the whole ingest, so a
    /// token written there is eaten and its silence would be logged as a token
    /// the transport lost.
    ///
    /// Driven through the production path — `feedSnapshot` raises the flag and
    /// lowers it one main-queue turn later, never on return — so the control is
    /// the far side of that turn rather than a flag the test put back itself.
    @Test("a probe during a snapshot ingest is refused, and lands once the ingest is over")
    func probeDuringSnapshotIngestIsRefused() async throws {
        let panel = try await makePanel()
        defer { panel.tearDown() }

        panel.coordinator.feedSnapshot(Data("preamble".utf8), into: panel.view)
        #expect(panel.coordinator.isIngestingSnapshot)

        panel.diagnostic.handleRequest(request(terminalID: panel.terminalID, seq: 9))
        #expect(panel.lines.all == [panel.refusal("ingestingsnapshot")])
        #expect(readAvailable(from: panel.sessionEnd).isEmpty)

        await mainQueueTurn()
        #expect(!panel.coordinator.isIngestingSnapshot)
        panel.diagnostic.handleRequest(request(terminalID: panel.terminalID, seq: 10))
        #expect(panel.lines.all == [panel.refusal("ingestingsnapshot")])
        #expect(readAvailable(from: panel.sessionEnd) == Data("lp10z\r".utf8))
    }

    /// While the handback's mode probe is in flight the panel COLLECTS replies
    /// instead of routing them, and a token written into that window is folded
    /// into `RecordedModeReplies` — handed to the daemon as though the terminal
    /// had said it. Refused, not measured.
    @Test("a probe during a handback's mode probe is refused, and lands once it is over")
    func probeDuringHandbackIsRefused() async throws {
        let panel = try await makePanel()
        defer { panel.tearDown() }

        panel.coordinator.isCollectingModeRepliesForTesting = true
        panel.diagnostic.handleRequest(request(terminalID: panel.terminalID, seq: 13))
        #expect(panel.lines.all == [panel.refusal("handbackinflight")])
        #expect(readAvailable(from: panel.sessionEnd).isEmpty)

        panel.coordinator.isCollectingModeRepliesForTesting = false
        panel.diagnostic.handleRequest(request(terminalID: panel.terminalID, seq: 14))
        #expect(panel.lines.all == [panel.refusal("handbackinflight")])
        #expect(readAvailable(from: panel.sessionEnd) == Data("lp14z\r".utf8))
    }

    /// The registration's own positive control: an attach that completes keeps
    /// its claim, so "0" above is a withdrawal rather than a tap that was never
    /// installed.
    @Test("a completed attach keeps its latency registration")
    func completedAttachKeepsTheRegistration() async throws {
        let panel = try await makePanel()
        defer { panel.tearDown() }

        #expect(panel.diagnostic.registrationCount == 1)
    }

    /// The same failure seen from the probe's side, for the window before the
    /// withdrawal lands: a panel whose holder was cleared still owns its
    /// NSView, so `terminalView != nil` is not enough to say bytes can flow.
    @Test("a panel whose holder has been cleared refuses with noview")
    func clearedHolderIsRefusedAsNoView() async throws {
        let panel = try await makePanel()
        defer { panel.tearDown() }

        panel.coordinator.viewHolderForTesting.clear()
        panel.diagnostic.handleRequest(request(terminalID: panel.terminalID, seq: 4))

        #expect(
            panel.lines.all
                == ["echorefused terminal=\(panel.terminalID.uuidString) reason=noview"])
        #expect(readAvailable(from: panel.sessionEnd).isEmpty)
    }
}
