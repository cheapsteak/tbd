import Clocks
import Darwin
import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib

/// Exercises CodexUsageFetcher's real child-process lifecycle with a controlled
/// shell fake. Only the deadline is virtual.
///
/// **Tier 3** — spawns a real process and proves SIGTERM/SIGKILL teardown by
/// polling the exact PID the child wrote to a unique marker. CI runs this
/// target serially on an otherwise-idle machine.
@Suite("Codex usage fetcher lifecycle", .serialized, .timeLimit(.minutes(1)))
struct CodexUsageFetcherLifecycleTests {
    /// Far beyond the suite limit, so only the TestClock can fire the timeout.
    fileprivate static let unreachableTimeout: Duration = .seconds(600)

    @Test func virtualTimeoutReturnsTimedOutAndKillsChild() async throws {
        let fixture = try ProcessFixture()
        defer { fixture.cleanup() }
        let clock = TestClock()
        let fetch = Task {
            await fixture.fetcher(clock: clock).fetch()
        }
        defer { fetch.cancel() }
        let pid = try await fixture.waitForPID()
        defer { fixture.killIfStillAlive(pid) }

        await clock.advanceWhenSuspended(by: Self.unreachableTimeout)
        let result = await fetch.value

        #expect(result.unavailableReason == "Usage timed out")
        try await fixture.waitUntilDead(pid)
    }

    @Test func cancellationReturnsUnavailableAndKillsChild() async throws {
        let fixture = try ProcessFixture()
        defer { fixture.cleanup() }
        let fetch = Task {
            await fixture.fetcher(clock: TestClock()).fetch()
        }
        defer { fetch.cancel() }
        let pid = try await fixture.waitForPID()
        defer { fixture.killIfStillAlive(pid) }

        fetch.cancel()
        let result = await fetch.value

        #expect(result.unavailableReason == "Usage unavailable")
        try await fixture.waitUntilDead(pid)
    }
}

private struct ProcessFixture {
    private struct PollingFailure: Error, CustomStringConvertible {
        let description: String
    }

    let directory: URL
    let pidMarker: URL
    let blockingFIFO: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-usage-lifecycle-\(UUID().uuidString)", isDirectory: true)
        pidMarker = directory.appendingPathComponent("pid", isDirectory: false)
        blockingFIFO = directory.appendingPathComponent("block", isDirectory: false)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard mkfifo(blockingFIFO.path, 0o600) == 0 else {
            throw PollingFailure(description: "Could not create Codex usage lifecycle FIFO: errno \(errno)")
        }
    }

    func fetcher(clock: any Clock<Duration>) -> CodexUsageFetcher {
        CodexUsageFetcher(
            executable: "/bin/sh",
            arguments: [
                "-c",
                """
                printf '%s' "$$" > "$1"
                trap '' TERM
                exec 3<> "$2"
                IFS= read -r _ <&3
                """,
                "codex-usage-lifecycle",
                pidMarker.path,
                blockingFIFO.path,
            ],
            timeout: CodexUsageFetcherLifecycleTests.unreachableTimeout,
            clock: clock
        )
    }

    func waitForPID(
        timeout: Duration = .seconds(10),
        pollInterval: Duration = .milliseconds(20)
    ) async throws -> pid_t {
        let deadline = ContinuousClock.now + timeout
        repeat {
            if let contents = try? String(contentsOf: pidMarker, encoding: .utf8),
               let pid = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines)),
               pid > 0 {
                return pid
            }
            try await Task.sleep(for: pollInterval)
        } while ContinuousClock.now < deadline
        throw PollingFailure(description: "Codex usage child did not write its PID marker within \(timeout)")
    }

    func waitUntilDead(
        _ pid: pid_t,
        timeout: Duration = .seconds(10),
        pollInterval: Duration = .milliseconds(20)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        repeat {
            if !isAlive(pid) { return }
            try await Task.sleep(for: pollInterval)
        } while ContinuousClock.now < deadline
        throw PollingFailure(description: "Codex usage child PID \(pid) was still alive after \(timeout)")
    }

    func killIfStillAlive(_ pid: pid_t) {
        if isAlive(pid) {
            _ = kill(pid, SIGKILL)
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func isAlive(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }
}
