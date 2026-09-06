import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
import TBDShared

/// Cache, executable pinning, and the fallback — the three decisions between an
/// RPC and an answer.
///
/// Tier 1: every collaborator is injected. No process is spawned, no filesystem
/// is read, and the fingerprint is a value the test chooses.
@Suite("CompletionInventoryService")
struct CompletionInventoryServiceTests {

    private actor Counter {
        private(set) var value = 0
        func bump() { value += 1 }
    }

    private actor Trace {
        private(set) var marks: [String] = []
        func mark(_ value: String) { marks.append(value) }
    }

    private func request(terminalID: UUID = UUID(), childPID: Int32? = 4242) ->
        CompletionInventoryService.Request {
        CompletionInventoryService.Request(
            terminalID: terminalID, childPID: childPID, panePID: nil,
            configDir: "/cfg", worktreePath: "/wt", environment: [:])
    }

    private func makeService(
        probeCalls: Counter,
        probeResult: @escaping @Sendable () async throws -> ClaudeCompletionProbe.Outcome,
        fingerprint: @escaping @Sendable (String, String) -> String = { _, _ in "fp-1" },
        scan: @escaping CompletionInventoryService.Scanner = { _, _ in
            ([CompletionCommand(name: "scanned", description: "d")], [])
        }
    ) -> CompletionInventoryService {
        CompletionInventoryService(
            probe: { _, _, _ in
                await probeCalls.bump()
                return try await probeResult()
            },
            scan: scan,
            resolveExecutable: { "/usr/local/bin/claude" },
            executablePathForPID: { _ in "/versions/2.1.261/claude" },
            fingerprint: fingerprint)
    }

    // MARK: - Executable pinning

    @Test func itPinsTheRunningBinaryFromTheChildPID() {
        let pinned = CompletionInventoryService.pinnedExecutable(
            childPID: 4242, panePID: 99,
            executablePathForPID: { pid in pid == 4242 ? "/versions/a/claude" : "/versions/b/claude" },
            fallback: { "/resolved/claude" })
        #expect(pinned == "/versions/a/claude")
    }

    @Test func itFallsBackToThePanePIDThenToTheResolver() {
        #expect(CompletionInventoryService.pinnedExecutable(
            childPID: nil, panePID: 99,
            executablePathForPID: { pid in pid == 99 ? "/versions/b/claude" : nil },
            fallback: { "/resolved/claude" }) == "/versions/b/claude")

        // Neither pid resolves — a shell that has not yet exec'd, or a versioned
        // file that is gone. Silent fallback, no marker.
        #expect(CompletionInventoryService.pinnedExecutable(
            childPID: 4242, panePID: 99,
            executablePathForPID: { _ in nil },
            fallback: { "/resolved/claude" }) == "/resolved/claude")

        #expect(CompletionInventoryService.pinnedExecutable(
            childPID: nil, panePID: nil,
            executablePathForPID: { _ in nil },
            fallback: { nil }) == nil)
    }

    /// The holder records the pid of `$SHELL -ilc "… claude …"`, and that pid
    /// presents as the login shell until it `exec`s the agent. Pinning the shell
    /// would run `zsh` with the probe's flags, fail, and drop every request to
    /// the uncached scan for as long as the window lasts — so a shell is skipped
    /// and the next candidate is tried.
    @Test func itSkipsAPIDThatIsStillAShell() {
        #expect(CompletionInventoryService.pinnedExecutable(
            childPID: 4242, panePID: 99,
            executablePathForPID: { pid in pid == 4242 ? "/bin/zsh" : "/versions/x/claude" },
            fallback: { "/resolved/claude" }) == "/versions/x/claude")

        // Both pids still shells: nothing running is worth asking, so the
        // resolver answers.
        #expect(CompletionInventoryService.pinnedExecutable(
            childPID: 4242, panePID: 99,
            executablePathForPID: { pid in pid == 4242 ? "/bin/zsh" : "/opt/homebrew/bin/fish" },
            fallback: { "/resolved/claude" }) == "/resolved/claude")

        // The gate is "not a shell", never "is named claude": a renamed binary
        // or a stub script is a legitimate thing for a session to be running.
        #expect(CompletionInventoryService.pinnedExecutable(
            childPID: 4242, panePID: nil,
            executablePathForPID: { _ in "/opt/tbd/claude-stub.py" },
            fallback: { "/resolved/claude" }) == "/opt/tbd/claude-stub.py")
    }

    // MARK: - Fingerprint

    /// `attributesOfItem(atPath:)` has `lstat` semantics, and
    /// `ClaudeProfileConfigDirManager.mirrorSlots` symlinks `commands`,
    /// `skills`, `agents` and `settings.json` into every profile config
    /// directory. Stat the link and four of the six config-dir entries report a
    /// mtime frozen at profile creation, so adding a command or a skill would
    /// never invalidate the cache.
    @Test func theFingerprintFollowsASymlinkedCommandsDirectory() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: fencedScratchRoot(prefix: "tbdfp"))
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let configDir = root.appendingPathComponent("config")
        let worktree = root.appendingPathComponent("wt")
        let target = root.appendingPathComponent("store/commands")
        for dir in [configDir, worktree, target] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try fm.createSymbolicLink(
            at: configDir.appendingPathComponent("commands"),
            withDestinationURL: target)

        let before = CompletionInventoryService.liveFingerprint(configDir.path, worktree.path)
        // An explicit later date rather than a touch: mtime at one-second
        // resolution would let a change inside the same second look like none.
        try fm.setAttributes(
            [.modificationDate: Date().addingTimeInterval(120)],
            ofItemAtPath: target.path)
        let after = CompletionInventoryService.liveFingerprint(configDir.path, worktree.path)

        #expect(before != after,
                "a change under the symlink target must invalidate the cache")
    }

    // MARK: - Cache

    @Test func aSecondRequestWithTheSameFingerprintServesTheCache() async throws {
        let calls = Counter()
        let service = makeService(probeCalls: calls, probeResult: {
            ClaudeCompletionProbe.Outcome(
                commands: [CompletionCommand(name: "probed", description: "d")], agents: [])
        })
        let req = request()

        let first = await service.inventory(for: req)
        let second = await service.inventory(for: req)

        #expect(await calls.value == 1, "the probe must run only on a cache miss")
        #expect(first.freshness == .fresh)
        #expect(second.freshness == .stale)
        #expect(second.commands.map(\.name) == ["probed"])
    }

    /// The fingerprint is what makes a new skill appear without a TBD release.
    @Test func aChangedFingerprintReProbes() async throws {
        let calls = Counter()
        let stamp = MutableStamp()
        let service = makeService(
            probeCalls: calls,
            probeResult: {
                ClaudeCompletionProbe.Outcome(
                    commands: [CompletionCommand(name: "probed", description: "d")], agents: [])
            },
            fingerprint: { _, _ in stamp.value })
        let req = request()

        _ = await service.inventory(for: req)
        stamp.value = "fp-2"
        let second = await service.inventory(for: req)

        #expect(await calls.value == 2)
        #expect(second.freshness == .fresh)
    }

    /// Two terminals on different config directories must not share one answer.
    @Test func theCacheKeyIncludesTheConfigDirectory() async throws {
        let calls = Counter()
        let service = makeService(probeCalls: calls, probeResult: {
            ClaudeCompletionProbe.Outcome(commands: [], agents: [])
        })
        _ = await service.inventory(for: request())
        _ = await service.inventory(for: CompletionInventoryService.Request(
            terminalID: UUID(), childPID: 4242, panePID: nil,
            configDir: "/other-cfg", worktreePath: "/wt", environment: [:]))
        #expect(await calls.value == 2)
    }

    /// Two worktrees on one profile see different project-level commands, so the
    /// worktree path is part of the identity a cached answer is keyed on.
    @Test func theCacheKeyIncludesTheWorktreePath() async throws {
        let calls = Counter()
        let service = makeService(probeCalls: calls, probeResult: {
            ClaudeCompletionProbe.Outcome(commands: [], agents: [])
        })
        _ = await service.inventory(for: request())
        _ = await service.inventory(for: CompletionInventoryService.Request(
            terminalID: UUID(), childPID: 4242, panePID: nil,
            configDir: "/cfg", worktreePath: "/other-wt", environment: [:]))
        #expect(await calls.value == 2)
    }

    // MARK: - Fallback

    /// Nothing resolves — no pid presents a binary and the resolver has none
    /// either. There is no probe to run, so none is attempted.
    @Test func noResolvableExecutableScansWithoutProbing() async throws {
        let calls = Counter()
        let service = CompletionInventoryService(
            probe: { _, _, _ in
                await calls.bump()
                return ClaudeCompletionProbe.Outcome(commands: [], agents: [])
            },
            scan: { _, _ in ([CompletionCommand(name: "scanned", description: "d")], []) },
            resolveExecutable: { nil },
            executablePathForPID: { _ in nil },
            fingerprint: { _, _ in "fp-1" })

        let result = await service.inventory(for: request())

        #expect(await calls.value == 0, "there is no binary to ask")
        #expect(result.source == .scan)
        #expect(result.freshness == .fallback)
        #expect(result.commands.map(\.name) == ["scanned"])
    }

    @Test func aTimedOutProbeFallsBackToTheScan() async throws {
        let calls = Counter()
        let service = makeService(probeCalls: calls, probeResult: {
            throw ClaudeCompletionProbe.ProbeError.timedOut
        })

        let result = await service.inventory(for: request())

        #expect(result.source == .scan)
        #expect(result.freshness == .fallback)
        #expect(result.commands.map(\.name) == ["scanned"])
    }

    @Test func aSuccessfulProbeReportsItself() async throws {
        let calls = Counter()
        let service = makeService(probeCalls: calls, probeResult: {
            ClaudeCompletionProbe.Outcome(
                commands: [CompletionCommand(name: "probed", description: "d")], agents: [])
        })
        let result = await service.inventory(for: request())
        #expect(result.source == .probe)
        #expect(result.freshness == .fresh)
    }

    /// A fallback answer is deliberately NOT cached as if it were the real one:
    /// the next request must try the binary again rather than serve a degraded
    /// list until something on disk happens to change.
    @Test func aFallbackIsNotCached() async throws {
        let calls = Counter()
        let service = makeService(probeCalls: calls, probeResult: {
            throw ClaudeCompletionProbe.ProbeError.timedOut
        })
        _ = await service.inventory(for: request())
        _ = await service.inventory(for: request())
        #expect(await calls.value == 2)
    }

    // MARK: - The serializer lane

    /// The probe rewrites `.claude.json`, and so does `ClaudeTrustSeeder`, so
    /// the probe must run through the per-directory lane rather than beside it.
    /// A seed that is already inside the lane for this request's config
    /// directory must therefore finish before the probe starts.
    ///
    /// The seed body suspends in the middle, which is the whole point: an actor
    /// would let the probe run inside that suspension, and only the lane orders
    /// them. Remove `serializer.run` from `inventory(for:)` and the probe's mark
    /// lands between the seed's two, failing this.
    @Test func theProbeRunsInsideTheConfigDirectoryLane() async throws {
        let serializer = ClaudeConfigDirSerializer()
        let trace = Trace()
        let service = CompletionInventoryService(
            probe: { _, _, _ in
                await trace.mark("probe")
                return ClaudeCompletionProbe.Outcome(commands: [], agents: [])
            },
            scan: { _, _ in ([], []) },
            resolveExecutable: { "/usr/local/bin/claude" },
            executablePathForPID: { _ in "/versions/2.1.261/claude" },
            fingerprint: { _, _ in "fp-1" },
            serializer: serializer)

        // Occupy the lane for the request's own config directory, signalling as
        // the body enters so the request is made after the lane is held rather
        // than after a guessed sleep.
        let (seedEntered, seedDidEnter) = AsyncStream<Void>.makeStream()
        async let seed: Void = serializer.run(configDir: "/cfg") {
            await trace.mark("seed-start")
            seedDidEnter.yield()
            try? await Task.sleep(for: .milliseconds(40))
            await trace.mark("seed-end")
        }
        var seedEntries = seedEntered.makeAsyncIterator()
        _ = await seedEntries.next()

        _ = await service.inventory(for: request())
        _ = try await seed

        #expect(await trace.marks == ["seed-start", "seed-end", "probe"],
                "the probe must wait for the lane, not interleave with it")
    }

    /// A lock-guarded box, not an actor: the fingerprint seam is a synchronous
    /// closure, exactly like the `now: () -> Date` seam `Tests/CLAUDE.md`
    /// describes.
    private final class MutableStamp: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = "fp-1"
        var value: String {
            get { lock.lock(); defer { lock.unlock() }; return storage }
            set { lock.lock(); storage = newValue; lock.unlock() }
        }
    }
}
