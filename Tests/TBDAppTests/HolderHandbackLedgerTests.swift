import Foundation
import Testing

@testable import TBDApp

/// The ledger a successor holder panel waits on before attaching: the
/// predecessor's handback task, keyed by terminal ID.
///
/// Every wait here is suspension-based — a continuation the test resumes —
/// so no thread blocks and no timing is involved. A wait that "could not have
/// finished yet" is asserted as an ordering the code cannot violate, not as
/// a race the test happens to win.
@Suite("Holder handback ledger")
struct HolderHandbackLedgerTests {

    /// A task the test holds open until it says otherwise.
    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false

        func wait() async {
            if opened { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            opened = true
            continuation?.resume()
            continuation = nil
        }
    }

    @MainActor
    @Test("awaitSettled returns immediately when nothing is registered")
    func returnsImmediatelyWhenIdle() async {
        let ledger = HolderHandbackLedger()
        let id = UUID()

        let waited = await ledger.awaitSettled(terminalID: id)

        #expect(!waited)
        #expect(!ledger.isInFlight(terminalID: id))
    }

    /// Main-actor flag a waiter raises when it returns, so a test can assert
    /// the waiter is still parked without racing it.
    @MainActor
    private final class Returned {
        var raised = false
    }

    @MainActor
    @Test("awaitSettled waits until the registered task finishes")
    func waitsForRegisteredTask() async {
        let ledger = HolderHandbackLedger()
        let id = UUID()
        let gate = Gate()
        ledger.register(terminalID: id, task: Task { await gate.wait() })

        let returned = Returned()
        let waiter = Task { @MainActor in
            let waited = await ledger.awaitSettled(terminalID: id)
            returned.raised = true
            return waited
        }
        for _ in 0..<20 { await Task.yield() }
        // The waiter cannot have returned: the task it awaits is parked on a
        // gate nobody has opened.
        #expect(!returned.raised, "the waiter returned before the handback finished")
        #expect(ledger.isInFlight(terminalID: id))

        await gate.open()
        let waited = await waiter.value

        #expect(returned.raised)
        #expect(waited, "a wait on an in-flight handback must report that it waited")
        #expect(!ledger.isInFlight(terminalID: id))
    }

    @MainActor
    @Test("a finished task removes its own entry")
    func finishedTaskRemovesItsEntry() async {
        let ledger = HolderHandbackLedger()
        let id = UUID()
        let gate = Gate()
        let task = Task { await gate.wait() }
        ledger.register(terminalID: id, task: task)
        #expect(ledger.isInFlight(terminalID: id))

        await gate.open()
        await task.value
        // The removal is one main-actor hop behind the task's completion.
        // Yield until it has run, bounded so a missing removal fails rather
        // than spins; each yield is a real main-actor turn.
        for _ in 0..<50 where ledger.isInFlight(terminalID: id) { await Task.yield() }

        #expect(!ledger.isInFlight(terminalID: id),
                "a finished handback must not stay on the ledger")
        // And a waiter arriving afterwards has nothing to wait on.
        #expect(await ledger.awaitSettled(terminalID: id) == false)
    }

    @MainActor
    @Test("an older task finishing does not remove a newer registration for the same terminal")
    func olderTaskDoesNotRemoveNewerRegistration() async {
        let ledger = HolderHandbackLedger()
        let id = UUID()
        let firstGate = Gate()
        let secondGate = Gate()
        let first = Task { await firstGate.wait() }
        let second = Task { await secondGate.wait() }
        ledger.register(terminalID: id, task: first)
        ledger.register(terminalID: id, task: second)

        await firstGate.open()
        await first.value
        // Let the first task's removal hop run: it must see the newer entry
        // and leave it alone.
        for _ in 0..<20 { await Task.yield() }
        #expect(ledger.isInFlight(terminalID: id),
                "the newer handback is still in flight and must stay registered")

        await secondGate.open()
        let waited = await ledger.awaitSettled(terminalID: id)

        #expect(waited)
        #expect(!ledger.isInFlight(terminalID: id))
    }

    @MainActor
    @Test("awaitSettled covers a task registered while it was already waiting")
    func coversTaskRegisteredMidWait() async {
        let ledger = HolderHandbackLedger()
        let id = UUID()
        let firstGate = Gate()
        let secondGate = Gate()
        ledger.register(terminalID: id, task: Task { await firstGate.wait() })

        let waiter = Task { @MainActor in await ledger.awaitSettled(terminalID: id) }
        for _ in 0..<20 { await Task.yield() }
        // A second handback lands while the waiter is parked on the first.
        ledger.register(terminalID: id, task: Task { await secondGate.wait() })

        await firstGate.open()
        for _ in 0..<20 { await Task.yield() }
        // The first task is done, but the waiter must not have returned: the
        // second is still in flight and the loop has to pick it up.
        #expect(ledger.isInFlight(terminalID: id))

        await secondGate.open()
        let waited = await waiter.value

        #expect(waited)
        #expect(!ledger.isInFlight(terminalID: id))
    }

    @MainActor
    @Test("terminals are independent: a handback on one does not hold up another")
    func terminalsAreIndependent() async {
        let ledger = HolderHandbackLedger()
        let busy = UUID()
        let idle = UUID()
        let gate = Gate()
        ledger.register(terminalID: busy, task: Task { await gate.wait() })

        let waited = await ledger.awaitSettled(terminalID: idle)

        #expect(!waited)
        #expect(ledger.isInFlight(terminalID: busy))
        await gate.open()
        await ledger.awaitSettled(terminalID: busy)
        #expect(!ledger.isInFlight(terminalID: busy))
    }
}
