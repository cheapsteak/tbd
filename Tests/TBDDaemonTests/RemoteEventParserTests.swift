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
        guard case .snapshot(let sessions, let complete) = snap else {
            Issue.record("not a snapshot"); return
        }
        #expect(sessions.map(\.id) == ["a"])
        #expect(complete, "an absent `complete` on a snapshot event reads as true")
        let sess = RemoteEventParser.parse(
            line: #"{"event": "session", "session": {"id": "b", "state": "exited"}}"#)
        guard case .session(let s) = sess else { Issue.record("not a session"); return }
        #expect(s.id == "b")
        #expect(s.state == .exited)
    }

    /// A `snapshot` line is a whole inventory, so one malformed session in it
    /// must cost one session — not the line, which would leave every remote
    /// row frozen at whatever it last said.
    @Test func aSnapshotSurvivesOneUndecodableSession() throws {
        let line = #"""
        {"event": "snapshot", "sessions": [
          {"id": "a", "state": "running"},
          {"id": "bad", "state": "running", "exit_code": "not-a-number"},
          {"id": "c", "state": "running", "meta": {"detail": {"nested": "object"}}}]}
        """#
        let event = RemoteEventParser.parse(line: line.replacingOccurrences(of: "\n", with: " "))
        guard case .snapshot(let sessions, _) = event else {
            Issue.record("not a snapshot: \(String(describing: event))")
            return
        }
        #expect(sessions.map(\.id) == ["a", "c"])
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

    /// The contract states `complete` on the events snapshot with exactly the
    /// meaning and the caller rules it has on `list`, so the parser must not
    /// silently drop it — a caller that only honored the `list` half would let
    /// an events-capable partial provider retire its own live sessions.
    @Test func theSnapshotEventCarriesCompleteness() {
        #expect(
            RemoteEventParser.parse(line: #"{"event": "snapshot", "complete": false, "sessions": []}"#)
                == .snapshot([], complete: false))
        #expect(
            RemoteEventParser.parse(line: #"{"event": "snapshot", "complete": true, "sessions": []}"#)
                == .snapshot([], complete: true))
        #expect(
            RemoteEventParser.parse(line: #"{"event": "snapshot", "sessions": []}"#)
                == .snapshot([], complete: true))
    }
}
