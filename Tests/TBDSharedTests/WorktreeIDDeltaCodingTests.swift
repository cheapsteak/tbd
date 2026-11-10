import Foundation
import Testing
import TBDShared

/// `WorktreeIDDelta` decodes payloads from daemons that predate each optional
/// field, and round-trips the fields when present.
@Suite("WorktreeIDDelta coding")
struct WorktreeIDDeltaCodingTests {
    private let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!

    @Test func aPayloadWithOnlyTheIDDecodes() throws {
        let json = Data(#"{"worktreeID":"12345678-1234-1234-1234-123456789ABC"}"#.utf8)
        let delta = try JSONDecoder().decode(WorktreeIDDelta.self, from: json)
        #expect(delta.worktreeID == id)
        #expect(delta.creationFailed == false)
        #expect(delta.unsentPromptPath == nil)
        #expect(delta.unsentPromptLost == false)
        #expect(delta.failureReason == nil)
    }

    @Test func unsentPromptLostRoundTrips() throws {
        let original = WorktreeIDDelta(worktreeID: id, creationFailed: true, unsentPromptLost: true)
        let decoded = try JSONDecoder().decode(
            WorktreeIDDelta.self, from: try JSONEncoder().encode(original))
        #expect(decoded.unsentPromptLost)
        #expect(decoded.unsentPromptPath == nil)
    }

    @Test func aPayloadWithoutTheUnsentPromptPathDecodes() throws {
        let json = Data(#"{"worktreeID":"12345678-1234-1234-1234-123456789ABC","creationFailed":true}"#.utf8)
        let delta = try JSONDecoder().decode(WorktreeIDDelta.self, from: json)
        #expect(delta.creationFailed)
        #expect(delta.unsentPromptPath == nil)
    }

    @Test func theUnsentPromptPathRoundTrips() throws {
        let original = WorktreeIDDelta(
            worktreeID: id, creationFailed: true, unsentPromptPath: "/tmp/x/unsent-prompts/a.md")
        let decoded = try JSONDecoder().decode(
            WorktreeIDDelta.self, from: try JSONEncoder().encode(original))
        #expect(decoded.worktreeID == id)
        #expect(decoded.creationFailed)
        #expect(decoded.unsentPromptPath == "/tmp/x/unsent-prompts/a.md")
    }

    /// The reason a failed creation carries reaches the app intact, newlines
    /// included: git's verdict is several lines.
    @Test func theFailureReasonRoundTrips() throws {
        let reason = "git worktree add failed — the disk is full; free space and try again\n"
            + "Details: fatal: Could not reset index file to revision 'HEAD'."
        let original = WorktreeIDDelta(worktreeID: id, creationFailed: true, failureReason: reason)
        let decoded = try JSONDecoder().decode(
            WorktreeIDDelta.self, from: try JSONEncoder().encode(original))
        #expect(decoded.creationFailed)
        #expect(decoded.failureReason == reason)
    }

    /// An older daemon's failure delta has no `failureReason` key; it decodes
    /// as nil, which the app reads as "no reason given".
    @Test func aFailurePayloadWithoutTheReasonDecodesAsNil() throws {
        let json = Data(#"{"worktreeID":"12345678-1234-1234-1234-123456789ABC","creationFailed":true}"#.utf8)
        let delta = try JSONDecoder().decode(WorktreeIDDelta.self, from: json)
        #expect(delta.creationFailed)
        #expect(delta.failureReason == nil)
    }

    /// A delta with no reason leaves the key out rather than sending null, so
    /// the payload an older app sees is unchanged.
    @Test func aNilReasonIsNotEncoded() throws {
        let data = try JSONEncoder().encode(WorktreeIDDelta(worktreeID: id, creationFailed: true))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(!object.keys.contains("failureReason"))
    }
}
