import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("Codex handoff generator")
struct CodexHandoffGeneratorTests {
    private struct ExpectedTargetOperation: Error {}

    @Test("extracts bounded untrusted transcript and repository state")
    func extractsBoundedContent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-handoff-generator-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("session.jsonl")
        let lines = [
            #"{"type":"progress","message":{"content":"ignore me"}}"#,
            #"{"type":"user","message":{"content":"implement the takeover"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"working tree inspected"}]}}"#,
        ]
        try lines.joined(separator: "\n").write(
            to: transcript, atomically: true, encoding: .utf8)
        let worktree = Worktree(
            id: UUID(), repoID: nil, name: "pilot", displayName: "Pilot",
            branch: "feature/handoff",
            path: root.path, status: .active, tmuxServer: "test")
        let input = CodexHandoffInput(
            sourceTerminalID: UUID(),
            sessionID: "claude-session",
            transcriptURL: transcript,
            worktree: worktree,
            repo: nil,
            gitStatus: "## feature/handoff\n M Sources/File.swift",
            recentCommits: "abc1234 add feature",
            tbdContext: "Pilot note")

        let artifact = try DeterministicCodexHandoffGenerator().generate(input)
        let data = artifact.data
        let content = try #require(String(data: data, encoding: .utf8))

        #expect(data.count <= DeterministicCodexHandoffGenerator.maximumOutputBytes)
        #expect(artifact.capture.transcriptBytesRead > 0)
        #expect(artifact.capture.transcriptBytesRendered > 0)
        #expect(artifact.capture.handoffBytesOutput == data.count)
        #expect(!artifact.capture.transcriptTailTruncated)
        #expect(content.contains("implement the takeover"))
        #expect(content.contains("working tree inspected"))
        #expect(!content.contains("ignore me"))
        #expect(!content.contains(#""type":"user""#))
        #expect(content.contains("M Sources/File.swift"))
        #expect(content.contains("Pilot note"))
        #expect(content.contains("<untrusted-claude-transcript>"))
        #expect(content.contains("verify every assumption"))
        #expect(content.contains("AGENTS.md"))
        #expect(content.contains("CLAUDE.md"))
        #expect(content.contains("claim-work"))
        #expect(content.contains("closeout"))
        #expect(content.contains("missing references"))
        #expect(content.contains("tracked repository equivalents"))
        #expect(content.contains("Claude-only knowledge injectors"))
        #expect(content.contains("Context Parity Warnings"))
        #expect(content.contains("Verify provenance"))
        #expect(content.contains(".Codex/skills"))
        #expect(content.contains(".agents/skills"))
        #expect(content.contains(".claude/skills"))
        #expect(content.contains("context budget"))
        #expect(content.contains("injector and hook parity"))
        #expect(content.contains(transcript.path))
        #expect(content.contains("does not stage, repair, reset, or clean"))
    }

    @Test("UTF-8 truncation includes its marker inside the exact byte bound")
    func utf8BoundIsExact() {
        let result = DeterministicCodexHandoffGenerator.utf8Prefix(
            String(repeating: "🛠️", count: 100), maximumBytes: 64)

        #expect(result.utf8.count <= 64)
        #expect(result.contains("truncated by TBD"))
    }

    @Test("capture metadata reports bounded transcript tail and output")
    func captureMetadataReportsBounds() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-handoff-capture-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("large.jsonl")
        let line = #"{"type":"user","message":{"content":"bounded capture message"}}"#
        try Array(repeating: line, count: 2_000).joined(separator: "\n")
            .write(to: transcript, atomically: true, encoding: .utf8)
        let worktree = Worktree(
            repoID: nil, name: "capture", displayName: "Capture",
            branch: "main", path: root.path, tmuxServer: "test")

        let artifact = try DeterministicCodexHandoffGenerator().generate(
            CodexHandoffInput(
                sourceTerminalID: UUID(),
                sessionID: "large-session",
                transcriptURL: transcript,
                worktree: worktree,
                repo: nil,
                gitStatus: "clean",
                recentCommits: "none",
                tbdContext: ""))

        #expect(artifact.capture.transcriptBytesRead
            == DeterministicCodexHandoffGenerator.maximumTranscriptReadBytes)
        #expect(artifact.capture.transcriptBytesRendered
            <= DeterministicCodexHandoffGenerator.maximumTranscriptRenderedBytes)
        #expect(artifact.capture.handoffBytesOutput == artifact.data.count)
        #expect(artifact.capture.handoffBytesOutput
            <= DeterministicCodexHandoffGenerator.maximumOutputBytes)
        #expect(artifact.capture.transcriptTailTruncated)
    }

    @Test("private writer uses 0700 directory and 0600 file")
    func privatePermissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-handoff-permissions-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("nested/CODEX_HANDOFF.md")

        try CodexHandoffFiles.writePrivateImmutable(Data("handoff".utf8), to: file)

        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: file.deletingLastPathComponent().path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("singleflight separates future takeover targets")
    func singleflightSeparatesTargets() async throws {
        let coordinator = ContinueInCodexCoordinator()
        let sourceID = UUID()
        let remoteTarget = TerminalContinueInCodexTarget(
            kind: "agent_box", workerID: "worker-1")
        let localResult = TerminalContinueInCodexResult(
            terminal: Terminal(
                worktreeID: UUID(),
                tmuxWindowID: "@codex",
                tmuxPaneID: "%codex",
                label: TerminalLabel.codex,
                kind: .codex),
            handoffPath: "/private/CODEX_HANDOFF.md",
            created: true,
            warnings: [],
            capture: TerminalContinueInCodexCaptureMetadata(
                transcriptBytesRead: 0,
                transcriptBytesRendered: 0,
                handoffBytesOutput: 0,
                transcriptTailTruncated: false))
        let (enteredStream, enteredContinuation) =
            AsyncStream.makeStream(of: Void.self)
        let (releaseStream, releaseContinuation) =
            AsyncStream.makeStream(of: Void.self)
        let localTask = Task {
            try await coordinator.run(
                sourceTerminalID: sourceID,
                target: .localCodex
            ) {
                enteredContinuation.yield()
                var iterator = releaseStream.makeAsyncIterator()
                _ = await iterator.next()
                return localResult
            }
        }
        var enteredIterator = enteredStream.makeAsyncIterator()
        _ = await enteredIterator.next()

        let remoteTask = Task {
            try await coordinator.run(
                sourceTerminalID: sourceID,
                target: remoteTarget
            ) {
                throw ExpectedTargetOperation()
            }
        }
        // Give the remote request a turn to enter the coordinator while the
        // local operation is provably held open.
        await Task.yield()
        releaseContinuation.yield()

        do {
            _ = try await remoteTask.value
            Issue.record("different targets must not share an in-flight result")
        } catch is ExpectedTargetOperation {
            // The remote operation ran independently, as required.
        }

        #expect(try await localTask.value.target == .localCodex)
    }
}
