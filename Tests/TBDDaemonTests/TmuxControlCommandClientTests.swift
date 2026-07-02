import Foundation
import Testing
@testable import TBDDaemonLib

/// Unit tests for the FIFO command correlation layer, driven entirely with
/// fabricated parser events — no tmux, no ~/tbd access.
@Suite("TmuxControlCommandClient")
struct TmuxControlCommandClientTests {

    /// Build a client whose side effects funnel into a fresh `Recorder`.
    private func makeClient() -> (TmuxControlCommandClient, Recorder) {
        let recorder = Recorder()
        let client = TmuxControlCommandClient(
            writeLine: { line in recorder.recordWrite(line) },
            onFatalError: { recorder.recordFatal() })
        return (client, recorder)
    }

    /// A `%end` reply block from THIS client (flags bit 0 set → fromClient).
    private func clientSuccess(_ number: Int, _ lines: [String]) -> TmuxControlEvent {
        .commandSucceeded(number: number, fromClient: true, lines: lines)
    }
    private func clientError(_ number: Int, _ lines: [String]) -> TmuxControlEvent {
        .commandFailed(number: number, fromClient: true, lines: lines)
    }

    @Test("completes commands in FIFO order")
    func fifoOrder() async throws {
        let (client, _) = makeClient()
        // Stagger the two sends so their enqueue order is deterministic; the
        // point under test is that replies match that order, not scheduling.
        let first = Task { try await client.send("cmd-a") }
        try await Task.sleep(for: .milliseconds(30))
        let second = Task { try await client.send("cmd-b") }
        try await Task.sleep(for: .milliseconds(30))

        await client.handle(clientSuccess(1, ["reply-a"]))
        await client.handle(clientSuccess(2, ["reply-b"]))

        #expect(try await first.value == ["reply-a"])
        #expect(try await second.value == ["reply-b"])
    }

    @Test("sendList writes one line and completes per-command in order")
    func sendListSingleWrite() async throws {
        let (client, recorder) = makeClient()
        let box = CompletionBox()
        await client.sendList([
            TmuxCommand(text: "a") { result in box.record(result) },
            TmuxCommand(text: "b") { result in box.record(result) },
            TmuxCommand(text: "c") { result in box.record(result) }
        ])

        // Exactly one stream write, carrying the batch joined by newlines.
        #expect(recorder.writes == ["a\nb\nc"])

        await client.handle(clientSuccess(1, ["one"]))
        await client.handle(clientSuccess(2, ["two"]))
        await client.handle(clientSuccess(3, ["three"]))

        let results = box.results
        #expect(results.count == 3)
        #expect(try results.map { try $0.get() } == [["one"], ["two"], ["three"]])
    }

    @Test("tolerated error completes the command and keeps the connection alive")
    func tolerateErrorSurvives() async throws {
        let (client, recorder) = makeClient()
        let call = Task { try await client.send("bogus", tolerateErrors: true) }
        try await Task.sleep(for: .milliseconds(30))
        await client.handle(clientError(1, ["boom"]))

        await #expect(throws: TmuxCommandError.commandFailed(lines: ["boom"])) {
            _ = try await call.value
        }
        #expect(recorder.fatalCount == 0)

        // A subsequent send still works — the connection was not torn down.
        let next = Task { try await client.send("still-here") }
        try await Task.sleep(for: .milliseconds(30))
        await client.handle(clientSuccess(2, ["ok"]))
        #expect(try await next.value == ["ok"])
    }

    @Test("un-tolerated error tears the connection down")
    func untoleratedErrorIsFatal() async throws {
        let (client, recorder) = makeClient()
        let call = Task { try await client.send("bogus") }
        try await Task.sleep(for: .milliseconds(30))
        await client.handle(clientError(1, ["boom"]))

        await #expect(throws: TmuxCommandError.commandFailed(lines: ["boom"])) {
            _ = try await call.value
        }
        #expect(recorder.fatalCount == 1)
    }

    @Test("absorbs a server-originated block (the attach greeting)")
    func greetingAbsorbed() async throws {
        let (client, recorder) = makeClient()
        // Greeting: flags 0 → fromClient false, arriving with an empty queue.
        await client.handle(.commandSucceeded(number: 0, fromClient: false, lines: []))
        #expect(recorder.fatalCount == 0)

        // A subsequently queued command still completes normally.
        let call = Task { try await client.send("cmd") }
        try await Task.sleep(for: .milliseconds(30))
        await client.handle(clientSuccess(1, ["done"]))
        #expect(try await call.value == ["done"])
    }

    @Test("a client reply with an empty queue is a fatal protocol violation")
    func emptyQueueViolation() async throws {
        let (client, recorder) = makeClient()
        await client.handle(clientSuccess(1, ["orphan"]))
        #expect(recorder.fatalCount == 1)

        // Subsequent sends fail fast — the client marked itself closed.
        await #expect(throws: TmuxCommandError.connectionClosed) {
            _ = try await client.send("after")
        }
    }

    @Test("connectionClosed fails all pending in order")
    func connectionClosedFailsPending() async throws {
        let (client, _) = makeClient()
        let first = Task { try await client.send("a") }
        try await Task.sleep(for: .milliseconds(30))
        let second = Task { try await client.send("b") }
        try await Task.sleep(for: .milliseconds(30))

        await client.connectionClosed()

        await #expect(throws: TmuxCommandError.connectionClosed) { _ = try await first.value }
        await #expect(throws: TmuxCommandError.connectionClosed) { _ = try await second.value }
    }

    @Test("a command with an embedded newline is rejected and never written")
    func newlineRejected() async throws {
        let (client, recorder) = makeClient()
        await #expect(throws: TmuxCommandError.invalidCommand) {
            _ = try await client.send("evil\ncommand")
        }
        #expect(recorder.writes.isEmpty)
        #expect(recorder.fatalCount == 0)
    }

    @Test("an empty command is rejected and never written")
    func emptyRejected() async throws {
        let (client, recorder) = makeClient()
        await #expect(throws: TmuxCommandError.invalidCommand) {
            _ = try await client.send("")
        }
        #expect(recorder.writes.isEmpty)
        #expect(recorder.fatalCount == 0)
    }

    @Test("a whitespace-only command is rejected and never written")
    func whitespaceOnlyRejected() async throws {
        let (client, recorder) = makeClient()
        await #expect(throws: TmuxCommandError.invalidCommand) {
            _ = try await client.send("   ")
        }
        #expect(recorder.writes.isEmpty)
        #expect(recorder.fatalCount == 0)
    }

    @Test("a command with an embedded carriage return is rejected and never written")
    func carriageReturnRejected() async throws {
        let (client, recorder) = makeClient()
        await #expect(throws: TmuxCommandError.invalidCommand) {
            _ = try await client.send("cmd\rtail")
        }
        #expect(recorder.writes.isEmpty)
        #expect(recorder.fatalCount == 0)
    }

    @Test("sendList rejects the whole batch when one entry is blank")
    func sendListRejectsBlankEntry() async throws {
        let (client, recorder) = makeClient()
        let box = CompletionBox()
        await client.sendList([
            TmuxCommand(text: "valid-a") { box.record($0) },
            TmuxCommand(text: "") { box.record($0) },
            TmuxCommand(text: "valid-b") { box.record($0) }
        ])

        let results = box.results
        #expect(results.count == 3)
        for result in results {
            #expect(throws: TmuxCommandError.invalidCommand) { try result.get() }
        }
        #expect(recorder.writes.isEmpty)
        #expect(recorder.fatalCount == 0)
    }
}

/// Thread-safe, synchronous recorder for `writeLine` / `onFatalError` side
/// effects. Synchronous (not an actor) so `@Sendable` closures record in the
/// exact call order — an actor hop would reorder writes nondeterministically.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _writes: [String] = []
    private var _fatalCount = 0

    func recordWrite(_ line: String) { lock.lock(); _writes.append(line); lock.unlock() }
    func recordFatal() { lock.lock(); _fatalCount += 1; lock.unlock() }
    var writes: [String] { lock.lock(); defer { lock.unlock() }; return _writes }
    var fatalCount: Int { lock.lock(); defer { lock.unlock() }; return _fatalCount }
}

/// Collects command completions from the `@Sendable` closures for assertion.
private final class CompletionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _results: [Result<[String], TmuxCommandError>] = []

    func record(_ result: Result<[String], TmuxCommandError>) {
        lock.lock(); _results.append(result); lock.unlock()
    }
    var results: [Result<[String], TmuxCommandError>] { lock.lock(); defer { lock.unlock() }; return _results }
}
