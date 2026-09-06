import Foundation
import Testing
@testable import TBDDaemonLib

/// The lane that keeps a completions probe from overlapping a trust seed on the
/// same Claude config directory. Both do a read-merge-write of `.claude.json`,
/// and the probe suspends, so an actor alone cannot order them.
///
/// Tier 1: no filesystem, no process — pure ordering.
@Suite("ClaudeConfigDirSerializer")
struct ClaudeConfigDirSerializerTests {

    private actor Trace {
        private(set) var marks: [String] = []
        func mark(_ value: String) { marks.append(value) }
    }

    @Test func twoBodiesOnOneDirectoryNeverOverlap() async throws {
        let serializer = ClaudeConfigDirSerializer()
        let trace = Trace()
        // The first body signals as it enters its lane, and the second is not
        // queued until that signal lands. A fixed sleep here would be a guess:
        // too short on a loaded machine and the second body is queued first, so
        // the test would assert nothing and still pass.
        let (firstEntered, firstDidEnter) = AsyncStream<Void>.makeStream()

        async let first: Void = serializer.run(configDir: "/cfg") {
            await trace.mark("a-start")
            firstDidEnter.yield()
            try? await Task.sleep(for: .milliseconds(40))
            await trace.mark("a-end")
        }
        var firstEntries = firstEntered.makeAsyncIterator()
        _ = await firstEntries.next()
        async let second: Void = serializer.run(configDir: "/cfg") {
            await trace.mark("b-start")
            await trace.mark("b-end")
        }
        _ = try await (first, second)

        #expect(await trace.marks == ["a-start", "a-end", "b-start", "b-end"])
    }

    /// Two different profiles are two different files. Serializing them together
    /// would make every probe wait behind an unrelated worktree's trust seed.
    @Test func twoDirectoriesRunConcurrently() async throws {
        let serializer = ClaudeConfigDirSerializer()
        let trace = Trace()
        // Same entry signal as above, for the same reason.
        let (firstEntered, firstDidEnter) = AsyncStream<Void>.makeStream()
        // The first body does not finish until the second has run, so the
        // interleaving is established by a signal rather than by a sleep the
        // second body is assumed to beat. A fixed sleep asserts nothing about
        // the serializer: on a loaded machine the second task simply is not
        // scheduled inside the window, the marks come out in lane order, and
        // the test fails without a bug — which is exactly what it did.
        //
        // `didRun` carries a Bool so a real regression FAILS rather than hangs:
        // if an unrelated directory did queue behind this one the second body
        // can never run, and only the watchdog's `false` releases the first.
        // The wait is off the critical path — it costs nothing when the lanes
        // are independent, and 30 s once when they are not.
        let (secondRan, secondDidRun) = AsyncStream<Bool>.makeStream()

        async let first: Void = serializer.run(configDir: "/one") {
            await trace.mark("a-start")
            firstDidEnter.yield()
            let watchdog = Task {
                try? await Task.sleep(for: .seconds(30))
                secondDidRun.yield(false)
            }
            var runs = secondRan.makeAsyncIterator()
            let ranConcurrently = await runs.next() ?? false
            watchdog.cancel()
            if !ranConcurrently { await trace.mark("a-gave-up-waiting") }
            await trace.mark("a-end")
        }
        var firstEntries = firstEntered.makeAsyncIterator()
        _ = await firstEntries.next()
        async let second: Void = serializer.run(configDir: "/two") {
            await trace.mark("b-start")
            await trace.mark("b-end")
            secondDidRun.yield(true)
        }
        _ = try await (first, second)

        let marks = await trace.marks
        #expect(!marks.contains("a-gave-up-waiting"),
                "an unrelated directory must not queue behind this one: \(marks)")
        #expect(marks.firstIndex(of: "b-end")! < marks.firstIndex(of: "a-end")!,
                "an unrelated directory must not queue behind this one: \(marks)")
    }

    /// A body that throws releases its lane. The successor must run, not inherit
    /// the failure.
    @Test func aThrowingBodyStillReleasesTheLane() async throws {
        struct Boom: Error {}
        let serializer = ClaudeConfigDirSerializer()

        await #expect(throws: Boom.self) {
            try await serializer.run(configDir: "/cfg") { throw Boom() }
        }
        let value = try await serializer.run(configDir: "/cfg") { 42 }
        #expect(value == 42)
    }

    /// The lane table must not grow one entry per directory ever used.
    @Test func lanesArePrunedWhenIdle() async throws {
        let serializer = ClaudeConfigDirSerializer()
        _ = try await serializer.run(configDir: "/cfg") { 1 }
        // The prune runs in its own task after the tail finishes; poll for it
        // rather than assuming a single yield is enough.
        for _ in 0..<50 where await serializer.trackedDirectoryCount != 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await serializer.trackedDirectoryCount == 0)
    }
}
