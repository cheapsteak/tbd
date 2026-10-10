import Foundation
import Testing
import TBDShared

@testable import TBDCLI

/// A clock whose sleeps return at once and are recorded, so reconnect backoff
/// is asserted on durations, not wall time.
private final class ImmediateClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (l: Instant, r: Instant) -> Bool { l.offset < r.offset }
    }
    private let lock = NSLock()
    private var slept: [Duration] = []
    var sleeps: [Duration] { lock.withLock { slept } }
    var now: Instant { Instant(offset: .zero) }
    var minimumResolution: Duration { .nanoseconds(1) }
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        lock.withLock { slept.append(deadline.offset) }
    }
}

private struct Boom: Error {}

/// Scripted transport: each queue is consumed in order; an empty queue throws.
private final class FakePromptTransport: PromptWaitTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var registerScript: [Result<PromptRegisterResult, Error>]
    private var awaitScript: [Result<PromptAwaitReply, Error>]
    private(set) var registers: [PromptRegisterParams] = []
    private(set) var acks: [PromptAckParams] = []
    let running: Bool

    init(running: Bool = true,
         register: [Result<PromptRegisterResult, Error>] = [],
         await awaits: [Result<PromptAwaitReply, Error>] = []) {
        self.running = running
        self.registerScript = register
        self.awaitScript = awaits
    }

    var isDaemonRunning: Bool { running }

    func register(_ params: PromptRegisterParams) throws -> PromptRegisterResult {
        try lock.withLock {
            registers.append(params)
            guard !registerScript.isEmpty else { throw Boom() }
            return try registerScript.removeFirst().get()
        }
    }

    func awaitResolution(_ params: PromptAwaitParams) throws -> PromptAwaitReply {
        try lock.withLock {
            guard !awaitScript.isEmpty else { throw Boom() }
            return try awaitScript.removeFirst().get()
        }
    }

    func ack(_ params: PromptAckParams) throws {
        lock.withLock { acks.append(params) }
    }
}

private final class Output: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [String] = []
    let succeeds: Bool
    init(succeeds: Bool = true) { self.succeeds = succeeds }
    var written: [String] { lock.withLock { chunks } }
    func write(_ text: String) -> Bool {
        lock.withLock { chunks.append(text) }
        return succeeds
    }
}

@Suite("PromptWaiter")
struct PromptWaiterTests {
    private let terminalID = UUID()
    private let request = PromptHookPayloadParser.PermissionRequest(
        sessionID: "s1", toolName: "Bash", toolInputJSON: #"{"command":"ls"}"#,
        suggestionsJSON: nil, inputHash: "h", transcriptPath: nil)

    private func waiter(
        _ transport: FakePromptTransport, _ out: Output, _ clock: ImmediateClock = ImmediateClock()
    ) -> PromptWaiter {
        PromptWaiter(transport: transport, clock: clock, write: { out.write($0) })
    }

    @Test func silentWhenDaemonDown() async {
        let t = FakePromptTransport(running: false)
        let out = Output()
        await waiter(t, out).run(terminalID: terminalID, request: request)
        #expect(t.registers.isEmpty)
        #expect(out.written.isEmpty)
    }

    @Test func silentWhenDisabled() async {
        let t = FakePromptTransport(register: [.success(.disabled)])
        let out = Output()
        await waiter(t, out).run(terminalID: terminalID, request: request)
        #expect(out.written.isEmpty)
        #expect(t.acks.isEmpty)
    }

    @Test func silentWhenFirstRegisterFails() async {
        let t = FakePromptTransport()
        let out = Output()
        let clock = ImmediateClock()
        await waiter(t, out, clock).run(terminalID: terminalID, request: request)
        #expect(out.written.isEmpty)
        #expect(clock.sleeps.isEmpty)
    }

    @Test func silentWhenResolvedElsewhere() async {
        let t = FakePromptTransport(
            register: [.success(.registered(promptID: "p1"))],
            await: [.success(PromptAwaitReply(result: .resolvedElsewhere, deliveryToken: nil))])
        let out = Output()
        await waiter(t, out).run(terminalID: terminalID, request: request)
        #expect(out.written.isEmpty)
        #expect(t.acks.isEmpty)
    }

    @Test func printsExactlyTheDecisionAndAcks() async {
        let token = UUID()
        let output = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest"}}"#
        let t = FakePromptTransport(
            register: [.success(.registered(promptID: "p1"))],
            await: [.success(PromptAwaitReply(result: .answered(hookOutput: output), deliveryToken: token))])
        let out = Output()
        await waiter(t, out).run(terminalID: terminalID, request: request)
        #expect(out.written == [output])
        #expect(t.acks.count == 1)
        #expect(t.acks.first?.token == token)
        #expect(t.acks.first?.delivered == true)
        #expect(t.registers.first?.knownPromptID == nil)
    }

    @Test func failedPrintAcksNotDelivered() async {
        let token = UUID()
        let t = FakePromptTransport(
            register: [.success(.registered(promptID: "p1"))],
            await: [.success(PromptAwaitReply(result: .answered(hookOutput: "{}"), deliveryToken: token))])
        let out = Output(succeeds: false)
        await waiter(t, out).run(terminalID: terminalID, request: request)
        #expect(t.acks.first?.token == token)
        #expect(t.acks.first?.delivered == false)
    }

    @Test func reconnectsAndReRegistersWithKnownID() async {
        let token = UUID()
        let t = FakePromptTransport(
            register: [.success(.registered(promptID: "p1")), .success(.registered(promptID: "p1"))],
            await: [.failure(Boom()),
                    .success(PromptAwaitReply(result: .answered(hookOutput: "{}"), deliveryToken: token))])
        let out = Output()
        let clock = ImmediateClock()
        await waiter(t, out, clock).run(terminalID: terminalID, request: request)
        #expect(t.registers.count == 2)
        #expect(t.registers[0].knownPromptID == nil)
        #expect(t.registers[1].knownPromptID == "p1")
        #expect(out.written == ["{}"])
        #expect(clock.sleeps.count == 1)
    }

    @Test func reRegisterCarriesThePairedToolUseID() async {
        let token = UUID()
        let t = FakePromptTransport(
            register: [.success(.registered(promptID: "p1", toolUseID: "toolu_1")),
                       .success(.registered(promptID: "p1"))],
            await: [.failure(Boom()),
                    .success(PromptAwaitReply(result: .answered(hookOutput: "{}"), deliveryToken: token))])
        let out = Output()
        await waiter(t, out).run(terminalID: terminalID, request: request)
        #expect(t.registers.count == 2)
        #expect(t.registers[0].knownToolUseID == nil)
        #expect(t.registers[1].knownPromptID == "p1")
        #expect(t.registers[1].knownToolUseID == "toolu_1",
                "a restarted daemon has no note left, so the hook must hand the pairing back")
    }

    @Test func givesUpSilentlyWhenTheDaemonStaysDown() async {
        let t = FakePromptTransport(
            register: [.success(.registered(promptID: "p1"))], await: [.failure(Boom())])
        let out = Output()
        let clock = ImmediateClock()
        var w = waiter(t, out, clock)
        w.reconnectBudget = .seconds(10)
        await w.run(terminalID: terminalID, request: request)
        #expect(out.written.isEmpty)
        #expect(clock.sleeps.reduce(Duration.zero, +) >= .seconds(10))
        #expect(clock.sleeps.reduce(Duration.zero, +) < .seconds(20))
        #expect(t.acks.isEmpty)
    }
}

@Suite("PromptHookPayloadParser")
struct PromptHookPayloadParserTests {
    @Test func permissionRequestWithSuggestions() throws {
        let json = #"""
        {"session_id":"s1","hook_event_name":"PermissionRequest","tool_name":"Bash",
         "tool_input":{"command":"ls","description":"d"},
         "permission_suggestions":[{"type":"addRules","behavior":"allow"}],
         "transcript_path":"/x/s1.jsonl"}
        """#
        let r = try #require(PromptHookPayloadParser.permissionRequest(Data(json.utf8)))
        #expect(r.sessionID == "s1")
        #expect(r.toolName == "Bash")
        #expect(r.toolInputJSON == #"{"command":"ls","description":"d"}"#)
        #expect(r.suggestionsJSON?.contains("addRules") == true)
        #expect(r.transcriptPath == "/x/s1.jsonl")
    }

    @Test func permissionRequestWithoutSuggestions() throws {
        let json = #"{"session_id":"s1","tool_name":"Edit","tool_input":{"file_path":"/a"}}"#
        let r = try #require(PromptHookPayloadParser.permissionRequest(Data(json.utf8)))
        #expect(r.suggestionsJSON == nil)
    }

    @Test func malformedPayloadsAreNil() {
        #expect(PromptHookPayloadParser.permissionRequest(Data("nope".utf8)) == nil)
        #expect(PromptHookPayloadParser.permissionRequest(Data(#"{"tool_name":"Bash"}"#.utf8)) == nil)
        #expect(PromptHookPayloadParser.toolEvent(Data("[]".utf8)) == nil)
        #expect(PromptHookPayloadParser.toolEvent(Data(#"{"session_id":"s","tool_name":"Bash"}"#.utf8)) == nil)
    }

    @Test func inputHashIgnoresKeyOrder() throws {
        let a = #"{"session_id":"s","tool_name":"T","tool_input":{"b":1,"a":2}}"#
        let b = #"{"session_id":"s","tool_name":"T","tool_input":{"a":2,"b":1}}"#
        let ra = try #require(PromptHookPayloadParser.permissionRequest(Data(a.utf8)))
        let rb = try #require(PromptHookPayloadParser.permissionRequest(Data(b.utf8)))
        #expect(ra.inputHash == rb.inputHash)
    }

    @Test func noteHashMatchesRegisterHash() throws {
        let input = #""tool_input":{"command":"ls","n":1}"#
        let pre = #"{"session_id":"s","tool_use_id":"u","hook_event_name":"PreToolUse","tool_name":"Bash",\#(input)}"#
        let perm = #"{"session_id":"s","tool_name":"Bash",\#(input)}"#
        let e = try #require(PromptHookPayloadParser.toolEvent(Data(pre.utf8)))
        let r = try #require(PromptHookPayloadParser.permissionRequest(Data(perm.utf8)))
        #expect(e.inputHash == r.inputHash)
    }

    @Test func toolEventPhases() throws {
        func event(_ name: String?, fallback: PromptNotePhase = .pre) throws -> PromptHookPayloadParser.ToolEvent {
            let ev = name.map { #","hook_event_name":"\#($0)""# } ?? ""
            let json = #"{"session_id":"s","tool_use_id":"u","tool_name":"Bash","tool_input":{"c":1}\#(ev)}"#
            return try #require(PromptHookPayloadParser.toolEvent(Data(json.utf8), fallbackPhase: fallback))
        }
        let pre = try event("PreToolUse")
        #expect(pre.phase == .pre)
        #expect(pre.inputHash != nil)
        #expect(pre.toolUseID == "u")
        for name in ["PostToolUse", "PostToolUseFailure"] {
            let post = try event(name)
            #expect(post.phase == .post)
            #expect(post.inputHash == pre.inputHash,
                    "a post carries the input hash so it can close an unpaired prompt")
        }
        #expect(try event(nil, fallback: .post).phase == .post)
        // The payload's own event wins over the flag.
        #expect(try event("PreToolUse", fallback: .post).phase == .pre)
    }
}
