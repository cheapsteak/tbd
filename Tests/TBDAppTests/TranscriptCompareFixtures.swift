import Foundation
import TBDShared

/// Content fixtures for the env-gated old-vs-new visual comparison harness
/// (`TranscriptVisualCompareHarness`). Each `scenario` returns the SAME
/// `[TranscriptItem]` array fed to BOTH render paths so any visual delta comes
/// from the renderer, not the data. (#129)
///
/// Kept separate from `TranscriptRenderNodeFixtures` (which builds
/// `TranscriptRenderNode`s for document-layer unit tests) because these are
/// `TranscriptItem`s — the upstream input both the SwiftUI `TranscriptItemsView`
/// and the TextKit2 `transcriptRenderNodes(from:)` consume.
enum TranscriptCompareFixtures {

    /// All scenarios in the order they should be rendered/indexed.
    static let scenarioNames: [String] = [
        "prose", "codeblock", "table", "lists", "toolcards", "mixed"
    ]

    /// Returns the fixture items for a named scenario.
    static func items(for scenario: String) -> [TranscriptItem] {
        switch scenario {
        case "prose": return prose
        case "codeblock": return codeblock
        case "table": return table
        case "lists": return lists
        case "toolcards": return toolcards
        case "mixed": return mixed
        default: return []
        }
    }

    // MARK: - Scenarios

    /// User prompt + assistant markdown prose: heading, bold, italic, inline
    /// code, a link, and multiple paragraphs.
    static let prose: [TranscriptItem] = [
        .userPrompt(
            id: "prose-u1",
            text: "Can you explain how the transcript renderer works, in a couple of paragraphs?",
            timestamp: nil
        ),
        .assistantText(
            id: "prose-a1",
            text: """
            ## Transcript renderer overview

            The renderer turns a list of **transcript items** into a flat sequence \
            of render nodes. Each node is rendered _once_ and cached, so a re-poll \
            does not rebuild the whole list. Inline code like `transcriptRenderNodes(from:)` \
            is the single entry point.

            For long-form content the body flows as attributed text, while interactive \
            tool calls become embedded cards. See the [design doc](https://example.com/design) \
            for the full rationale and the trade-offs we accepted.

            A third paragraph to exercise vertical spacing and paragraph separation \
            between blocks of prose.
            """,
            timestamp: nil,
            usage: nil
        )
    ]

    /// Assistant message with a fenced Swift code block.
    static let codeblock: [TranscriptItem] = [
        .userPrompt(id: "code-u1", text: "Show me a small Swift snippet.", timestamp: nil),
        .assistantText(
            id: "code-a1",
            text: """
            Here is a minimal example:

            ```swift
            struct TranscriptRenderNode: Identifiable, Equatable {
                let id: String
                let kind: Kind

                static func == (lhs: Self, rhs: Self) -> Bool {
                    lhs.id == rhs.id && lhs.contentVersion == rhs.contentVersion
                }
            }
            ```

            The `==` is O(1) because it compares a precomputed content version.
            """,
            timestamp: nil,
            usage: nil
        )
    ]

    /// Assistant message containing a GFM table.
    static let table: [TranscriptItem] = [
        .userPrompt(id: "table-u1", text: "Compare the two render paths.", timestamp: nil),
        .assistantText(
            id: "table-a1",
            text: """
            Here is a quick comparison:

            | Aspect        | SwiftUI (old)      | TextKit2 (new)     |
            | ------------- | ------------------ | ------------------ |
            | Layout engine | LazyVStack         | NSTextLayoutManager|
            | Cards         | Native SwiftUI     | Attachment views   |
            | Selection     | Per-row NSTextField| Single text view   |
            | Streaming     | Diffed node array  | In-place storage   |

            Each approach has different performance characteristics under load.
            """,
            timestamp: nil,
            usage: nil
        )
    ]

    /// Assistant message with bullet + ordered lists and a blockquote.
    static let lists: [TranscriptItem] = [
        .userPrompt(id: "lists-u1", text: "Summarize the steps and caveats.", timestamp: nil),
        .assistantText(
            id: "lists-a1",
            text: """
            ### Steps

            1. Build the render nodes from items.
            2. Bind the document to the text storage.
            3. Force layout and place attachment views.

            Key points to remember:

            - Cards must not contain a direct `ScrollView`.
            - Hover state is per-row, never list-wide.
            - The badge is inlined, not a sibling node.

            > Note: a flat list under-represents the depth recursion seen in real
            > hover/activation spindumps, so micro-benchmarks are a lower bound.
            """,
            timestamp: nil,
            usage: nil
        )
    ]

    /// A sequence of tool calls: Bash, Read, Edit, Grep, Agent, AskUserQuestion —
    /// so the embedded cards (new) can be compared against the SwiftUI cards (old).
    static let toolcards: [TranscriptItem] = [
        .toolCall(
            id: "tc-bash",
            name: "Bash",
            inputJSON: #"{"command":"swift build 2>&1 | tail -5","description":"Build the package"}"#,
            inputTruncatedTo: nil,
            result: ToolResult(text: "Compiling TBDApp...\nBuild complete! (12.34s)", truncatedTo: nil, isError: false),
            subagent: nil,
            timestamp: nil,
            usage: nil
        ),
        .toolCall(
            id: "tc-read",
            name: "Read",
            inputJSON: #"{"file_path":"/Users/chang/tbd/Sources/TBDApp/AppState.swift"}"#,
            inputTruncatedTo: nil,
            result: ToolResult(text: "1\timport SwiftUI\n2\timport TBDShared\n3\t\n4\tfinal class AppState {}", truncatedTo: nil, isError: false),
            subagent: nil,
            timestamp: nil,
            usage: nil
        ),
        .toolCall(
            id: "tc-edit",
            name: "Edit",
            inputJSON: #"{"file_path":"/Users/chang/tbd/Sources/TBDApp/Foo.swift","old_string":"let x = 1","new_string":"let x = 2"}"#,
            inputTruncatedTo: nil,
            result: ToolResult(text: "The file has been updated.", truncatedTo: nil, isError: false),
            subagent: nil,
            timestamp: nil,
            usage: nil
        ),
        .toolCall(
            id: "tc-grep",
            name: "Grep",
            inputJSON: #"{"pattern":"transcriptRenderNodes","path":"Sources","output_mode":"files_with_matches"}"#,
            inputTruncatedTo: nil,
            result: ToolResult(text: "Sources/TBDApp/Panes/Transcript/TranscriptRenderNode.swift\nSources/TBDApp/Panes/Transcript/TranscriptItemsView.swift", truncatedTo: nil, isError: false),
            subagent: nil,
            timestamp: nil,
            usage: nil
        ),
        .toolCall(
            id: "tc-agent",
            name: "Agent",
            inputJSON: #"{"subagent_type":"general-purpose","description":"Investigate render paths","prompt":"Compare the two transcript renderers and report differences."}"#,
            inputTruncatedTo: nil,
            result: ToolResult(text: "Investigation complete. Both paths produce equivalent text but differ in card chrome.", truncatedTo: nil, isError: false),
            subagent: Subagent(
                agentID: "sub-1",
                agentType: "general-purpose",
                items: [
                    .assistantText(id: "sub-a1", text: "Looking at both renderers now.", timestamp: nil, usage: nil),
                    .toolCall(id: "sub-t1", name: "Read", inputJSON: #"{"file_path":"/tmp/x.swift"}"#, inputTruncatedTo: nil, result: nil, subagent: nil, timestamp: nil, usage: nil)
                ]
            ),
            timestamp: nil,
            usage: nil
        ),
        .toolCall(
            id: "tc-ask",
            name: "AskUserQuestion",
            inputJSON: #"{"questions":[{"question":"Which render path should we ship?","header":"Render path","options":[{"label":"SwiftUI","description":"The existing path"},{"label":"TextKit2","description":"The new path"}]}]}"#,
            inputTruncatedTo: nil,
            result: ToolResult(text: "User selected: TextKit2", truncatedTo: nil, isError: false),
            subagent: nil,
            timestamp: nil,
            usage: nil
        )
    ]

    /// A realistic multi-turn conversation combining prose, tool calls, and a
    /// summary.
    static let mixed: [TranscriptItem] = [
        .userPrompt(
            id: "mix-u1",
            text: "Find where the render nodes are built and add a comment explaining the badge logic.",
            timestamp: nil
        ),
        .assistantText(
            id: "mix-a1",
            text: """
            I'll start by locating the builder, then read it and make the edit.

            Here's my plan:

            1. Grep for the builder function.
            2. Read the surrounding code.
            3. Add a clarifying comment.
            """,
            timestamp: nil,
            usage: nil
        ),
        .toolCall(
            id: "mix-grep",
            name: "Grep",
            inputJSON: #"{"pattern":"func transcriptRenderNodes","output_mode":"content","-n":true}"#,
            inputTruncatedTo: nil,
            result: ToolResult(text: "TranscriptRenderNode.swift:106:nonisolated func transcriptRenderNodes(from items: [TranscriptItem])", truncatedTo: nil, isError: false),
            subagent: nil,
            timestamp: nil,
            usage: nil
        ),
        .toolCall(
            id: "mix-read",
            name: "Read",
            inputJSON: #"{"file_path":"/Users/chang/tbd/Sources/TBDApp/Panes/Transcript/TranscriptRenderNode.swift","offset":106,"limit":20}"#,
            inputTruncatedTo: nil,
            result: ToolResult(text: "106\tnonisolated func transcriptRenderNodes(...)\n107\t  // Find latest usage-carrying item for the badge", truncatedTo: nil, isError: false),
            subagent: nil,
            timestamp: nil,
            usage: nil
        ),
        .toolCall(
            id: "mix-edit",
            name: "Edit",
            inputJSON: #"{"file_path":"/Users/chang/tbd/Sources/TBDApp/Panes/Transcript/TranscriptRenderNode.swift","old_string":"let badge","new_string":"// Badge attaches to the latest visible usage item\n        let badge"}"#,
            inputTruncatedTo: nil,
            result: ToolResult(text: "The file has been updated.", truncatedTo: nil, isError: false),
            subagent: nil,
            timestamp: nil,
            usage: nil
        ),
        .assistantText(
            id: "mix-a2",
            text: """
            **Done.** I added a comment above the `badge` binding in \
            `transcriptRenderNodes(from:)` explaining that the badge attaches to the \
            most-recent *visible* usage-carrying item. The change is a comment only, \
            so behavior is unchanged.
            """,
            timestamp: nil,
            usage: TokenUsage(inputTokens: 1200, cacheCreationTokens: 800, cacheReadTokens: 14_000)
        )
    ]
}
