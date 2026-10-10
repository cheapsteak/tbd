import Testing
import Foundation
@testable import TBDShared

@Suite("ProgramStatusParser")
struct ProgramStatusParserTests {

    private func parse(_ text: String) -> ProgramStatusPayload? {
        ProgramStatusParser.parse(Array(text.utf8))
    }

    private func report(_ text: String) -> ProgramStatusReport? {
        guard case .report(let r)? = parse(text) else { return nil }
        return r
    }

    private func b64(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    // MARK: - Probe

    @Test func questionMarkAloneIsProbe() {
        #expect(parse("?") == .probe)
        #expect(ProgramStatusParser.isProbe(Array("?".utf8)))
        #expect(ProgramStatusParser.isProbe(ArraySlice(Array("?".utf8))))
    }

    @Test func probeLookingJunkIsRejected() {
        #expect(parse("?x") == nil)
        #expect(!ProgramStatusParser.isProbe(Array("?x".utf8)))
        #expect(!ProgramStatusParser.isProbe([UInt8]()))
        #expect(!ProgramStatusParser.isProbe(Array("state=idle".utf8)))
    }

    @Test func probeReplyBytes() {
        #expect(Array(ProgramStatusProtocol.probeReply.utf8) == [0x1B, 0x5D, 0x37, 0x35, 0x30, 0x31, 0x3B, 0x3F, 0x07])
        #expect(ProgramStatusProtocol.oscCode == 7501)
    }

    // MARK: - Rejection

    @Test func emptyPayloadIsRejected() {
        #expect(ProgramStatusParser.parse([UInt8]()) == nil)
    }

    @Test func nonUTF8IsRejected() {
        #expect(ProgramStatusParser.parse([0xFF, 0xFE, 0x3D]) == nil)
    }

    @Test func missingStateIsRejected() {
        #expect(parse("app=claude-code:id=abc") == nil)
        #expect(parse("state") == nil)
        #expect(parse("=working") == nil)
    }

    // MARK: - Keys

    @Test func parsesEveryKey() throws {
        let text = "state=blocked:app=claude-code:id=task-1:kind=permission:progress=40:title=\(b64("Edit file")):msg=\(b64("Allow write?"))"
        let r = try #require(report(text))
        #expect(r.state == .blocked)
        #expect(r.app == "claude-code")
        #expect(r.id == "task-1")
        #expect(r.kind == .permission)
        #expect(r.progress == 40)
        #expect(r.title == "Edit file")
        #expect(r.msg == "Allow write?")
    }

    @Test func minimalReportHasNilOptionals() throws {
        let r = try #require(report("state=working"))
        #expect(r.state == .working)
        #expect(r.app == nil)
        #expect(r.id == nil)
        #expect(r.kind == nil)
        #expect(r.progress == nil)
        #expect(r.title == nil)
        #expect(r.msg == nil)
    }

    @Test func clearWithID() throws {
        let r = try #require(report("state=clear:id=X"))
        #expect(r.state == .clear)
        #expect(r.id == "X")
    }

    @Test func knownStates() throws {
        let pairs: [(String, ProgramStatusState)] = [
            ("working", .working), ("blocked", .blocked), ("done", .done),
            ("idle", .idle), ("error", .error), ("clear", .clear),
        ]
        for (raw, expected) in pairs {
            let r = try #require(report("state=\(raw)"))
            #expect(r.state == expected)
            #expect(r.state.rawValue == raw)
        }
    }

    @Test func knownKinds() throws {
        let pairs: [(String, ProgramStatusBlockKind)] = [
            ("permission", .permission), ("question", .question), ("auth", .auth),
        ]
        for (raw, expected) in pairs {
            let r = try #require(report("state=blocked:kind=\(raw)"))
            #expect(r.kind == expected)
        }
    }

    @Test func unknownStateAndKindAreUnrecognized() throws {
        let r = try #require(report("state=thinking:kind=sudo"))
        #expect(r.state == .unrecognized("thinking"))
        #expect(r.kind == .unrecognized("sudo"))
        #expect(r.state.rawValue == "thinking")
        #expect(r.kind?.rawValue == "sudo")
    }

    @Test func kindIsKeptWhateverTheState() throws {
        let r = try #require(report("state=working:kind=question"))
        #expect(r.kind == .question)
    }

    @Test func unknownKeysAndMalformedPiecesAreIgnored() throws {
        let r = try #require(report("future=1:state=idle:noequals:=empty"))
        #expect(r.state == .idle)
        #expect(r == ProgramStatusReport(state: .idle))
    }

    @Test func duplicateKeyLastWins() throws {
        let r = try #require(report("state=working:state=done"))
        #expect(r.state == .done)
    }

    @Test func valueSplitsOnFirstEquals() throws {
        let r = try #require(report("state=a=b"))
        #expect(r.state == .unrecognized("a=b"))
    }

    // MARK: - Progress

    private func progress(_ value: String) throws -> Int? {
        let r = try #require(report("state=working:progress=\(value)"))
        return r.progress
    }

    @Test func progressIsClamped() throws {
        #expect(try progress("-5") == 0)
        #expect(try progress("250") == 100)
        #expect(try progress("0") == 0)
        #expect(try progress("100") == 100)
        #expect(try progress("abc") == nil)
        #expect(try progress("4.5") == nil)
    }

    // MARK: - Title / msg

    @Test func base64RoundTripForTitleAndMsg() throws {
        let title = "Résumé — build ✓"
        let msg = "Line one\nLine two: with colon"
        let r = try #require(report("state=done:title=\(b64(title)):msg=\(b64(msg))"))
        #expect(r.title == title)
        #expect(r.msg == msg)
    }

    @Test func base64WithoutPaddingDecodes() throws {
        // "ab" encodes as "YWI=", sent unpadded.
        let r = try #require(report("state=done:title=YWI"))
        #expect(r.title == "ab")
    }

    @Test func badBase64DropsOnlyThatField() throws {
        let r = try #require(report("state=error:title=!!!not*base64:msg=\(b64("still here"))"))
        #expect(r.state == .error)
        #expect(r.title == nil)
        #expect(r.msg == "still here")
    }

    @Test func titleCapsAtBoundaryWithStraddlingMultibyte() throws {
        // 191 ASCII bytes + a 2-byte "é" = 193 bytes; the cap of 192 would cut
        // "é" in half, so it is dropped entirely.
        let title = String(repeating: "a", count: 191) + "é"
        let r = try #require(report("state=done:title=\(b64(title))"))
        #expect(r.title == String(repeating: "a", count: 191))
    }

    @Test func msgCapsAtBoundaryWithStraddlingMultibyte() throws {
        // 2047 ASCII bytes + a 3-byte "✓" = 2050 bytes, cap 2048.
        let msg = String(repeating: "b", count: 2047) + "✓"
        let r = try #require(report("state=done:msg=\(b64(msg))"))
        #expect(r.msg == String(repeating: "b", count: 2047))
    }

    @Test func textExactlyAtCapIsKept() throws {
        let title = String(repeating: "c", count: ProgramStatusProtocol.titleMaxBytes)
        let r = try #require(report("state=done:title=\(b64(title))"))
        #expect(r.title == title)
    }

    @Test func truncatedUTF8Helper() {
        let bytes = Array(("xy" + "é").utf8) // 4 bytes
        #expect(ProgramStatusParser.truncatedUTF8(bytes, maxBytes: 4) == "xyé")
        #expect(ProgramStatusParser.truncatedUTF8(bytes, maxBytes: 3) == "xy")
        #expect(ProgramStatusParser.truncatedUTF8(bytes, maxBytes: 2) == "xy")
        #expect(ProgramStatusParser.truncatedUTF8([0xFF, 0xFF], maxBytes: 10) == nil)
    }

    // MARK: - id

    private func id(_ value: String) throws -> String? {
        let r = try #require(report("state=working:id=\(value)"))
        return r.id
    }

    @Test func idIsSanitized() throws {
        #expect(try id("a b/c_d.e+f-g") == "abc_d.e+f-g")
        #expect(try id("/// ") == nil)
        #expect(try id("") == nil)
        let long = String(repeating: "z", count: 40)
        #expect(try id(long) == String(repeating: "z", count: 32))
    }

    // MARK: - Codable

    @Test func stateCodableRoundTrip() throws {
        let values: [ProgramStatusState] = [.working, .blocked, .done, .idle, .error, .clear, .unrecognized("later")]
        let data = try JSONEncoder().encode(values)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json == #"["working","blocked","done","idle","error","clear","later"]"#)
        let decoded = try JSONDecoder().decode([ProgramStatusState].self, from: data)
        #expect(decoded == values)
    }

    @Test func blockKindCodableRoundTrip() throws {
        let values: [ProgramStatusBlockKind] = [.permission, .question, .auth, .unrecognized("mfa")]
        let data = try JSONEncoder().encode(values)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json == #"["permission","question","auth","mfa"]"#)
        let decoded = try JSONDecoder().decode([ProgramStatusBlockKind].self, from: data)
        #expect(decoded == values)
    }

    // MARK: - Gate

    @Test func gateSetAndRead() {
        let gate = ProgramStatusGate()
        #expect(gate.isEnabled == false)
        gate.set(true)
        #expect(gate.isEnabled == true)
        gate.set(false)
        #expect(gate.isEnabled == false)
        #expect(ProgramStatusGate(enabled: true).isEnabled == true)
    }
}
