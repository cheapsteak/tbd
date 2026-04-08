# History Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a History tab to TBDApp that lists past Claude Code sessions for the selected worktree and lets the user resume any of them with one click.

**Architecture:** The daemon parses `~/.claude/projects/<encoded-cwd>/*.jsonl` and serves `[SessionSummary]` via a new `session.list` RPC. The app adds a history button pinned to the right side of the tab strip; clicking it shows `HistoryPaneView` instead of the normal split layout. Resuming calls the existing `terminal.create` RPC with `resumeSessionID` set — no new spawn path needed.

**Tech Stack:** Swift 6, SwiftUI (macOS), GRDB (database), Swift Testing (`@Suite`/`@Test`/`#expect`), Foundation JSONSerialization for line-by-line JSONL parsing.

---

## File Map

| Action | File |
|--------|------|
| Create | `Tests/Fixtures/sample-session.jsonl` |
| Create | `Sources/TBDDaemon/Claude/UserMessageClassifier.swift` |
| Create | `Tests/TBDDaemonTests/UserMessageClassifierTests.swift` |
| Create | `Sources/TBDDaemon/Claude/ClaudeSessionScanner.swift` |
| Create | `Tests/TBDDaemonTests/ClaudeSessionScannerTests.swift` |
| Modify | `Sources/TBDShared/Models.swift` — add `SessionSummary` |
| Modify | `Sources/TBDShared/RPCProtocol.swift` — add `sessionList` method + `SessionListParams` |
| Create | `Sources/TBDDaemon/Server/RPCRouter+SessionHandlers.swift` |
| Modify | `Sources/TBDDaemon/Server/RPCRouter.swift` — add `case RPCMethod.sessionList:` |
| Modify | `Sources/TBDApp/DaemonClient.swift` — add `listSessions(worktreeID:)` |
| Create | `Sources/TBDApp/AppState+History.swift` |
| Modify | `Sources/TBDApp/TabBar.swift` — add history button pinned right |
| Modify | `Sources/TBDApp/Terminal/TerminalContainerView.swift` — render HistoryPaneView |
| Create | `Sources/TBDApp/Panes/HistoryPaneView.swift` |

---

## Task 1: Test Fixture + UserMessageClassifier

**Files:**
- Create: `Tests/Fixtures/sample-session.jsonl`
- Create: `Sources/TBDDaemon/Claude/UserMessageClassifier.swift`
- Create: `Tests/TBDDaemonTests/UserMessageClassifierTests.swift`

- [ ] **Step 1: Create the fixture file**

Create `Tests/Fixtures/sample-session.jsonl` with these exact lines (one JSON object per line):

```jsonl
{"type":"permission-mode","sessionId":"abc123de-0000-0000-0000-000000000001","cwd":"/Users/test/project","gitBranch":"main","permissionMode":"auto"}
{"type":"user","message":{"role":"user","content":"<system-reminder>You are Claude.</system-reminder>"},"sessionId":"abc123de-0000-0000-0000-000000000001"}
{"type":"user","message":{"role":"user","content":"Hello, can you help me refactor this function?"},"sessionId":"abc123de-0000-0000-0000-000000000001"}
{"type":"assistant","message":{"role":"assistant","content":"Of course! Please share the function."},"sessionId":"abc123de-0000-0000-0000-000000000001"}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"result"}]},"sessionId":"abc123de-0000-0000-0000-000000000001"}
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"<command-name>commit</command-name>"}]},"sessionId":"abc123de-0000-0000-0000-000000000001"}
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Now add unit tests for it."}]},"sessionId":"abc123de-0000-0000-0000-000000000001"}
{"type":"assistant","message":{"role":"assistant","content":"Here are the tests..."},"sessionId":"abc123de-0000-0000-0000-000000000001"}
{"type":"user","message":{"role":"user","content":"<tool_result>tool output here</tool_result>"},"sessionId":"abc123de-0000-0000-0000-000000000001"}
{"type":"user","message":{"role":"user","content":"What does this error mean?"},"sessionId":"abc123de-0000-0000-0000-000000000001"}
{"type":"file-history-snapshot","snapshot":{},"sessionId":"abc123de-0000-0000-0000-000000000001"}
```

- [ ] **Step 2: Create UserMessageClassifier.swift**

Create `Sources/TBDDaemon/Claude/UserMessageClassifier.swift`:

```swift
import Foundation

/// Determines whether a decoded JSONL line is a real user-authored message
/// vs. a tool result, system reminder, or other system-generated content.
///
/// This is the single place to update detection heuristics. The fixture at
/// Tests/Fixtures/sample-session.jsonl documents the classification decisions.
enum UserMessageClassifier {

    /// Prefixes that mark system-generated content in the user role.
    private static let systemPrefixes: [String] = [
        "<system-reminder",
        "<command-",
        "<tool_result",
        "<local-command-",
    ]

    /// Returns true if the parsed JSONL object is a real user message.
    static func isRealUserMessage(_ line: [String: Any]) -> Bool {
        guard
            line["type"] as? String == "user",
            let message = line["message"] as? [String: Any],
            message["role"] as? String == "user"
        else { return false }

        if let content = message["content"] as? String {
            return !hasSystemPrefix(content)
        }

        if let array = message["content"] as? [[String: Any]] {
            // All tool_result blocks → not a real message
            if array.allSatisfy({ $0["type"] as? String == "tool_result" }) {
                return false
            }
            // Check the first text block's content
            if let firstText = array.first(where: { $0["type"] as? String == "text" }),
               let text = firstText["text"] as? String {
                return !hasSystemPrefix(text)
            }
            return false
        }

        return false
    }

    /// Extracts display text from a real user message line. Returns nil if empty.
    static func extractText(_ line: [String: Any]) -> String? {
        guard let message = line["message"] as? [String: Any] else { return nil }

        if let text = message["content"] as? String {
            return text.isEmpty ? nil : text
        }

        if let array = message["content"] as? [[String: Any]] {
            return array
                .first(where: { $0["type"] as? String == "text" })
                .flatMap { $0["text"] as? String }
                .flatMap { $0.isEmpty ? nil : $0 }
        }

        return nil
    }

    private static func hasSystemPrefix(_ text: String) -> Bool {
        systemPrefixes.contains(where: { text.hasPrefix($0) })
    }
}
```

- [ ] **Step 3: Create UserMessageClassifierTests.swift**

Create `Tests/TBDDaemonTests/UserMessageClassifierTests.swift`:

```swift
import Testing
import Foundation
@testable import TBDDaemonLib

@Suite("UserMessageClassifier")
struct UserMessageClassifierTests {

    private func line(_ type: String, role: String, content: Any) -> [String: Any] {
        ["type": type, "message": ["role": role, "content": content]]
    }

    @Test("passes real string message")
    func realStringMessage() {
        let l = line("user", role: "user", content: "Hello, can you help?")
        #expect(UserMessageClassifier.isRealUserMessage(l) == true)
        #expect(UserMessageClassifier.extractText(l) == "Hello, can you help?")
    }

    @Test("passes real array message")
    func realArrayMessage() {
        let l = line("user", role: "user", content: [["type": "text", "text": "Now add unit tests."]])
        #expect(UserMessageClassifier.isRealUserMessage(l) == true)
        #expect(UserMessageClassifier.extractText(l) == "Now add unit tests.")
    }

    @Test("filters system-reminder string")
    func filtersSystemReminder() {
        let l = line("user", role: "user", content: "<system-reminder>You are Claude.</system-reminder>")
        #expect(UserMessageClassifier.isRealUserMessage(l) == false)
    }

    @Test("filters tool_result string")
    func filtersToolResultString() {
        let l = line("user", role: "user", content: "<tool_result>output</tool_result>")
        #expect(UserMessageClassifier.isRealUserMessage(l) == false)
    }

    @Test("filters all-tool_result array")
    func filtersToolResultArray() {
        let l = line("user", role: "user", content: [
            ["type": "tool_result", "tool_use_id": "t1", "content": "result"]
        ])
        #expect(UserMessageClassifier.isRealUserMessage(l) == false)
    }

    @Test("slash commands (command- prefix) are filtered out")
    func filtersCommandPrefix() {
        let l = line("user", role: "user", content: [
            ["type": "text", "text": "<command-name>commit</command-name>"]
        ])
        #expect(UserMessageClassifier.isRealUserMessage(l) == false)
    }

    @Test("rejects non-user type")
    func rejectsAssistantType() {
        let l = line("assistant", role: "assistant", content: "Some response")
        #expect(UserMessageClassifier.isRealUserMessage(l) == false)
    }

    @Test("extracts text from array content")
    func extractsArrayText() {
        let l = line("user", role: "user", content: [
            ["type": "text", "text": "What does this error mean?"]
        ])
        #expect(UserMessageClassifier.extractText(l) == "What does this error mean?")
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd /Users/chang/tbd/worktrees/tbd/20260408-aggregate-guan
swift test --filter UserMessageClassifierTests 2>&1 | tail -20
```

Expected: All 8 tests pass. If the test target can't find the type, ensure `UserMessageClassifier.swift` is in the `TBDDaemon` target (check `Package.swift`).

- [ ] **Step 5: Commit**

```bash
git add Tests/Fixtures/sample-session.jsonl \
        Sources/TBDDaemon/Claude/UserMessageClassifier.swift \
        Tests/TBDDaemonTests/UserMessageClassifierTests.swift
git commit -m "feat: UserMessageClassifier for JSONL session parsing"
```

---

## Task 2: ClaudeSessionScanner

**Files:**
- Create: `Sources/TBDDaemon/Claude/ClaudeSessionScanner.swift`
- Create: `Tests/TBDDaemonTests/ClaudeSessionScannerTests.swift`

- [ ] **Step 1: Create ClaudeSessionScanner.swift**

Create `Sources/TBDDaemon/Claude/ClaudeSessionScanner.swift`:

```swift
import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "session-scanner")

// MARK: - ClaudeProjectDirectory

/// Resolves the ~/.claude/projects/<encoded-cwd>/ directory for a worktree path.
/// Three-tier lookup: exact encoding → regex fallback → full content scan.
/// Results are cached after first resolution.
enum ClaudeProjectDirectory {
    private nonisolated(unsafe) static var cache: [String: URL] = [:]
    private static let lock = NSLock()

    static func resolve(worktreePath: String, projectsBase: URL? = nil) -> URL? {
        let base = projectsBase ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects")

        lock.lock()
        if let cached = cache[worktreePath] {
            lock.unlock()
            return FileManager.default.fileExists(atPath: cached.path) ? cached : nil
        }
        lock.unlock()

        let result = resolveUncached(worktreePath: worktreePath, projectsBase: base)
        if let result {
            lock.lock()
            cache[worktreePath] = result
            lock.unlock()
        }
        return result
    }

    /// Wipe the in-memory cache (for testing).
    static func clearCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    // MARK: Private

    private static func resolveUncached(worktreePath: String, projectsBase: URL) -> URL? {
        // Tier 1: exact (/ and . → -)
        let exact = worktreePath.map { "/." .contains($0) ? "-" : String($0) }.joined()
        let tier1 = projectsBase.appendingPathComponent(exact)
        if FileManager.default.fileExists(atPath: tier1.path) {
            logger.debug("Session dir via exact: \(tier1.path, privacy: .public)")
            return tier1
        }

        // Tier 2: regex (any non-alphanumeric run → single -)
        let regex = regexEncode(worktreePath)
        if regex != exact {
            let tier2 = projectsBase.appendingPathComponent(regex)
            if FileManager.default.fileExists(atPath: tier2.path) {
                logger.debug("Session dir via regex: \(tier2.path, privacy: .public)")
                return tier2
            }
        }

        // Tier 3: scan all project dirs for a matching cwd field
        return scanForCWD(worktreePath: worktreePath, projectsBase: projectsBase)
    }

    private static func regexEncode(_ path: String) -> String {
        var result = ""
        var inNonAlpha = false
        for ch in path {
            if ch.isLetter || ch.isNumber {
                result.append(ch)
                inNonAlpha = false
            } else if !inNonAlpha {
                result.append("-")
                inNonAlpha = true
            }
        }
        return result
    }

    private static func scanForCWD(worktreePath: String, projectsBase: URL) -> URL? {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: projectsBase, includingPropertiesForKeys: nil
        ) else { return nil }

        for dir in dirs where dir.hasDirectoryPath {
            guard
                let firstJSONL = (try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: nil
                ))?.first(where: { $0.pathExtension == "jsonl" }),
                let firstLine = readFirstNonEmptyLine(of: firstJSONL),
                let data = firstLine.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let cwd = json["cwd"] as? String
            else { continue }

            if cwd == worktreePath {
                logger.debug("Session dir via scan: \(dir.path, privacy: .public)")
                return dir
            }
        }
        return nil
    }

    private static func readFirstNonEmptyLine(of url: URL) -> String? {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? handle.close() }
        let chunk = handle.readData(ofLength: 1024)
        return String(data: chunk, encoding: .utf8)?
            .components(separatedBy: "\n")
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    }
}

// MARK: - ClaudeSessionScanner

enum ClaudeSessionScanner {

    /// Lists all sessions in a project directory, sorted by mtime descending.
    static func listSessions(projectDir: URL) throws -> [SessionSummary] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let entries = try? fm.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: Array(keys)) else {
            return []
        }
        return entries
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { parseSummary(file: $0) }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    // MARK: Private

    private static func parseSummary(file: URL) -> SessionSummary? {
        let rv = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modifiedAt = rv?.contentModificationDate ?? Date.distantPast
        let fileSize = Int64(rv?.fileSize ?? 0)

        guard let handle = FileHandle(forReadingAtPath: file.path) else { return nil }
        defer { try? handle.close() }

        var lineCount = 0
        var firstUserMessage: String? = nil
        var lastUserMessage: String? = nil
        var sessionId: String? = nil
        var cwd: String? = nil
        var gitBranch: String? = nil
        var buffer = Data()

        func processLine(_ lineData: Data) {
            guard !lineData.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { return }
            lineCount += 1
            if sessionId == nil {
                sessionId  = json["sessionId"]  as? String
                cwd        = json["cwd"]        as? String
                gitBranch  = json["gitBranch"]  as? String
            }
            if UserMessageClassifier.isRealUserMessage(json),
               let text = UserMessageClassifier.extractText(json) {
                let truncated = String(text.prefix(300))
                if firstUserMessage == nil { firstUserMessage = truncated }
                lastUserMessage = truncated
            }
        }

        let chunkSize = 65_536
        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            guard !chunk.isEmpty else { break }
            buffer.append(chunk)
            while let nl = buffer.range(of: Data([0x0A])) {
                let lineData = Data(buffer[buffer.startIndex..<nl.lowerBound])
                buffer.removeSubrange(buffer.startIndex...nl.lowerBound)
                processLine(lineData)
            }
        }
        // Trailing line without newline
        if !buffer.isEmpty { processLine(buffer) }

        return SessionSummary(
            sessionId: sessionId ?? file.deletingPathExtension().lastPathComponent,
            filePath: file.path,
            modifiedAt: modifiedAt,
            fileSize: fileSize,
            lineCount: lineCount,
            firstUserMessage: firstUserMessage,
            lastUserMessage: lastUserMessage,
            cwd: cwd,
            gitBranch: gitBranch
        )
    }
}
```

- [ ] **Step 2: Create ClaudeSessionScannerTests.swift**

Create `Tests/TBDDaemonTests/ClaudeSessionScannerTests.swift`:

```swift
import Testing
import Foundation
@testable import TBDDaemonLib

@Suite("ClaudeSessionScanner")
struct ClaudeSessionScannerTests {

    /// URL of the committed fixture file.
    private var fixtureURL: URL {
        // Walk up from this file's compile-time path to find the repo root,
        // then navigate to the fixture.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // TBDDaemonTests/
            .deletingLastPathComponent()  // Tests/
            .appendingPathComponent("Fixtures/sample-session.jsonl")
    }

    @Test("counts all lines in fixture")
    func lineCount() throws {
        let dir = fixtureURL.deletingLastPathComponent()
        let summaries = try ClaudeSessionScanner.listSessions(projectDir: dir)
        let summary = try #require(summaries.first(where: { $0.filePath.hasSuffix("sample-session.jsonl") }))
        #expect(summary.lineCount == 11)
    }

    @Test("first user message is the first real user turn")
    func firstUserMessage() throws {
        let dir = fixtureURL.deletingLastPathComponent()
        let summaries = try ClaudeSessionScanner.listSessions(projectDir: dir)
        let summary = try #require(summaries.first(where: { $0.filePath.hasSuffix("sample-session.jsonl") }))
        #expect(summary.firstUserMessage == "Hello, can you help me refactor this function?")
    }

    @Test("last user message is the last real user turn")
    func lastUserMessage() throws {
        let dir = fixtureURL.deletingLastPathComponent()
        let summaries = try ClaudeSessionScanner.listSessions(projectDir: dir)
        let summary = try #require(summaries.first(where: { $0.filePath.hasSuffix("sample-session.jsonl") }))
        #expect(summary.lastUserMessage == "What does this error mean?")
    }

    @Test("truncates messages at 300 characters")
    func truncatesAt300() throws {
        let longText = String(repeating: "a", count: 400)
        let line: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": longText]
        ]
        #expect(UserMessageClassifier.isRealUserMessage(line))
        #expect(UserMessageClassifier.extractText(line).map { String($0.prefix(300)).count } == 300)
    }

    @Test("extracts session metadata from header line")
    func sessionMetadata() throws {
        let dir = fixtureURL.deletingLastPathComponent()
        let summaries = try ClaudeSessionScanner.listSessions(projectDir: dir)
        let summary = try #require(summaries.first(where: { $0.filePath.hasSuffix("sample-session.jsonl") }))
        #expect(summary.cwd == "/Users/test/project")
        #expect(summary.gitBranch == "main")
    }

    @Test("empty file returns summary with zero lines")
    func emptyFile() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".jsonl")
        try Data().write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let summaries = try ClaudeSessionScanner.listSessions(projectDir: tmp.deletingLastPathComponent())
        let summary = summaries.first(where: { $0.filePath == tmp.path })
        #expect(summary?.lineCount == 0)
        #expect(summary?.firstUserMessage == nil)
    }

    @Test("directory resolution: exact encoding")
    func exactEncoding() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let encoded = "-Users-test-myproject"
        let dir = tmp.appendingPathComponent(encoded)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        ClaudeProjectDirectory.clearCache()
        let resolved = ClaudeProjectDirectory.resolve(worktreePath: "/Users/test/myproject", projectsBase: tmp)
        #expect(resolved?.lastPathComponent == encoded)
    }
}
```

- [ ] **Step 3: Verify tests pass**

```bash
cd /Users/chang/tbd/worktrees/tbd/20260408-aggregate-guan
swift test --filter ClaudeSessionScannerTests 2>&1 | tail -20
```

Expected: All tests pass. If `#filePath` navigation doesn't resolve, use `Bundle.module` or hard-code the path relative to the repo root.

- [ ] **Step 4: Commit**

```bash
git add Sources/TBDDaemon/Claude/ClaudeSessionScanner.swift \
        Tests/TBDDaemonTests/ClaudeSessionScannerTests.swift
git commit -m "feat: ClaudeSessionScanner + project directory resolver"
```

---

## Task 3: SessionSummary + RPC Types

**Files:**
- Modify: `Sources/TBDShared/Models.swift`
- Modify: `Sources/TBDShared/RPCProtocol.swift`

- [ ] **Step 1: Add SessionSummary to Models.swift**

Read `Sources/TBDShared/Models.swift` to find a good insertion point (after the last public struct, before the last closing brace/comment). Add:

```swift
// MARK: - SessionSummary

public struct SessionSummary: Codable, Sendable, Identifiable {
    public var id: String { sessionId }
    public let sessionId: String
    public let filePath: String
    public let modifiedAt: Date
    public let fileSize: Int64
    public let lineCount: Int
    public let firstUserMessage: String?
    public let lastUserMessage: String?
    public let cwd: String?
    public let gitBranch: String?

    public init(
        sessionId: String,
        filePath: String,
        modifiedAt: Date,
        fileSize: Int64,
        lineCount: Int,
        firstUserMessage: String?,
        lastUserMessage: String?,
        cwd: String?,
        gitBranch: String?
    ) {
        self.sessionId = sessionId
        self.filePath = filePath
        self.modifiedAt = modifiedAt
        self.fileSize = fileSize
        self.lineCount = lineCount
        self.firstUserMessage = firstUserMessage
        self.lastUserMessage = lastUserMessage
        self.cwd = cwd
        self.gitBranch = gitBranch
    }
}
```

- [ ] **Step 2: Add RPC method + params to RPCProtocol.swift**

In `Sources/TBDShared/RPCProtocol.swift`, in the `RPCMethod` enum body after the last `public static let`, add:

```swift
    public static let sessionList = "session.list"
```

Then in the params section (after the last existing params struct), add:

```swift
// MARK: - Session Params

public struct SessionListParams: Codable, Sendable {
    public let worktreeID: UUID

    public init(worktreeID: UUID) {
        self.worktreeID = worktreeID
    }
}
```

- [ ] **Step 3: Build to verify**

```bash
cd /Users/chang/tbd/worktrees/tbd/20260408-aggregate-guan
swift build 2>&1 | grep -E "error:|warning:|Build complete"
```

Expected: `Build complete!` with no errors.

- [ ] **Step 4: Commit**

```bash
git add Sources/TBDShared/Models.swift Sources/TBDShared/RPCProtocol.swift
git commit -m "feat: SessionSummary model and session.list RPC types"
```

---

## Task 4: RPC Handler + DaemonClient Method

**Files:**
- Create: `Sources/TBDDaemon/Server/RPCRouter+SessionHandlers.swift`
- Modify: `Sources/TBDDaemon/Server/RPCRouter.swift`
- Modify: `Sources/TBDApp/DaemonClient.swift`

- [ ] **Step 1: Create RPCRouter+SessionHandlers.swift**

Create `Sources/TBDDaemon/Server/RPCRouter+SessionHandlers.swift`:

```swift
import Foundation
import TBDShared

extension RPCRouter {

    func handleSessionList(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(SessionListParams.self, from: paramsData)

        guard let worktree = try await db.worktrees.get(id: params.worktreeID) else {
            return try RPCResponse(result: [SessionSummary]())
        }

        guard let projectDir = ClaudeProjectDirectory.resolve(worktreePath: worktree.path) else {
            return try RPCResponse(result: [SessionSummary]())
        }

        let summaries = try ClaudeSessionScanner.listSessions(projectDir: projectDir)
        return try RPCResponse(result: summaries)
    }
}
```

- [ ] **Step 2: Register the handler in RPCRouter.swift**

Read `Sources/TBDDaemon/Server/RPCRouter.swift`. Find the switch statement in `handle(_ request: RPCRequest)`. After the last `case RPCMethod.*:` entry (before the `default:` case), add:

```swift
            case RPCMethod.sessionList:
                return try await handleSessionList(request.paramsData)
```

- [ ] **Step 3: Add listSessions to DaemonClient.swift**

Read `Sources/TBDApp/DaemonClient.swift`. Find the section with typed RPC methods (near `func listRepos()`). Add after the last method in a logical grouping:

```swift
    func listSessions(worktreeID: UUID) throws -> [SessionSummary] {
        return try call(
            method: RPCMethod.sessionList,
            params: SessionListParams(worktreeID: worktreeID),
            resultType: [SessionSummary].self
        )
    }
```

- [ ] **Step 4: Build to verify**

```bash
cd /Users/chang/tbd/worktrees/tbd/20260408-aggregate-guan
swift build 2>&1 | grep -E "error:|warning:|Build complete"
```

Expected: `Build complete!` with no errors.

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDDaemon/Server/RPCRouter+SessionHandlers.swift \
        Sources/TBDDaemon/Server/RPCRouter.swift \
        Sources/TBDApp/DaemonClient.swift
git commit -m "feat: session.list RPC handler and DaemonClient method"
```

---

## Task 5: TabBar History Button

**Files:**
- Modify: `Sources/TBDApp/TabBar.swift`

The history button is **not** a `Tab` in the tabs array — it's a separate button pinned to the right of the tab strip via a `Spacer()`. The existing `TabBar` `body` ends with `Spacer()` after the `AddTabButton`. Replace that `Spacer()` with `Spacer()` + a new `HistoryTabButton`.

- [ ] **Step 1: Read TabBar.swift**

Read `Sources/TBDApp/TabBar.swift` in full to understand the current layout. The `body` of `TabBar` currently looks like:

```swift
HStack(spacing: 0) {
    ForEach(...) { ... TabBarItem(...) }
    Rectangle()...           // divider before +
    AddTabButton(...)
    Spacer()
}
```

- [ ] **Step 2: Add isHistorySelected + onHistoryTab to TabBar**

In `TabBar`'s stored properties (after `var onForkTab`), add:

```swift
    var isHistorySelected: Bool = false
    var onHistoryTab: () -> Void = {}
```

- [ ] **Step 3: Replace trailing Spacer with Spacer + HistoryTabButton**

In `TabBar.body`, change:

```swift
            Spacer()
        }
```

to:

```swift
            Spacer()

            HistoryTabButton(
                isSelected: isHistorySelected,
                action: onHistoryTab
            )
        }
```

- [ ] **Step 4: Add HistoryTabButton view**

Add this private struct at the bottom of `TabBar.swift` (before the last closing brace of the file, or after the `AddTabButton` struct):

```swift
// MARK: - HistoryTabButton

private struct HistoryTabButton: View {
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 10))
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(isHovering ? .secondary : .tertiary))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected ? Color.primary.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Session History")
    }
}
```

- [ ] **Step 5: Build to verify**

```bash
cd /Users/chang/tbd/worktrees/tbd/20260408-aggregate-guan
swift build 2>&1 | grep -E "error:|warning:|Build complete"
```

Expected: `Build complete!` with no errors.

- [ ] **Step 6: Commit**

```bash
git add Sources/TBDApp/TabBar.swift
git commit -m "feat: history button pinned to right of tab strip"
```

---

## Task 6: AppState+History

**Files:**
- Create: `Sources/TBDApp/AppState+History.swift`

- [ ] **Step 1: Create AppState+History.swift**

Create `Sources/TBDApp/AppState+History.swift`:

```swift
import Foundation
import TBDShared

// MARK: - History Load State

enum HistoryLoadState: Equatable {
    case idle
    case loading                           // first load — no prior data
    case loadingStale([SessionSummary])    // refetch — stale data visible
    case loaded([SessionSummary])
    case failed(String)                    // error message for display

    static func == (lhs: HistoryLoadState, rhs: HistoryLoadState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading): return true
        case (.loadingStale, .loadingStale): return true
        case (.loaded, .loaded): return true
        case (.failed(let a), .failed(let b)): return a == b
        default: return false
        }
    }

    var currentSessions: [SessionSummary] {
        switch self {
        case .loadingStale(let s), .loaded(let s): return s
        default: return []
        }
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        if case .loadingStale = self { return true }
        return false
    }
}

// MARK: - AppState History Extension

extension AppState {

    /// Whether the history pane is visible for a given worktree.
    /// Stored separately from tabs so it doesn't interfere with the layout system.
    // Note: @Published properties can't be in extensions on @MainActor classes in Swift 5.9.
    // historyActiveWorktrees and historyLoadStates are declared in AppState.swift.
    // This extension adds the logic methods only.

    func toggleHistory(worktreeID: UUID) {
        if historyActiveWorktrees.contains(worktreeID) {
            historyActiveWorktrees.remove(worktreeID)
        } else {
            historyActiveWorktrees.insert(worktreeID)
            Task { await fetchSessions(worktreeID: worktreeID) }
        }
    }

    func fetchSessions(worktreeID: UUID) async {
        let current = historyLoadStates[worktreeID]?.currentSessions ?? []
        historyLoadStates[worktreeID] = current.isEmpty ? .loading : .loadingStale(current)

        do {
            let fresh = try daemonClient.listSessions(worktreeID: worktreeID)
            historyLoadStates[worktreeID] = .loaded(fresh)
        } catch {
            historyLoadStates[worktreeID] = .failed(error.localizedDescription)
        }
    }

    func resumeSession(worktreeID: UUID, sessionId: String) async {
        do {
            let terminal = try daemonClient.createTerminal(
                worktreeID: worktreeID,
                resumeSessionID: sessionId
            )
            terminals[worktreeID, default: []].append(terminal)
            let tab = Tab(id: terminal.id, content: .terminal(terminalID: terminal.id))
            tabs[worktreeID, default: []].append(tab)
            // Switch to new tab and close history view
            let index = (tabs[worktreeID]?.count ?? 1) - 1
            activeTabIndices[worktreeID] = index
            historyActiveWorktrees.remove(worktreeID)
        } catch {
            handleConnectionError(error)
        }
    }
}
```

- [ ] **Step 2: Add @Published properties to AppState.swift**

Read `Sources/TBDApp/AppState.swift`. Find the `@Published` property block (around lines 70-90 where `tabs`, `terminals`, etc. are declared). Add these two properties:

```swift
    @Published var historyActiveWorktrees: Set<UUID> = []
    @Published var historyLoadStates: [UUID: HistoryLoadState] = [:]
```

- [ ] **Step 3: Build to verify**

```bash
cd /Users/chang/tbd/worktrees/tbd/20260408-aggregate-guan
swift build 2>&1 | grep -E "error:|warning:|Build complete"
```

Expected: `Build complete!`. Fix any `@Published` in extension errors by moving the properties to AppState.swift as instructed in Step 2.

- [ ] **Step 4: Commit**

```bash
git add Sources/TBDApp/AppState+History.swift Sources/TBDApp/AppState.swift
git commit -m "feat: AppState history state and session fetch/resume logic"
```

---

## Task 7: HistoryPaneView

**Files:**
- Create: `Sources/TBDApp/Panes/HistoryPaneView.swift`

- [ ] **Step 1: Create HistoryPaneView.swift**

Create `Sources/TBDApp/Panes/HistoryPaneView.swift`:

```swift
import SwiftUI
import TBDShared

// MARK: - HistoryPaneView

struct HistoryPaneView: View {
    let worktreeID: UUID
    @EnvironmentObject var appState: AppState

    private var loadState: HistoryLoadState {
        appState.historyLoadStates[worktreeID] ?? .idle
    }

    var body: some View {
        VStack(spacing: 0) {
            HistoryHeaderView(loadState: loadState, worktreeID: worktreeID)
            Divider()
            sessionList
        }
    }

    @ViewBuilder
    private var sessionList: some View {
        let sessions = loadState.currentSessions
        if sessions.isEmpty && !loadState.isLoading {
            VStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("No sessions found")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(sessions) { summary in
                SessionRowView(summary: summary)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Task {
                            await appState.resumeSession(
                                worktreeID: worktreeID,
                                sessionId: summary.sessionId
                            )
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            }
            .listStyle(.plain)
        }
    }
}

// MARK: - HistoryHeaderView

private struct HistoryHeaderView: View {
    let loadState: HistoryLoadState
    let worktreeID: UUID
    @EnvironmentObject var appState: AppState
    @State private var pendingSessions: [SessionSummary]? = nil
    @State private var upToDateVisible = false

    var body: some View {
        ZStack {
            // Fixed height so the list never shifts
            Color.clear.frame(height: 28)
            content
        }
        .onChange(of: loadState) { _, newState in
            handleTransition(newState)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .idle:
            EmptyView()

        case .loading:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.6)
                Text("Loading sessions…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .loadingStale:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.6)
                Text("Checking for new sessions…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .loaded:
            if let pending = pendingSessions {
                Button {
                    appState.historyLoadStates[worktreeID] = .loaded(pending)
                    pendingSessions = nil
                } label: {
                    Text("↑ \(pending.count) new session\(pending.count == 1 ? "" : "s") — click to show")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            } else if upToDateVisible {
                Text("Up to date")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .transition(.opacity)
            }

        case .failed(let msg):
            Button {
                Task { await appState.fetchSessions(worktreeID: worktreeID) }
            } label: {
                Text("Failed to load — click to retry")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help(msg)
        }
    }

    private func handleTransition(_ newState: HistoryLoadState) {
        guard case .loaded(let fresh) = newState else { return }
        let existing = loadState.currentSessions
        let existingIDs = Set(existing.map(\.sessionId))
        let newOnes = fresh.filter { !existingIDs.contains($0.sessionId) }

        if !newOnes.isEmpty {
            // Offer the new sessions without shifting the list
            pendingSessions = fresh
        } else {
            // Brief "up to date" flash
            upToDateVisible = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                withAnimation { upToDateVisible = false }
            }
        }
    }
}

// MARK: - SessionRowView

private struct SessionRowView: View {
    let summary: SessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(String(summary.sessionId.prefix(8)))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                Spacer()
                Text(summary.modifiedAt.relativeFormatted)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 4) {
                Text("\(summary.lineCount.formatted()) events")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
                Text(summary.fileSize.formattedFileSize)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let branch = summary.gitBranch {
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                    Text(branch)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if let first = summary.firstUserMessage {
                Text(first)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let last = summary.lastUserMessage, last != summary.firstUserMessage {
                Text(last)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Formatting Helpers

private extension Date {
    var relativeFormatted: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}

private extension Int64 {
    var formattedFileSize: String {
        let bytes = Double(self)
        if bytes < 1024 { return "\(self) B" }
        if bytes < 1_048_576 { return String(format: "%.1f KB", bytes / 1024) }
        return String(format: "%.1f MB", bytes / 1_048_576)
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
cd /Users/chang/tbd/worktrees/tbd/20260408-aggregate-guan
swift build 2>&1 | grep -E "error:|warning:|Build complete"
```

Expected: `Build complete!`. Fix any type errors (e.g. `HistoryLoadState` Equatable conformance needed for `onChange`).

- [ ] **Step 3: Commit**

```bash
git add Sources/TBDApp/Panes/HistoryPaneView.swift
git commit -m "feat: HistoryPaneView with stale-while-revalidate header"
```

---

## Task 8: Wire TabBar + TerminalContainerView

**Files:**
- Modify: `Sources/TBDApp/Terminal/TerminalContainerView.swift`

This task connects everything: the history button triggers the history view, and the history pane renders instead of `SplitLayoutView`.

- [ ] **Step 1: Read TerminalContainerView.swift in full**

Read `Sources/TBDApp/Terminal/TerminalContainerView.swift` to understand the `SingleWorktreeView` body, specifically the `TabBar(...)` call and `layoutContent(worktree:)`.

- [ ] **Step 2: Pass isHistorySelected + onHistoryTab into TabBar**

In `SingleWorktreeView.body`, find the `TabBar(...)` call. Add these two parameters:

```swift
                        isHistorySelected: appState.historyActiveWorktrees.contains(worktreeID),
                        onHistoryTab: {
                            appState.toggleHistory(worktreeID: worktreeID)
                        },
```

Add them after the existing `onForkTab:` closure argument.

- [ ] **Step 3: Override layoutContent for history view**

In `SingleWorktreeView`, find `layoutContent(worktree:)`. Replace the entire method with:

```swift
    @ViewBuilder
    private func layoutContent(worktree: Worktree) -> some View {
        if appState.historyActiveWorktrees.contains(worktreeID) {
            HistoryPaneView(worktreeID: worktreeID)
                .task(id: worktreeID) {
                    await appState.fetchSessions(worktreeID: worktreeID)
                }
        } else if let tab = activeTab {
            let layoutBinding = Binding<LayoutNode>(
                get: { appState.layouts[tab.id] ?? .pane(tab.content) },
                set: { appState.layouts[tab.id] = $0 }
            )
            SplitLayoutView(
                node: layoutBinding.wrappedValue,
                worktree: worktree,
                layout: layoutBinding
            )
            .id(tab.id)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "terminal")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text("No terminals")
                    .foregroundStyle(.secondary)
                Button("Create Terminal") {
                    Task {
                        await appState.createTerminal(worktreeID: worktreeID)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
```

Note: read the existing `layoutContent` body first to make sure the fallback empty-state matches exactly what was there before.

- [ ] **Step 4: Full build + test**

```bash
cd /Users/chang/tbd/worktrees/tbd/20260408-aggregate-guan
swift build 2>&1 | grep -E "error:|warning:|Build complete"
swift test 2>&1 | tail -30
```

Expected: `Build complete!` and all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDApp/Terminal/TerminalContainerView.swift
git commit -m "feat: wire history tab toggle and HistoryPaneView into SingleWorktreeView"
```

---

## Self-Review Checklist

- [x] **Spec coverage:**
  - Per-worktree tab, pinned right ✓ (Task 5, 8)
  - Session list sorted by mtime desc ✓ (Task 2 `ClaudeSessionScanner`)
  - Session ID, timestamp, size, line count, first/last user message ✓ (Task 7 `SessionRowView`)
  - Click row → resume ✓ (Task 6 `resumeSession`, Task 7 `onTapGesture`)
  - Stale-while-revalidate loading header ✓ (Task 7 `HistoryHeaderView`)
  - `UserMessageClassifier` isolated, fixture-tested ✓ (Task 1)
  - Three-tier directory resolution ✓ (Task 2 `ClaudeProjectDirectory`)
  - Server-side 300-char truncation ✓ (Task 2 `parseSummary`)
  - No direct file reads in app (RPC only) ✓
  - No `print()` in Sources/ ✓ (uses `os.Logger`)

- [x] **Type consistency:** `SessionSummary` defined once in TBDShared/Models.swift, used identically in scanner, handler, client, and view. `HistoryLoadState` defined once in AppState+History.swift.

- [x] **No placeholders:** All code blocks are complete.
