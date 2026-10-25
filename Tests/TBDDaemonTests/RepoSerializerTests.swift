import Testing
import Foundation
@testable import TBDDaemonLib
import TestSupport

/// Every ordering and overlap claim here is made with gates the test holds,
/// never with wall-clock timestamps around sleeps: a body parks until the test
/// or the other body releases it, so what the assertions see does not depend
/// on how promptly a loaded runner schedules each task. `.fastPassBounded`
/// bounds the one shape that regresses as a hang, a submit that waits on its
/// predecessor.
@Suite("RepoSerializer", .fastPassBounded)
struct RepoSerializerTests {

    @Test("same repoID serializes consecutively, never overlapping")
    func sameRepoSerializes() async throws {
        let serializer = RepoSerializer()
        let repoID = UUID()
        let log = EventLog()
        let aStarted = AsyncSignal()
        let aMayFinish = AsyncSignal()

        // Submit two pieces of work back-to-back for the same repo. A parks
        // mid-work on a gate the test holds, so "B never overlaps A" does not
        // depend on how long A happens to take.
        let t1 = await serializer.submit(repoID: repoID) {
            log.append("A start")
            await aStarted.signal()
            await aMayFinish.wait()
            log.append("A end")
        }
        let t2 = await serializer.submit(repoID: repoID) {
            log.append("B start")
            log.append("B end")
        }
        await aStarted.wait()

        // Negative-assertion window: B must not start while A is parked. The
        // window is the assertion, and a correct serializer cannot start B
        // inside it however long it runs, so it never reddens a slow run.
        let bStartedEarly = await pollUntilTrue(timeout: .milliseconds(100)) {
            log.entries.contains("B start")
        }
        #expect(bStartedEarly != .satisfied, "B started while A was still in flight")

        await aMayFinish.signal()
        await t1.value
        await t2.value

        // B runs in submission order, strictly after A ends.
        #expect(log.entries == ["A start", "A end", "B start", "B end"])
    }

    @Test("different repoIDs run in parallel")
    func differentReposOverlap() async throws {
        let serializer = RepoSerializer()
        let repoA = UUID()
        let repoB = UUID()
        let aRunning = SendableBox(false)
        let bRunning = SendableBox(false)
        let aSawB = SendableBox(false)
        let bSawA = SendableBox(false)

        // Each body starts, then finishes only once it has seen the other one
        // running. Both waits succeed only if the two bodies are in flight at
        // the same time; serialized, the first body's wait would expire.
        let t1 = await serializer.submit(repoID: repoA) {
            aRunning.set(true)
            let outcome = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { bRunning.get() }
            aSawB.set(outcome == .satisfied)
        }
        let t2 = await serializer.submit(repoID: repoB) {
            bRunning.set(true)
            let outcome = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { aRunning.get() }
            bSawA.set(outcome == .satisfied)
        }
        await t1.value
        await t2.value

        // Overlap proof: each one started before the other finished.
        #expect(aSawB.get(), "B never started while A was running")
        #expect(bSawA.get(), "A never started while B was running")
    }

    @Test("lane entries are pruned after work completes")
    func lanesArePrunedAfterCompletion() async throws {
        let serializer = RepoSerializer()
        let repoA = UUID()
        let repoB = UUID()

        let t1 = await serializer.submit(repoID: repoA) { }
        let t2 = await serializer.submit(repoID: repoB) { }
        await t1.value
        await t2.value

        // Cleanup tasks chain off the work tasks, so they need their own turn
        // on the actor after the work completes.
        _ = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            await serializer.trackedRepoCount == 0
        }
        let finalCount = await serializer.trackedRepoCount
        #expect(finalCount == 0)
    }

    @Test("submit returns immediately even if predecessor is long-running")
    func submitReturnsBeforeWorkFinishes() async throws {
        let serializer = RepoSerializer()
        let repoID = UUID()
        let firstStarted = AsyncSignal()
        let firstMayFinish = AsyncSignal()
        let sentinel = SendableBox(false)

        let slow = await serializer.submit(repoID: repoID) {
            await firstStarted.signal()
            await firstMayFinish.wait()
        }
        await firstStarted.wait()

        // The second submit must not block on the in-flight first. Returning
        // here while the first is still gated is the proof: a submit that
        // waited on its predecessor would never come back.
        let queued = await serializer.submit(repoID: repoID) {
            sentinel.set(true)
        }
        #expect(sentinel.get() == false)

        await firstMayFinish.signal()
        await slow.value
        await queued.value
        #expect(sentinel.get() == true)
    }
}

// MARK: - Local test utilities

/// One-shot async semaphore (set-once, multi-await).
private actor AsyncSignal {
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        guard !fired else { return }
        fired = true
        for w in waiters { w.resume() }
        waiters.removeAll()
    }

    func wait() async {
        if fired { return }
        await withCheckedContinuation { cont in waiters.append(cont) }
    }
}

private final class SendableBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
}

/// Append-only record of what the bodies did, in the order they did it.
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    func append(_ entry: String) { lock.lock(); recorded.append(entry); lock.unlock() }
    var entries: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
}
