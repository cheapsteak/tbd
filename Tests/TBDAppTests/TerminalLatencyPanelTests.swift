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
    /// daemon gives a descriptor it has not accounted for.
    private struct StubAttach: HolderAttaching {
        let attachment: HolderAttachment
        var readyError: (any Error)?

        func attach(
            worktreeID: UUID, paneID: String, terminalID: UUID
        ) async throws -> HolderAttachment { attachment }

        func ready(
            worktreeID: UUID, paneID: String, terminalID: UUID, generation: UInt64
        ) async throws {
            if let readyError { throw readyError }
        }

        func detach(
            worktreeID: UUID, paneID: String, terminalID: UUID, generation: UInt64,
            snapshotPreamble: Data
        ) async throws {}
    }

    private struct ReadyRefused: Error {}

    @MainActor
    private struct Panel {
        /// Held for the panel's lifetime: `Coordinator.appState` is weak, and
        /// a released one makes `panelKind()` answer nil — which the diagnostic
        /// correctly refuses as `notshell`, for the wrong reason entirely.
        let state: AppState
        let coordinator: TerminalPanelRepresentable.Coordinator
        let diagnostic: TerminalLatencyDiagnostic
        let lines: Lines
        let terminalID: UUID
        let sessionEnd: Int32
        let view: TBDTerminalView
        let defaults: UserDefaults
        let suiteName: String

        func tearDown() {
            coordinator.cleanup()
            Darwin.close(sessionEnd)
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    /// A holder-backed panel wired as production wires one, with the latency
    /// diagnostic on. `vending` replaces the pty with a descriptor whose writes
    /// always fail; `readyError` makes the daemon refuse the attach ack.
    @MainActor
    private func makePanel(
        vending: Int32? = nil, readyError: (any Error)? = nil
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
            kind: .shell,
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
            readyError: readyError)

        await coordinator.startHolderClient(terminalView: view)

        return Panel(
            state: state, coordinator: coordinator, diagnostic: diagnostic, lines: lines,
            terminalID: terminalID, sessionEnd: sessionEnd, view: view,
            defaults: defaults, suiteName: suiteName)
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

    /// The tap is installed before the attach is acknowledged, so every path
    /// that gives up after that point has to withdraw it. A claim left behind
    /// answers a later request by writing into a session this panel does not
    /// have.
    @Test("an attach refused at ready withdraws the panel's latency registration")
    func refusedReadyWithdrawsTheRegistration() async throws {
        let panel = try await makePanel(readyError: ReadyRefused())
        defer { panel.tearDown() }

        #expect(panel.diagnostic.registrationCount == 0)

        panel.diagnostic.handleRequest(request(terminalID: panel.terminalID, seq: 3))
        #expect(
            panel.lines.all
                == ["echorefused terminal=\(panel.terminalID.uuidString) reason=unknownterminal"])
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
