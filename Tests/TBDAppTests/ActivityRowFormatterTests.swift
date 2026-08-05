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

    @Test("Injected file body → 'file' badge + '<displayPath> · <original size>' title")
    func nestedMemoryTitleCarriesSourceAndSize() throws {
        // The size readout is the point: a collapsed row must show at a glance
        // how much context a 15-line Read actually pulled in. `truncatedTo`
        // holds the ORIGINAL length, so it wins over the capped `text`.
        let node = TranscriptRenderNode.makeSystemReminder(
            id: "m1", kind: .nestedMemory, text: "# acme rules (truncated)",
            source: ".github/CLAUDE.md", truncatedTo: 39_673)
        let p = try #require(ActivityRowFormatter.presentation(for: node))
        #expect(p.badges == [ActivityRowBadge(text: "file", kind: .neutral)])
        #expect(p.titleSegments.map(\.text).first == ".github/CLAUDE.md")
        // Magnitude, not just "has a suffix": 39,673 chars → "39.7K chars".
        #expect(titleText(p).contains("39.7K chars"), "got \(titleText(p))")
        #expect(!titleText(p).contains("\(("# acme rules (truncated)").count)"),
                "size must come from truncatedTo, not the capped text length")
        #expect(p.openTargetID == "m1")
    }

    @Test("Injected file path gets a hover tooltip carrying the untruncated path")
    func nestedMemoryTitleCarriesTooltip() throws {
        let node = TranscriptRenderNode.makeSystemReminder(
            id: "m2", kind: .nestedMemory, text: "# acme rules",
            source: "~/scratch/acme/very/deep/nesting/iam-pr-body.md")
        let p = try #require(ActivityRowFormatter.presentation(for: node))
        // Head truncation: the ellipsis eats the path PREFIX so the whole
        // filename survives. Middle truncation kept a short tail that cut into
        // the filename itself (`…pr-body.md` for `iam-pr-body.md`).
        #expect(p.titleTruncation == .byTruncatingHead)
        #expect(p.titleTooltip == "~/scratch/acme/very/deep/nesting/iam-pr-body.md")
    }

    @Test("Hook rows get no tooltip — a short hook name is fully visible")
    func hookRowHasNoTooltip() throws {
        let node = TranscriptRenderNode.makeSystemReminder(
            id: "h2", kind: .hookOutput, text: "injected", source: "PostToolUse:Read")
        let p = try #require(ActivityRowFormatter.presentation(for: node))
        #expect(p.titleTooltip == nil)
        // NOT head-truncated: the informative front of `PostToolUse:Read` is
        // exactly what head truncation would drop.
        #expect(p.titleTruncation == .byTruncatingMiddle)
    }

    @Test("Injected hook context → 'hook' badge + '<hookName> · <size>' title")
    func hookAdditionalContextTitleCarriesHookName() throws {
        let node = TranscriptRenderNode.makeSystemReminder(
            id: "h1", kind: .hookOutput, text: String(repeating: "x", count: 300),
            source: "PostToolUse:Read")
        let p = try #require(ActivityRowFormatter.presentation(for: node))
        #expect(p.badges == [ActivityRowBadge(text: "hook", kind: .neutral)])
        #expect(p.titleSegments.map(\.text).first == "PostToolUse:Read")
        // Untruncated: size falls back to the text length.
        #expect(titleText(p).contains("300 chars"), "got \(titleText(p))")
    }

    @Test("Injected size counts CHARACTERS, not bytes")
    func injectedSizeIsCharactersNotBytes() {
        // `truncatedTo` / `String.count` are grapheme clusters. Em-dashes are
        // 3 UTF-8 bytes each, so a byte formatter would have reported ~3x —
        // the unit label must match the number actually being counted.
        let emDashes = String(repeating: "—", count: 1500)
        #expect(emDashes.utf8.count == 4500)
        #expect(ActivityRowFormatter.injectedSize(text: emDashes, truncatedTo: nil) == "1.5K chars")
        #expect(ActivityRowFormatter.injectedSize(text: "abc", truncatedTo: nil) == "3 chars")
        #expect(ActivityRowFormatter.injectedSize(text: "short", truncatedTo: 44_312) == "44.3K chars")
    }

    @Test("Injected size rounding never rolls a mantissa past its own unit")
    func injectedSizeRoundingDoesNotRollPastItsUnit() {
        // K boundary: 999_950...999_999 round to a K-mantissa of 1000.0 and
        // must bump to M instead of printing "1000.0K chars".
        #expect(ActivityRowFormatter.injectedSize(text: "", truncatedTo: 999_949) == "999.9K chars")
        #expect(ActivityRowFormatter.injectedSize(text: "", truncatedTo: 999_950) == "1.0M chars")
        #expect(ActivityRowFormatter.injectedSize(text: "", truncatedTo: 999_999) == "1.0M chars")
        #expect(ActivityRowFormatter.injectedSize(text: "", truncatedTo: 1_000_000) == "1.0M chars")
        // M boundary equivalent (same shape, x1000): must bump to G instead
        // of printing "1000.0M chars".
        #expect(ActivityRowFormatter.injectedSize(text: "", truncatedTo: 999_949_000) == "999.9M chars")
        #expect(ActivityRowFormatter.injectedSize(text: "", truncatedTo: 999_950_000) == "1.0G chars")
        #expect(ActivityRowFormatter.injectedSize(text: "", truncatedTo: 999_999_950) == "1.0G chars")
        #expect(ActivityRowFormatter.injectedSize(text: "", truncatedTo: 1_000_000_000) == "1.0G chars")
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

    // MARK: Activity group summary badges

    private func groupNode(
        errorCount: Int = 0,
        pendingCount: Int = 0,
        requiresResponse: Bool = false,
        itemCount: Int = 3,
        bucketCounts: [ActivityBucket: Int] = [.read: 1, .bash: 2]
    ) -> TranscriptRenderNode {
        let summary = ActivityGroupSummary(
            id: "g1#activity-group",
            itemCount: itemCount,
            bucketCounts: bucketCounts,
            errorCount: errorCount,
            pendingCount: pendingCount,
            requiresResponse: requiresResponse,
            isExpanded: false
        )
        return TranscriptRenderNode(id: summary.id, kind: .activityGroupSummary(summary), badgeUsage: nil)
    }

    @Test("Activity group where everything succeeded carries NO badge")
    func activityGroupSucceededHasNoBadge() throws {
        let p = try #require(ActivityRowFormatter.presentation(for: groupNode()))
        #expect(p.badges.isEmpty)
        #expect(!p.isError)
        // …and the accessibility label drops the status clause entirely.
        #expect(p.accessibilityLabel == "Expand Read 1 file, ran 2 shell commands")
    }

    @Test("Activity group failures and questions still badge; running work does not")
    func activityGroupAttentionBadges() throws {
        let failed = try #require(ActivityRowFormatter.presentation(for: groupNode(errorCount: 2)))
        #expect(failed.badges == [ActivityRowBadge(text: "2 failed", kind: .error)])
        #expect(failed.isError)

        let asking = try #require(
            ActivityRowFormatter.presentation(for: groupNode(requiresResponse: true)))
        #expect(asking.badges == [ActivityRowBadge(text: "needs response", kind: .error)])

        // The old "active" capsule is gone: the phrase's tense carries it.
        let pending = try #require(ActivityRowFormatter.presentation(for: groupNode(pendingCount: 1)))
        #expect(pending.badges.isEmpty)
        #expect(!pending.isError)
        #expect(titleText(pending) == "Reading 1 file, running 2 shell commands…")
        #expect(pending.accessibilityLabel == "Expand Reading 1 file, running 2 shell commands…")
    }

    @Test("Activity group title is the whole phrase, in one secondary run")
    func activityGroupTitleIsThePhrase() throws {
        let p = try #require(ActivityRowFormatter.presentation(
            for: groupNode(itemCount: 2, bucketCounts: [.bash: 2])))
        #expect(p.titleSegments == [ActivityRowSegment(text: "Ran 2 shell commands", style: .secondary)])
    }

    @Test("Activity group summary is grayed down — never the primary label color")
    func activityGroupSummaryRecedes() throws {
        // The summary line is chrome between assistant prose; rendering it at
        // `.primary` (labelColor) made it compete with the prose around it.
        // `.secondary` keeps the subheadline size — it is greyed, not shrunk.
        for node in [groupNode(), groupNode(errorCount: 2), groupNode(pendingCount: 1)] {
            let p = try #require(ActivityRowFormatter.presentation(for: node))
            #expect(p.titleSegments.count == 1)
            #expect(p.titleSegments.allSatisfy { $0.style != .primary })
            #expect(p.titleSegments.allSatisfy { $0.style == .secondary })
        }
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

    @Test("WebFetch: globe icon, title carries the url, middle truncation + tooltip")
    func webFetch() throws {
        let node = TranscriptRenderNode.makeToolCall(
            id: "w1", name: "WebFetch",
            inputJSON: #"{"url":"https://example.com/docs/reference/Array/reduce","prompt":"summarize"}"#)
        let p = try #require(ActivityRowFormatter.presentation(for: node))
        #expect(p.iconSystemName == "globe")
        #expect(p.titleTruncation == .byTruncatingMiddle)
        let text = titleText(p)
        #expect(text.contains("WebFetch"))
        #expect(text.contains("https://example.com/docs/reference/Array/reduce"))
        #expect(p.titleTooltip == "https://example.com/docs/reference/Array/reduce")
        #expect(p.openTargetID == "w1")
    }

    @Test("WebSearch: title carries the query")
    func webSearch() throws {
        let node = TranscriptRenderNode.makeToolCall(
            id: "w2", name: "WebSearch",
            inputJSON: #"{"query":"hierarchical data tree structures"}"#)
        let p = try #require(ActivityRowFormatter.presentation(for: node))
        let text = titleText(p)
        #expect(text.contains("WebSearch"))
        #expect(text.contains("hierarchical data tree structures"))
        #expect(p.titleTooltip == "hierarchical data tree structures")
    }

    @Test("Web tool with a failed result surfaces the error badge")
    func webFetchError() throws {
        let node = TranscriptRenderNode.makeToolCall(
            id: "w3", name: "WebFetch", inputJSON: #"{"url":"https://example.com/gone"}"#,
            result: ToolResult(text: "404", truncatedTo: nil, isError: true))
        let p = try #require(ActivityRowFormatter.presentation(for: node))
        #expect(p.isError)
        #expect(p.badges.contains(ActivityRowBadge(text: "error", kind: .error)))
    }

    /// Malformed input must degrade to the bare label, never drop the row or
    /// render a dangling empty detail segment.
    @Test("Web tool with malformed input keeps the label and adds no target")
    func webMalformed() throws {
        let node = TranscriptRenderNode.makeToolCall(
            id: "w4", name: "WebFetch", inputJSON: "not-json")
        let p = try #require(ActivityRowFormatter.presentation(for: node))
        #expect(titleText(p) == "WebFetch")
        #expect(p.titleTooltip == nil)
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
