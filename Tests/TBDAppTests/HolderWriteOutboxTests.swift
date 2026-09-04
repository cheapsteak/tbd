import AppKit
import Darwin
import Foundation
import SwiftTerm
import TBDShared
import Testing

@testable import TBDApp
import TestSupport

/// The panel's write step end to end, against a **real pty** whose slave is in
/// raw mode and unread — the fixture that makes the 1,022-byte refusal
/// deterministic.
///
/// A socket pair, which the sibling `HolderInjectionDelivery` suite uses, has
/// no `TTYHOG`, no line discipline and no `ptcwrite`, so it can never produce
/// the short write this whole subsystem exists for. Everything here needs the
/// real refusal.
@Suite("HolderWriteOutbox")
struct HolderWriteOutboxTests {

    // MARK: - The payload arrives whole

    @MainActor
    @Test("a paste larger than the pty's queue is delivered whole, markers and all")
    func largePasteIsDeliveredWhole() async throws {
        let panel = try await makeHolderPanel()
        defer { panel.tearDown() }
        let start = Data(EscapeSequences.bracketedPasteStart)
        let body = Data(repeating: 0x61, count: 8 * 1024)
        let end = Data(EscapeSequences.bracketedPasteEnd)

        // The production path: four chunks through `Coordinator.send`, in one
        // main-actor turn, exactly as SwiftTerm's paste emits the first three.
        panel.coordinator.send(source: panel.view, data: [UInt8](start)[...])
        panel.coordinator.send(source: panel.view, data: [UInt8](body)[...])
        panel.coordinator.send(source: panel.view, data: [UInt8](end)[...])
        panel.coordinator.send(source: panel.view, data: [UInt8]("Z".utf8)[...])

        var expected = Data()
        expected.append(start)
        expected.append(body)
        expected.append(end)
        expected.append(Data("Z".utf8))
        let delivered = try await panel.pty.drainUntil(byteCount: expected.count)

        #expect(delivered == expected, """
            every byte exactly once and in order: a truncated payload, a lost \
            end marker or a keystroke ahead of the marker all fail here
            """)
    }

    @MainActor
    @Test("a keystroke typed during a stall is held, not dropped, and lands in order")
    func keystrokeDuringAStallIsHeld() async throws {
        let panel = try await makeHolderPanel()
        defer { panel.tearDown() }
        // Learn this kernel's ceiling rather than hard-coding 1,022, then put
        // the queue back into the full state: the very first byte of what is
        // typed next is refused, which is a stall rather than a partial.
        panel.pty.fillPTY()
        let ceiling = panel.pty.drainAll()
        #expect(ceiling > 0, "the fixture must have actually filled the queue")
        let refilled = panel.pty.fillPTY()

        panel.coordinator.send(source: panel.view, data: [UInt8]("first".utf8)[...])
        panel.coordinator.send(source: panel.view, data: [UInt8]("second".utf8)[...])

        #expect(panel.coordinator.outgoingQueueForTesting.pendingByteCountForTesting == 11,
                "both keystrokes are held; a dropped one is the regression this replaces")

        let delivered = try await panel.pty.drainUntil(byteCount: refilled + 11)

        #expect(delivered.suffix(11) == Data("firstsecond".utf8),
                "held keystrokes are written in the order they were typed")
    }

    // MARK: - The interim ack, all four rows

    @MainActor
    @Test("a partial injection is acked accepted, not failed")
    func partialInjectionIsAckedAccepted() async throws {
        let panel = try await makeHolderPanel()
        defer { panel.tearDown() }
        let handler = try #require(
            panel.state.terminalInjections.registeredHandlerForTesting(
                terminalID: panel.terminalID))

        // 4 KiB into an empty raw-mode queue: a kilobyte goes, the rest is
        // refused and becomes the panel's to finish.
        let acked = await handler(panel.terminalID, Data(repeating: 0x62, count: 4_096))

        #expect(panel.coordinator.outgoingQueueForTesting.pendingByteCountForTesting > 0,
                "the fixture must actually produce a remainder, or this row is vacuous")
        #expect(acked == true, """
            `true` means accepted by a writer that will complete — the daemon \
            must NOT fall back and write the payload a second time on top of a \
            prefix this panel is still finishing
            """)
    }

    @MainActor
    @Test("an injection into a queue that takes nothing at all is still acked accepted")
    func fullQueueInjectionIsAckedAccepted() async throws {
        let panel = try await makeHolderPanel()
        defer { panel.tearDown() }
        panel.pty.fillPTY()
        let handler = try #require(
            panel.state.terminalInjections.registeredHandlerForTesting(
                terminalID: panel.terminalID))

        #expect(await handler(panel.terminalID, Data("hi\r".utf8)) == true,
                "zero bytes taken by a live pty is a refusal to hold, not a failure")
    }

    /// The matrix's negative control, and it is honest about being one: this
    /// row passed before the outbox too, because an unwritable descriptor was
    /// already the one thing reported unwritten. It is here so the three rows
    /// above cannot be satisfied by a seam that simply answers `true` always.
    @MainActor
    @Test("an injection into a dead descriptor is acked unwritten")
    func injectionIntoADeadDescriptorIsAckedUnwritten() async throws {
        // A live, read-only descriptor, never a number this test just closed:
        // suites run in parallel in one process and a closed number can be
        // reissued to a stranger's file before the write below runs. It is not
        // closed here either — the panel's reader owns it and closes it on the
        // way out, exactly as it owns the vended pty in the other rows.
        let readOnly = Darwin.open("/dev/null", O_RDONLY)
        try #require(readOnly >= 0)
        let panel = try await makeHolderPanel(vending: readOnly)
        defer { panel.tearDown() }
        let handler = try #require(
            panel.state.terminalInjections.registeredHandlerForTesting(
                terminalID: panel.terminalID))

        #expect(await handler(panel.terminalID, Data("hi\r".utf8)) == false,
                "nothing will land through this descriptor, and the daemon must fall back")
    }

    @MainActor
    @Test("a prefix followed by EIO is acked unwritten and drops what was held")
    func prefixThenEIOIsAckedUnwritten() async throws {
        let panel = try await makeHolderPanel()
        defer { panel.tearDown() }
        let queue = panel.coordinator.outgoingQueueForTesting
        let handler = try #require(
            panel.state.terminalInjections.registeredHandlerForTesting(
                terminalID: panel.terminalID))
        // A prefix goes, a remainder is held.
        #expect(await handler(panel.terminalID, Data(repeating: 0x62, count: 4_096)) == true)
        #expect(queue.pendingByteCountForTesting > 0)

        // The last slave closes: every further write to the master is EIO,
        // which is the child having exited.
        panel.pty.closeSessionEnd()
        queue.drain()

        #expect(queue.pendingByteCountForTesting == 0)
        #expect(queue.outboxDropLogsForTesting == 1)
        #expect(await handler(panel.terminalID, Data("hi\r".utf8)) == false, """
            once the child is gone, the honest answer to "was it written" is no \
            — even though a prefix did reach the pty
            """)
    }

    // MARK: - The fixture

    /// The panel wired the way production wires one, attached to a real pty
    /// master. `startHolderClient` is the production attach path, so the drain
    /// notifier under test is the one it builds — nothing here injects a fake.
    @MainActor
    private func makeHolderPanel(vending: Int32? = nil) async throws -> HolderPanel {
        let pty = try RawPTYPair()
        let vended = vending ?? Darwin.dup(pty.ptyFD)
        try #require(vended >= 0)
        // The real vend is a `dup` of a pty the daemon opened `O_NONBLOCK`, and
        // the flag rides the dup; a blocking descriptor here would park the
        // main actor rather than refuse.
        _ = fcntl(vended, F_SETFL, fcntl(vended, F_GETFL, 0) | O_NONBLOCK)

        let worktreeID = UUID()
        let terminalID = UUID()
        let state = AppState()
        // A holder row carries empty tmux coordinates by construction.
        state.terminals[worktreeID] = [Terminal(
            id: terminalID,
            worktreeID: worktreeID,
            tmuxWindowID: "",
            tmuxPaneID: "",
            label: "Shell",
            kind: .shell,
            transport: .holder
        )]

        // Isolated defaults: `AppearanceSettings` must never read or write the
        // developer's real TBDApp.plist.
        let suiteName = "TBDAppTests.HolderWriteOutbox.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let view = TBDTerminalView(
            frame: CGRect(x: 0, y: 0, width: 600, height: 300),
            font: TBDTerminalView.defaultMonospaceFont,
            appearance: AppearanceSettings(defaults: defaults))

        let coordinator = TerminalPanelRepresentable.Coordinator()
        coordinator.appState = state
        coordinator.panelID = terminalID
        coordinator.holderAttachClient = StubAttach(
            attachment: HolderAttachment(
                ptyFD: vended, generation: 7, snapshotPreamble: Data()))

        await coordinator.startHolderClient(terminalView: view)

        return HolderPanel(
            state: state, coordinator: coordinator, view: view, terminalID: terminalID,
            pty: pty, defaults: defaults, suiteName: suiteName)
    }

    /// Stands in for the daemon's two attach RPCs, handing over a descriptor
    /// the test can read. A copy of `HolderInjectionDeliveryTests`'s stub
    /// rather than a shared one: it is nine lines, and making it internal to
    /// share it couples two suites for nothing.
    private struct StubAttach: HolderAttaching {
        let attachment: HolderAttachment

        func attach(
            worktreeID: UUID, paneID: String, terminalID: UUID
        ) async throws -> HolderAttachment { attachment }

        func ready(
            worktreeID: UUID, paneID: String, terminalID: UUID, generation: UInt64
        ) async throws {}

        func detach(
            worktreeID: UUID, paneID: String, terminalID: UUID, generation: UInt64,
            snapshotPreamble: Data
        ) async throws {}
    }

    @MainActor
    private struct HolderPanel {
        let state: AppState
        let coordinator: TerminalPanelRepresentable.Coordinator
        let view: TBDTerminalView
        let terminalID: UUID
        /// The session's side. The reader closes the descriptor it was handed;
        /// this fixture owns the rest, and `close()` is idempotent over a
        /// session end a test closed early.
        let pty: RawPTYPair
        let defaults: UserDefaults
        let suiteName: String

        func tearDown() {
            coordinator.cleanup()
            pty.close()
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}
