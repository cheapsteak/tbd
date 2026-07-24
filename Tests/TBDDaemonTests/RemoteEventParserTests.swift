import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

// Tier 1: pure, deterministic, no I/O.
@Suite("RemoteEventParser")
struct RemoteEventParserTests {
    @Test func parsesAllEventTypes() throws {
        #expect(RemoteEventParser.parse(line: #"{"event": "hello", "contract_version": 1}"#)
                == .hello(contractVersion: 1))
        #expect(RemoteEventParser.parse(line: #"{"event": "ping"}"#) == .ping)
        #expect(RemoteEventParser.parse(line: #"{"event": "removed", "id": "x"}"#) == .removed(id: "x"))
        let snap = RemoteEventParser.parse(
            line: #"{"event": "snapshot", "sessions": [{"id": "a", "state": "running"}]}"#)
        guard case .snapshot(let sessions) = snap else { Issue.record("not a snapshot"); return }
        #expect(sessions.map(\.id) == ["a"])
        let sess = RemoteEventParser.parse(
            line: #"{"event": "session", "session": {"id": "b", "state": "exited"}}"#)
        guard case .session(let s) = sess else { Issue.record("not a session"); return }
        #expect(s.id == "b")
        #expect(s.state == .exited)
    }

    @Test func helloDefaultsContractVersionWhenAbsent() {
        #expect(RemoteEventParser.parse(line: #"{"event": "hello"}"#) == .hello(contractVersion: 1))
    }

    @Test func sessionAndRemovedWithoutRequiredFieldsAreSkipped() {
        // A `session` event missing its `session` object, or a `removed`
        // event missing `id`, is malformed — skip rather than crash.
        #expect(RemoteEventParser.parse(line: #"{"event": "session"}"#) == nil)
        #expect(RemoteEventParser.parse(line: #"{"event": "removed"}"#) == nil)
    }

    @Test func blankAndUnknownLinesAreSkipped() {
        #expect(RemoteEventParser.parse(line: "") == nil)
        #expect(RemoteEventParser.parse(line: "   ") == nil)
        #expect(RemoteEventParser.parse(line: #"{"event": "future_thing"}"#) == nil)
        #expect(RemoteEventParser.parse(line: "not json") == nil)
    }
}
