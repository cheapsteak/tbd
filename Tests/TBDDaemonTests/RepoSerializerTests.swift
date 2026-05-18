import Testing
import Foundation
@testable import TBDDaemonLib

@Suite("RepoSerializer")
struct RepoSerializerTests {

    /// Records start/end timestamps for each tagged piece of work so tests can
    /// assert ordering and overlap properties.
    actor TimelineRecorder {
        struct Span { let tag: String; let start: Date; let end: Date }
        private(set) var spans: [Span] = []

        func record(tag: String, work: () async -> Void) async {
            let start = Date()
            await work()
            let end = Date()
            spans.append(Span(tag: tag, start: start, end: end))
        }

        func allSpans() -> [Span] { spans }
    }

    @Test("same repoID serializes consecutively, never overlapping")
    func sameRepoSerializes() async throws {
        let serializer = RepoSerializer()
        let recorder = TimelineRecorder()
        let repoID = UUID()
        let sleep: UInt64 = 150_000_000 // 150ms

        // Submit two pieces of work back-to-back for the same repo. They must
        // run in submission order with zero overlap.
        let t1 = await serializer.submit(repoID: repoID) {
            await recorder.record(tag: "A") {
                try? await Task.sleep(nanoseconds: sleep)
            }
        }
        let t2 = await serializer.submit(repoID: repoID) {
            await recorder.record(tag: "B") {
                try? await Task.sleep(nanoseconds: sleep)
            }
        }
        await t1.value
        await t2.value

        let spans = await recorder.allSpans()
        #expect(spans.count == 2)
        #expect(spans[0].tag == "A")
        #expect(spans[1].tag == "B")
        // B must start strictly after A ends.
        #expect(spans[1].start >= spans[0].end)
    }

    @Test("different repoIDs run in parallel")
    func differentReposOverlap() async throws {
        let serializer = RepoSerializer()
        let recorder = TimelineRecorder()
        let repoA = UUID()
        let repoB = UUID()
        let sleep: UInt64 = 200_000_000 // 200ms

        let t1 = await serializer.submit(repoID: repoA) {
            await recorder.record(tag: "A") {
                try? await Task.sleep(nanoseconds: sleep)
            }
        }
        let t2 = await serializer.submit(repoID: repoB) {
            await recorder.record(tag: "B") {
                try? await Task.sleep(nanoseconds: sleep)
            }
        }
        await t1.value
        await t2.value

        let spans = await recorder.allSpans()
        #expect(spans.count == 2)
        let aSpan = try #require(spans.first { $0.tag == "A" })
        let bSpan = try #require(spans.first { $0.tag == "B" })
        // Overlap proof: each one started before the other finished.
        #expect(aSpan.start < bSpan.end)
        #expect(bSpan.start < aSpan.end)
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

        // The second submit must not block on the in-flight first.
        let t0 = Date()
        let queued = await serializer.submit(repoID: repoID) {
            sentinel.set(true)
        }
        #expect(Date().timeIntervalSince(t0) < 0.05)
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
