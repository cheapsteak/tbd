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

    // MARK: - The other two writers of `.claude.json`

    /// `ensureAPIKeyDir` is a read-merge-write of the same file the probe
    /// rewrites, so it must wait for the lane rather than write through it.
    ///
    /// Discriminating: with the `ensure*` write outside the lane it lands while
    /// the lane is held and `wroteWhileHeld` is true; inside the lane it cannot
    /// start until the holder returns. The holder signals as it enters and then
    /// waits for the ensure call to have been *issued*, so the ordering under
    /// test is established rather than raced.
    @Test func ensureAPIKeyDirWaitsForTheLaneOnItsConfigDir() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-lane-ensure-\(UUID().uuidString)", isDirectory: true)
        let profileID = UUID()
        let manager = ClaudeProfileConfigDirManager(
            baseDirectory: dir, hostBaseDirectory: dir.appendingPathComponent("host"))
        let configDir = manager.configDirectory(forProfileID: profileID)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let claudeJSON = configDir.appendingPathComponent(".claude.json")
        let (holderEntered, holderDidEnter) = AsyncStream<Void>.makeStream()
        let (ensureIssued, ensureWasIssued) = AsyncStream<Void>.makeStream()

        // `ensure*Dir` reaches the shared lane, so the holder must too.
        async let holder: Void = ClaudeConfigDirSerializer.shared.run(
            configDir: configDir.path
        ) {
            holderDidEnter.yield()
            var issued = ensureIssued.makeAsyncIterator()
            _ = await issued.next()
            // Give a lane-ignoring writer every chance to land before we look.
            try? await Task.sleep(for: .milliseconds(50))
        }
        var entries = holderEntered.makeAsyncIterator()
        _ = await entries.next()

        async let ensure: Void = {
            _ = try? await manager.ensureAPIKeyDir(
                forProfileID: profileID, apiKey: "sk-ant-test-key-0123456789")
        }()
        ensureWasIssued.yield()

        // Sampled while the lane is still held by `holder`.
        try? await Task.sleep(for: .milliseconds(20))
        let wroteWhileHeld = FileManager.default.fileExists(atPath: claudeJSON.path)

        _ = try await holder
        await ensure

        #expect(!wroteWhileHeld,
                "ensureAPIKeyDir wrote .claude.json while another writer held the lane")
        #expect(FileManager.default.fileExists(atPath: claudeJSON.path),
                "the write must still happen once the lane is released")
    }

    /// The interaction the two writers exist to protect: a trust entry written
    /// into `.claude.json` survives an `ensureAPIKeyDir` running against the same
    /// directory. Unserialized, the ensure's read-merge-write is built from a
    /// snapshot taken before the trust write and writes the trust key back out of
    /// existence.
    ///
    /// **The trust write must land BETWEEN the ensure's read and the ensure's
    /// write, or the test proves nothing.** Seeding it up front — what this test
    /// used to do — leaves an ordering no lane is needed for: every ensure then
    /// reads a file that already carries the entry, and the test passes with the
    /// lane deleted. The merge is straight-line synchronous code inside the lane
    /// body, so that window cannot be straddled from outside; `afterReadForTesting`
    /// is the minimal seam that opens it, and it is the ONLY thing here that is
    /// test-only.
    ///
    /// The rest is the same handshake as `ensureAPIKeyDirWaitsForTheLaneOnItsConfigDir`
    /// above. A holder takes the lane and plays the trust seeder's part: it waits
    /// until the ensure has been issued, gives a lane-ignoring ensure 50 ms to
    /// reach its read and park in the seam, writes the trust entry, and releases.
    /// With the lane, the ensure has not read yet and reads the trust-bearing
    /// file; without it, the ensure read a file that had none and rewrites it away.
    ///
    /// Discriminating: verified by bypassing the lane in `ensureAPIKeyDir` (call
    /// the body directly instead of through `ClaudeConfigDirSerializer.shared.run`),
    /// which makes this fail on a missing `hasTrustDialogAccepted`.
    @Test func anInterleavedEnsureLeavesTheTrustEntryIntact() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-lane-trust-\(UUID().uuidString)", isDirectory: true)
        let profileID = UUID()
        let manager = ClaudeProfileConfigDirManager(
            baseDirectory: dir, hostBaseDirectory: dir.appendingPathComponent("host"))
        let configDir = manager.configDirectory(forProfileID: profileID)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let claudeJSON = configDir.appendingPathComponent(".claude.json")
        let key = "sk-ant-test-key-0123456789"
        // The pre-trust file: what a lane-ignoring ensure reads if it starts
        // before the trust write lands.
        try JSONSerialization.data(
            withJSONObject: ["hasCompletedOnboarding": true], options: [.sortedKeys]
        ).write(to: claudeJSON, options: [.atomic])

        let (holderEntered, holderDidEnter) = AsyncStream<Void>.makeStream()
        let (ensureIssued, ensureWasIssued) = AsyncStream<Void>.makeStream()
        let (trustWritten, trustWasWritten) = AsyncStream<Void>.makeStream()

        // The trust seeder's part, holding the lane the way the seeder does.
        async let holder: Void = ClaudeConfigDirSerializer.shared.run(
            configDir: configDir.path
        ) {
            holderDidEnter.yield()
            var issued = ensureIssued.makeAsyncIterator()
            _ = await issued.next()
            // Give a lane-ignoring ensure every chance to reach its read before
            // the trust entry exists.
            try? await Task.sleep(for: .milliseconds(50))
            let seeded: [String: Any] = [
                "hasCompletedOnboarding": true,
                "projects": ["/some/worktree": ["hasTrustDialogAccepted": true]],
            ]
            try JSONSerialization.data(withJSONObject: seeded, options: [.sortedKeys])
                .write(to: claudeJSON, options: [.atomic])
            trustWasWritten.yield()
        }
        var entries = holderEntered.makeAsyncIterator()
        _ = await entries.next()

        async let ensure: Void = {
            _ = try? await manager.ensureAPIKeyDir(
                forProfileID: profileID, apiKey: key,
                afterReadForTesting: {
                    // Held only by an ensure that read before the trust write;
                    // an ensure that waited for the lane finds this already
                    // yielded and passes straight through.
                    var written = trustWritten.makeAsyncIterator()
                    _ = await written.next()
                })
        }()
        ensureWasIssued.yield()

        _ = try await holder
        await ensure

        let parsed = try JSONSerialization.jsonObject(
            with: Data(contentsOf: claudeJSON)) as? [String: Any]
        let projects = parsed?["projects"] as? [String: Any]
        let entry = projects?["/some/worktree"] as? [String: Any]
        #expect(entry?["hasTrustDialogAccepted"] as? Bool == true,
                "the trust entry was lost to an interleaved ensure: \(parsed ?? [:])")
        // Also proves the ensure really rewrote the file, so the assertion above
        // is not passing merely because nothing ran.
        let responses = parsed?["customApiKeyResponses"] as? [String: Any]
        #expect((responses?["approved"] as? [String])?.contains(String(key.suffix(20))) == true,
                "the api-key approval must also survive")
    }
}
