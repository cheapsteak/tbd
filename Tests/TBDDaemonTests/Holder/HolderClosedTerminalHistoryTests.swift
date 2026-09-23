import Darwin
import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Closed Terminals history for a holder row, through the one helper every
/// history-keeping holder teardown calls (`recordHolderClosedTerminal`).
///
/// The two branches are the whole rule: a reader that is draining is the live
/// store and its screen is captured; a reader suspended for an attach holds a
/// screen frozen at the moment the viewer arrived, so the entry is written
/// without one. Both are driven against a real `HolderReader` over a
/// socketpair — the reader's drain state is what decides, so a fake would be
/// testing the fake.
@Suite struct HolderClosedTerminalHistoryTests {

    private static let esc = "\u{1b}"

    private struct Fixture {
        let db: TBDDatabase
        let historyDir: String
        let terminal: Terminal

        func contentPath() -> String {
            db.terminalHistory.contentPath(
                worktreeID: terminal.worktreeID, terminalID: terminal.id)
        }

        func cleanup() {
            try? FileManager.default.removeItem(atPath: historyDir)
        }
    }

    /// A holder-transport Claude row, created through the same store call the
    /// spawn path uses.
    private func makeFixture() async throws -> Fixture {
        let historyDir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("tbd-holder-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: historyDir, withIntermediateDirectories: true)
        let db = try TBDDatabase(inMemory: true, terminalHistoryDir: historyDir)
        let repo = try await db.repos.create(
            path: "/tmp/acme-holder-history-\(UUID().uuidString)",
            displayName: "acme", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/acme-holder-history-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-holder-history")
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "", tmuxPaneID: "",
            label: TerminalLabel.claudeCode, claudeSessionID: "sess-holder-history",
            kind: .claude, transport: .holder, holderPID: nil, childPID: 0)
        return Fixture(db: db, historyDir: historyDir, terminal: terminal)
    }

    /// A reader over one end of a socketpair, seeded with coloured output
    /// before it starts — `ingest` must run with nothing else feeding the
    /// emulator, which before `start()` is guaranteed.
    private func makeSeededReader(sessionID: UUID) throws -> (HolderReader, Int32) {
        var pair: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let reader = HolderReader(
            sessionID: sessionID, ptyFD: pair[0], columns: 80, rows: 24,
            scrollbackLines: 200, observedChildFromStart: true)
        return (reader, pair[1])
    }

    private static let seed =
        "first plain line\r\n\(esc)[31mred marker line\(esc)[0m\r\nlast line"

    @Test("a draining reader's screen is captured into the entry")
    func liveReaderCapturesScrollbackAndViewport() async throws {
        let fx = try await makeFixture()
        defer { fx.cleanup() }
        let (reader, ours) = try makeSeededReader(sessionID: fx.terminal.id)
        defer { close(ours) }
        await reader.ingest(preamble: Data(Self.seed.utf8))
        try await reader.start()

        await WorktreeLifecycle.recordHolderClosedTerminal(
            fx.terminal, reader: reader, history: fx.db.terminalHistory)
        await reader.stop()

        let entries = try await fx.db.terminalHistory.list(worktreeID: fx.terminal.worktreeID)
        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(entry.id == fx.terminal.id)
        #expect(entry.kind == .claude)
        #expect(entry.claudeSessionID == "sess-holder-history")
        #expect(entry.lineCount > 0)

        let captured = try String(contentsOfFile: fx.contentPath(), encoding: .utf8)
        #expect(captured.contains("first plain line"))
        #expect(captured.contains("red marker line"))
        #expect(captured.contains("last line"))
        // Colours survive: the red run is re-encoded as an SGR sequence, and
        // nothing of the attach preamble's reset prelude (erase display and
        // scrollback) is in a file revive `cat`s under its own banner.
        #expect(captured.contains("\(Self.esc)["), "the capture lost its colours")
        #expect(!captured.contains("\(Self.esc)[3J"), "the capture carries the viewer reset prelude")
        #expect(!captured.contains("\r\n"), "the capture keeps CRLF line endings")
    }

    @Test("a suspended reader writes the entry without a capture")
    func suspendedReaderWritesEntryWithoutCapture() async throws {
        let fx = try await makeFixture()
        defer { fx.cleanup() }
        let (reader, ours) = try makeSeededReader(sessionID: fx.terminal.id)
        defer { close(ours) }
        await reader.ingest(preamble: Data(Self.seed.utf8))
        try await reader.start()
        // What an attach does: the viewer takes a duplicate of the pty and the
        // daemon's emulator freezes. The screen above is still in it, which is
        // what makes the absence below a decision rather than an empty model.
        let duplicate = try await reader.suspendDraining()
        close(duplicate)
        #expect(await reader.renderScreen().contains("red marker line"))

        await WorktreeLifecycle.recordHolderClosedTerminal(
            fx.terminal, reader: reader, history: fx.db.terminalHistory)
        await reader.stop()

        let entries = try await fx.db.terminalHistory.list(worktreeID: fx.terminal.worktreeID)
        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(entry.claudeSessionID == "sess-holder-history",
                "a Claude entry without its session id cannot be revived")
        #expect(entry.lineCount == 0)
        #expect(!FileManager.default.fileExists(atPath: fx.contentPath()),
                "a screen frozen at attach time was stored as the final screen")
    }

    @Test("a retried capture-less close keeps the first close's capture")
    func retriedCaptureLessCloseKeepsEarlierCapture() async throws {
        let fx = try await makeFixture()
        defer { fx.cleanup() }
        await fx.db.terminalHistory.recordOnClose(
            terminal: fx.terminal, capture: "an earlier capture\nsecond line\n")
        let first = try #require(
            try await fx.db.terminalHistory.list(worktreeID: fx.terminal.worktreeID).first)

        // The retry: the holder was disposed by the first close, so there is
        // no reader left to capture from.
        await fx.db.terminalHistory.recordOnClose(terminal: fx.terminal, capture: nil)

        let entries = try await fx.db.terminalHistory.list(worktreeID: fx.terminal.worktreeID)
        #expect(entries == [first], "the retry overwrote the first close's entry")
        #expect(try String(contentsOfFile: fx.contentPath(), encoding: .utf8)
                == "an earlier capture\nsecond line\n",
                "the retry threw away the first close's capture")
    }

    @Test("a capture-less entry removes a stray content file at its path")
    func captureLessEntryRemovesStrayContentFile() async throws {
        let fx = try await makeFixture()
        defer { fx.cleanup() }
        let path = fx.contentPath()
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try "stray".write(toFile: path, atomically: true, encoding: .utf8)

        await fx.db.terminalHistory.recordOnClose(terminal: fx.terminal, capture: nil)

        let entries = try await fx.db.terminalHistory.list(worktreeID: fx.terminal.worktreeID)
        #expect(entries.map(\.id) == [fx.terminal.id])
        #expect(entries.first?.lineCount == 0)
        #expect(!FileManager.default.fileExists(atPath: path),
                "the row says no capture while the viewer and revive would read the file")
    }

    @Test("a blank capture writes the entry without a content file")
    func blankCaptureWritesEntryWithoutFile() async throws {
        let fx = try await makeFixture()
        defer { fx.cleanup() }

        await fx.db.terminalHistory.recordOnClose(terminal: fx.terminal, capture: " \n\n ")

        let entries = try await fx.db.terminalHistory.list(worktreeID: fx.terminal.worktreeID)
        #expect(entries.map(\.id) == [fx.terminal.id])
        #expect(entries.first?.lineCount == 0)
        #expect(!FileManager.default.fileExists(atPath: fx.contentPath()))
    }

    @Test("no registry still writes the entry, without a capture")
    func noRegistryWritesEntryWithoutCapture() async throws {
        let fx = try await makeFixture()
        defer { fx.cleanup() }

        await WorktreeLifecycle.recordHolderClosedTerminal(
            fx.terminal, registry: nil, history: fx.db.terminalHistory)

        let entries = try await fx.db.terminalHistory.list(worktreeID: fx.terminal.worktreeID)
        #expect(entries.map(\.id) == [fx.terminal.id])
        #expect(entries.first?.claudeSessionID == "sess-holder-history")
        #expect(!FileManager.default.fileExists(atPath: fx.contentPath()))
    }
}
