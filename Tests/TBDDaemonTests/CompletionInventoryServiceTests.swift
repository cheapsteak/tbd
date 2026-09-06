import Foundation
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

    // MARK: - Fallback

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
