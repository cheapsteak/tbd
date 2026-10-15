import Foundation
import Testing
@testable import TBDShared

/// Claude Code's "don't ask again" suggestions, read as card lines and as the
/// session-scoped `updatedPermissions` that `allow_always` applies.
@Suite("PermissionSuggestionSummary")
struct PermissionSuggestionSummaryTests {

    @Test func addDirectoriesIsOneLinePerDirectory() {
        let json = #"[{"type":"addDirectories","directories":["/w","/x"],"destination":"session"}]"#
        #expect(PermissionSuggestionSummary.lines(fromJSON: json) == ["adds directory /w", "adds directory /x"])
    }

    @Test func setModeNamesTheMode() {
        let json = #"[{"type":"setMode","mode":"acceptEdits","destination":"session"}]"#
        #expect(PermissionSuggestionSummary.lines(fromJSON: json) == ["switches to acceptEdits"])
    }

    @Test func addRulesNamesTheRule() {
        let json = #"[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"touch:*"}],"behavior":"allow","destination":"localSettings"}]"#
        #expect(PermissionSuggestionSummary.lines(fromJSON: json) == ["allows Bash(touch:*)"])
    }

    @Test func aRuleWithoutContentNamesTheTool() {
        let json = #"[{"type":"addRules","rules":[{"toolName":"WebFetch"}],"behavior":"allow"}]"#
        #expect(PermissionSuggestionSummary.lines(fromJSON: json) == ["allows WebFetch"])
    }

    @Test func anUnknownTypeIsTheGenericLine() {
        let json = #"[{"type":"somethingNew","destination":"session"}]"#
        #expect(PermissionSuggestionSummary.lines(fromJSON: json) == ["changes a permission setting"])
    }

    @Test func linesKeepSuggestionOrder() {
        let json = #"[{"type":"addDirectories","directories":["/w"]},{"type":"setMode","mode":"acceptEdits"}]"#
        #expect(PermissionSuggestionSummary.lines(fromJSON: json) == ["adds directory /w", "switches to acceptEdits"])
    }

    @Test func nothingUsableIsNoLines() {
        #expect(PermissionSuggestionSummary.lines(fromJSON: nil).isEmpty)
        #expect(PermissionSuggestionSummary.lines(fromJSON: "[]").isEmpty)
        #expect(PermissionSuggestionSummary.lines(fromJSON: "not json").isEmpty)
        #expect(PermissionSuggestionSummary.lines(fromJSON: #"{"type":"setMode"}"#).isEmpty)
    }

    @Test func sessionScopedForcesTheDestination() throws {
        let json = #"[{"type":"addDirectories","directories":["/w"],"destination":"localSettings"},{"type":"setMode","mode":"acceptEdits"}]"#
        let scoped = try #require(PermissionSuggestionSummary.sessionScoped(fromJSON: json))
        #expect(scoped.count == 2)
        #expect(scoped.allSatisfy { $0["destination"] as? String == "session" })
        #expect(scoped[0]["directories"] as? [String] == ["/w"])
        #expect(scoped[1]["mode"] as? String == "acceptEdits")
    }

    @Test func sessionScopedIsNilWithoutSuggestions() {
        #expect(PermissionSuggestionSummary.sessionScoped(fromJSON: nil) == nil)
        #expect(PermissionSuggestionSummary.sessionScoped(fromJSON: "[]") == nil)
        #expect(PermissionSuggestionSummary.sessionScoped(fromJSON: "not json") == nil)
    }
}
