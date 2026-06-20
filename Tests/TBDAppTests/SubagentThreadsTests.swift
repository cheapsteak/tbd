import Foundation
import Testing
import TBDShared

@testable import TBDApp

@Suite("SubagentThreads")
struct SubagentThreadsTests {

    // MARK: - Fixtures

    /// A Task toolCall carrying a subagent with the given nested items.
    private func taskCall(
        id: String,
        description: String,
        agentType: String?,
        items: [TranscriptItem],
        isError: Bool = false
    ) -> TranscriptItem {
        .toolCall(
            id: id,
            name: "Task",
            inputJSON: "{\"description\":\"\(description)\",\"subagent_type\":\"\(agentType ?? "")\"}",
            inputTruncatedTo: nil,
            result: ToolResult(text: "done", truncatedTo: nil, isError: isError),
            subagent: Subagent(agentID: "agent-\(id)", agentType: agentType, items: items),
            timestamp: nil,
            usage: nil
        )
    }

    private func user(_ id: String, _ text: String = "hi") -> TranscriptItem {
        .userPrompt(id: id, text: text, timestamp: nil)
    }

    private func assistant(_ id: String, _ text: String = "ok") -> TranscriptItem {
        .assistantText(id: id, text: text, timestamp: nil, usage: nil)
    }

    // MARK: - sessionThreads

    @Test("zero subagents → empty thread list")
    func zeroSubagents() {
        let items = [user("u1"), assistant("a1")]
        #expect(sessionThreads(from: items).isEmpty)
        #expect(shouldShowThreadsColumn(items) == false)
    }

    @Test("N flat subagents → N rows in appearance order")
    func flatSubagents() {
        let items = [
            user("u1"),
            taskCall(id: "t1", description: "Angle A", agentType: "general-purpose",
                     items: [assistant("s1"), assistant("s2")]),
            assistant("a1"),
            taskCall(id: "t2", description: "Angle B", agentType: "Explore",
                     items: [assistant("s3")], isError: true),
        ]
        let threads = sessionThreads(from: items)
        #expect(threads.map(\.id) == ["t1", "t2"])
        #expect(threads[0].description == "Angle A")
        #expect(threads[0].agentType == "general-purpose")
        #expect(threads[0].itemCount == 2)
        #expect(threads[0].isError == false)
        #expect(threads[1].description == "Angle B")
        #expect(threads[1].agentType == "Explore")
        #expect(threads[1].isError == true)
        #expect(shouldShowThreadsColumn(items) == true)
    }

    @Test("depth-2 subagent → flat row for inner agent too")
    func nestedSubagent() {
        let inner = taskCall(id: "t1a", description: "Inner", agentType: "claude",
                             items: [assistant("s2")])
        let outer = taskCall(id: "t1", description: "Outer", agentType: "general-purpose",
                             items: [assistant("s1"), inner])
        let threads = sessionThreads(from: [user("u1"), outer])
        #expect(threads.map(\.id) == ["t1", "t1a"])
    }

    @Test("itemCount counts visible items only (hidden tools excluded)")
    func visibleCountOnly() {
        let hidden = TranscriptItem.toolCall(
            id: "h1", name: "TodoWrite", inputJSON: "{}", inputTruncatedTo: nil,
            result: nil, subagent: nil, timestamp: nil, usage: nil)
        let items = [taskCall(id: "t1", description: "X", agentType: nil,
                              items: [assistant("s1"), hidden])]
        #expect(sessionThreads(from: items)[0].itemCount == 1)
    }

    // MARK: - resolveThread

    @Test("empty path → root")
    func resolveEmpty() {
        let items = [user("u1"), assistant("a1")]
        #expect(resolveThread(root: items, path: []).map(\.id) == ["u1", "a1"])
    }

    @Test("[id] → that subagent's items")
    func resolveOne() {
        let items = [taskCall(id: "t1", description: "X", agentType: nil,
                              items: [assistant("s1"), assistant("s2")])]
        #expect(resolveThread(root: items, path: ["t1"]).map(\.id) == ["s1", "s2"])
    }

    @Test("nested path → deepest items")
    func resolveNested() {
        let inner = taskCall(id: "t1a", description: "I", agentType: nil,
                             items: [assistant("deep")])
        let outer = taskCall(id: "t1", description: "O", agentType: nil,
                             items: [inner])
        #expect(resolveThread(root: [outer], path: ["t1", "t1a"]).map(\.id) == ["deep"])
    }

    @Test("stale id → deepest resolvable prefix")
    func resolveStale() {
        let items = [taskCall(id: "t1", description: "X", agentType: nil,
                              items: [assistant("s1")])]
        // "nope" is unresolvable after t1 → stop at t1's items.
        #expect(resolveThread(root: items, path: ["t1", "nope"]).map(\.id) == ["s1"])
        // unresolvable first element → root.
        #expect(resolveThread(root: items, path: ["nope"]).map(\.id) == ["t1"])
    }

    // MARK: - threadLabel

    @Test("threadLabel returns deepest description, nil when empty")
    func labels() {
        let inner = taskCall(id: "t1a", description: "Inner", agentType: nil,
                             items: [assistant("d")])
        let outer = taskCall(id: "t1", description: "Outer", agentType: nil,
                             items: [inner])
        #expect(threadLabel(root: [outer], path: []) == nil)
        #expect(threadLabel(root: [outer], path: ["t1"]) == "Outer")
        #expect(threadLabel(root: [outer], path: ["t1", "t1a"]) == "Inner")
    }
}

@Suite("ThreadsColumnVisibility")
struct ThreadsColumnVisibilityTests {
    @Test("hidden with zero subagents, shown with ≥1")
    func gate() {
        let none: [TranscriptItem] = [.userPrompt(id: "u", text: "x", timestamp: nil)]
        #expect(shouldShowThreadsColumn(none) == false)

        let one: [TranscriptItem] = [.toolCall(
            id: "t1", name: "Task", inputJSON: "{\"description\":\"d\"}",
            inputTruncatedTo: nil, result: nil,
            subagent: Subagent(agentID: "a", agentType: nil,
                               items: [.assistantText(id: "s", text: "y", timestamp: nil, usage: nil)]),
            timestamp: nil, usage: nil)]
        #expect(shouldShowThreadsColumn(one) == true)
    }
}
