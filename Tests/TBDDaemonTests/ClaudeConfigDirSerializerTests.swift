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

        async let first: Void = serializer.run(configDir: "/cfg") {
            await trace.mark("a-start")
            try? await Task.sleep(for: .milliseconds(40))
            await trace.mark("a-end")
        }
        // Give the first body a turn to enter its lane before queueing the
        // second, so this asserts ordering rather than racing to observe it.
        try await Task.sleep(for: .milliseconds(5))
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

        async let first: Void = serializer.run(configDir: "/one") {
            await trace.mark("a-start")
            try? await Task.sleep(for: .milliseconds(40))
            await trace.mark("a-end")
        }
        try await Task.sleep(for: .milliseconds(5))
        async let second: Void = serializer.run(configDir: "/two") {
            await trace.mark("b-start")
            await trace.mark("b-end")
        }
        _ = try await (first, second)

        let marks = await trace.marks
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
