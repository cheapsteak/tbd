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
    /// Far beyond the suite limit, so only the `EventDrivenTestClock` can fire the timeout.
    fileprivate static let unreachableTimeout: Duration = .seconds(600)

    @Test func virtualTimeoutReturnsTimedOutAndKillsChild() async throws {
        let fixture = try ProcessFixture()
        defer { fixture.cleanup() }
        let clock = EventDrivenTestClock()
        let fetch = Task {
            await fixture.fetcher(clock: clock).fetch()
        }
        defer { fetch.cancel() }
        let pid = try await fixture.waitForPID()
        defer { fixture.killIfStillAlive(pid) }

        try await clock.requireAdvanceWhenArmed(by: Self.unreachableTimeout)
        let result = await fetch.value

        #expect(result.unavailableReason == "Usage timed out")
        try await fixture.waitUntilDead(pid)
    }

    @Test func cancellationReturnsUnavailableAndKillsChild() async throws {
        let fixture = try ProcessFixture()
        defer { fixture.cleanup() }
        let fetch = Task {
            await fixture.fetcher(clock: EventDrivenTestClock()).fetch()
        }
        defer { fetch.cancel() }
        let pid = try await fixture.waitForPID()
        defer { fixture.killIfStillAlive(pid) }

        fetch.cancel()
        let result = await fetch.value

        #expect(result.unavailableReason == "Usage unavailable")
        try await fixture.waitUntilDead(pid)
    }

    /// The session writes JSON-RPC requests into the child's stdin, and a CLI
    /// that exits under a write fails it with EPIPE. `start` marks the write
    /// end `F_SETNOSIGPIPE` so that failure raises no SIGPIPE. The session
    /// keeps the write end to itself, so the test reaches it as the pipe peer
    /// of the child's stdin (`pipeWriteEnd(peerOf:inProcess:)`), which the
    /// fake holds open while it blocks on its FIFO, and reads the flag back
    /// before cancelling.
    @Test func stdinWriteEndIsMarkedNoSIGPIPE() async throws {
        let fixture = try ProcessFixture()
        defer { fixture.cleanup() }
        let fetch = Task {
            await fixture.fetcher(clock: EventDrivenTestClock()).fetch()
        }
        defer { fetch.cancel() }
        let pid = try await fixture.waitForPID()
        defer { fixture.killIfStillAlive(pid) }

        let writeEnd = pipeWriteEnd(peerOf: STDIN_FILENO, inProcess: pid)
        let noSIGPIPE = writeEnd.map { fcntl($0, F_GETNOSIGPIPE) }

        fetch.cancel()
        _ = await fetch.value
        try await fixture.waitUntilDead(pid)

        let readBack = noSIGPIPE.map { "F_GETNOSIGPIPE read \($0)" }
            ?? "no descriptor in this process was the pipe peer of the child's stdin"
        #expect(
            noSIGPIPE == 1,
            "start must mark the stdin pipe's write end F_SETNOSIGPIPE; \(readBack)")
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
