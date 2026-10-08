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
}
