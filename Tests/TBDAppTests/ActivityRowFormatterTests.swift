import AppKit
import Testing
import TBDShared
@testable import TBDApp

/// Verifies `ActivityRowFormatter.presentation(for:)` ports each SwiftUI card's
/// header (icon + title segments + badges + open/navigate target + truncation)
/// exactly, and returns nil for the kinds that stay SwiftUI-hosted. (#129)
@MainActor
@Suite("Activity row formatter")
struct ActivityRowFormatterTests {
    private func titleText(_ p: ActivityRowPresentation) -> String {
        p.titleSegments.map(\.text).joined(separator: " ")
    }

    @Test("chat bubble has no native presentation (stays the native bubble cell)")
    func chatBubbleNil() {
        let node = TranscriptRenderNode.makeAssistantText(id: "a1", text: "hello")
        #expect(ActivityRowFormatter.presentation(for: node) == nil)
    }

    @Test("AskUserQuestion has no native presentation (stays SwiftUI-hosted)")
    func askUserQuestionNil() {
        let node = TranscriptRenderNode.makeToolCall(
            id: "q1", name: "AskUserQuestion", inputJSON: #"{"questions":[]}"#)
        #expect(ActivityRowFormatter.presentation(for: node) == nil)
    }

    @Test("Read: doc.text icon, title carries label + path, middle truncation")
    func read() throws {
        let node = TranscriptRenderNode.makeToolCall(
            id: "r1", name: "Read",
            inputJSON: #"{"file_path":"/Users/x/Sources/Foo.swift","offset":10,"limit":5}"#)
        let p = try #require(ActivityRowFormatter.presentation(for: node))
        #expect(p.iconSystemName == "doc.text")
        #expect(p.titleTruncation == .byTruncatingMiddle)
        let text = titleText(p)
        #expect(text.contains("Read"))
        #expect(text.contains("/Users/x/Sources/Foo.swift"))
        #expect(text.contains("lines 10–14"))
        #expect(p.openTargetID == "r1")
    }

    @Test("Bash with failing result: terminal icon + error badge text 'failed'")
    func bashFailed() throws {
        let node = TranscriptRenderNode.makeToolCall(
            id: "b1", name: "Bash", inputJSON: #"{"command":"exit 1"}"#,
            result: ToolResult(text: "boom", truncatedTo: nil, isError: true))
        let p = try #require(ActivityRowFormatter.presentation(for: node))
        #expect(p.iconSystemName == "terminal")
        #expect(p.isError)
        #expect(p.badges == [ActivityRowBadge(text: "failed", kind: .error)])
    }

    @Test("Edit with all replace_all → neutral 'all' badge")
    func editAllReplace() throws {
        let node = TranscriptRenderNode.makeToolCall(
            id: "e1", name: "MultiEdit",
            inputJSON: #"{"file_path":"/a.swift","edits":[{"old_string":"a","new_string":"b","replace_all":true}]}"#)
        let p = try #require(ActivityRowFormatter.presentation(for: node))
        #expect(p.iconSystemName == "pencil")
        #expect(p.badges.contains(ActivityRowBadge(text: "all", kind: .neutral)))
    }

    @Test("Edit with error result → error 'error' badge")
    func editError() throws {
        let node = TranscriptRenderNode.makeToolCall(
            id: "e2", name: "Edit",
            inputJSON: #"{"file_path":"/a.swift","old_string":"a","new_string":"b"}"#,
            result: ToolResult(text: "no match", truncatedTo: nil, isError: true))
        let p = try #require(ActivityRowFormatter.presentation(for: node))
        #expect(p.badges.contains(ActivityRowBadge(text: "error", kind: .error)))
    }

    @Test("Grep: magnifyingglass icon + monospace pattern segment")
    func grep() throws {
        let node = TranscriptRenderNode.makeToolCall(
            id: "g1", name: "Grep", inputJSON: #"{"pattern":"TODO","path":"Sources"}"#)
        let p = try #require(ActivityRowFormatter.presentation(for: node))
        #expect(p.iconSystemName == "magnifyingglass")
        #expect(p.titleSegments.contains(ActivityRowSegment(text: "TODO", style: .monospace)))
        #expect(titleText(p).contains("in Sources"))
    }

    @Test("Agent/Task: sparkles icon + opens the overlay like any other tool card")
    func agent() throws {
        let node = TranscriptRenderNode.makeToolCall(
            id: "t1", name: "Task",
            inputJSON: #"{"description":"Investigate","subagent_type":"Explore"}"#)
        let p = try #require(ActivityRowFormatter.presentation(for: node))
        #expect(p.iconSystemName == "sparkles")
        // Subagent drill-in was removed: Agent/Task rows open the standard
        // overlay (input + result), not a nested thread.
        #expect(p.openTargetID == "t1")
        #expect(titleText(p).contains("Investigate"))
    }

    @Test("Generic mcp tool → 'mcp · foo · bar' title")
    func genericMCP() throws {
        let node = TranscriptRenderNode.makeToolCall(
            id: "m1", name: "mcp__foo__bar", inputJSON: "{}")
        let p = try #require(ActivityRowFormatter.presentation(for: node))
        #expect(p.iconSystemName == "wrench.and.screwdriver")
        #expect(titleText(p) == "mcp · foo · bar")
    }

    @Test("System reminder (.hookOutput) → info.circle + neutral 'hook' badge")
    func systemReminderHook() throws {
        let node = TranscriptRenderNode.makeSystemReminder(
            id: "s1", kind: .hookOutput, text: "hook fired")
        let p = try #require(ActivityRowFormatter.presentation(for: node))
        #expect(p.iconSystemName == "info.circle")
        #expect(p.titleSegments.isEmpty)
        #expect(p.badges == [ActivityRowBadge(text: "hook", kind: .neutral)])
        #expect(p.openTargetID == "s1")
    }

    @Test("Task notification → clock icon, 'Background · <summary>' title, status badge")
    func taskNotification() throws {
        let node = TranscriptRenderNode.makeSystemReminder(
            id: "t1", kind: .taskNotification,
            text: "<task-notification>\n<status>completed</status>\n<summary>Agent \"X\" came to rest</summary>\n</task-notification>")
        let p = try #require(ActivityRowFormatter.presentation(for: node))
        #expect(p.iconSystemName == "clock.arrow.circlepath")
        #expect(titleText(p).contains("Background"))
        #expect(titleText(p).contains("Agent \"X\" came to rest"))
        #expect(p.badges == [ActivityRowBadge(text: "completed", kind: .neutral)])
        #expect(p.openTargetID == "t1")
        #expect(p.titleTruncation == .byTruncatingTail)
    }

    @Test("Task notification with no <summary> → falls back to status text")
    func taskNotificationFallbackToStatus() throws {
        let node = TranscriptRenderNode.makeSystemReminder(
            id: "t2", kind: .taskNotification,
            text: "<task-notification>\n<status>running</status>\n</task-notification>")
        let p = try #require(ActivityRowFormatter.presentation(for: node))
        #expect(titleText(p).contains("running"))
        #expect(p.badges == [ActivityRowBadge(text: "running", kind: .neutral)])
    }

    @Test("Task notification with no summary or status → 'Background task', no badge")
    func taskNotificationFallbackToDefault() throws {
        let node = TranscriptRenderNode.makeSystemReminder(
            id: "t3", kind: .taskNotification,
            text: "<task-notification>\n<task-id>abc</task-id>\n</task-notification>")
        let p = try #require(ActivityRowFormatter.presentation(for: node))
        #expect(titleText(p).contains("Background task"))
        #expect(p.badges.isEmpty)
    }

    @Test("Task notification with failing status → error badge kind")
    func taskNotificationErrorBadge() throws {
        let node = TranscriptRenderNode.makeSystemReminder(
            id: "t4", kind: .taskNotification,
            text: "<task-notification>\n<status>failed</status>\n<summary>boom</summary>\n</task-notification>")
        let p = try #require(ActivityRowFormatter.presentation(for: node))
        #expect(p.badges == [ActivityRowBadge(text: "failed", kind: .error)])
    }

    @Test("Skill body → 'Skill' + skill-name segments")
    func skillBody() throws {
        let node = TranscriptRenderNode.makeSkillBody(
            id: "k1",
            text: "Base directory for this skill: /Users/x/.claude/skills/my-skill\nbody")
        let p = try #require(ActivityRowFormatter.presentation(for: node))
        #expect(p.iconSystemName == "sparkles")
        let texts = p.titleSegments.map(\.text)
        #expect(texts.contains("Skill"))
        #expect(texts.contains("my-skill"))
        #expect(p.openTargetID == "k1")
    }

    @Test("Subagent summary → person.2 icon, plain style, no targets, no timestamp")
    func subagentSummary() throws {
        let node = TranscriptRenderNode.makeSubagentSummary(id: "p1#subagent", count: 3, agentType: "Explore")
        let p = try #require(ActivityRowFormatter.presentation(for: node))
        #expect(p.iconSystemName == "person.2")
        #expect(p.style == .plainSummary)
        #expect(p.openTargetID == nil)
        #expect(p.timestamp == nil)
        #expect(titleText(p) == "3 subagent activities · Explore")
    }
}
