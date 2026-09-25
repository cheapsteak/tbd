import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// The remote transcript pane's link and "Show full output" rules: file paths
/// never act (they name files on another machine), and a card with no
/// terminal reads full bodies from the pane's cache file app-side.
@MainActor
@Suite("Remote transcript — links and full output")
struct RemoteTranscriptLinksAndDetailTests {

    // MARK: - Links

    @Test func remoteDestination_forAFile_doesNothing() {
        #expect(TranscriptLinkDestination.remote(.file("/home/acme/project/README.md")) == nil)
    }

    @Test func remoteDestination_forAURL_opensIt() throws {
        let url = try #require(URL(string: "https://example.com/docs"))
        #expect(TranscriptLinkDestination.remote(.web(url)) == url)
    }

    // MARK: - Full body source

    @Test func fullBodySource_terminalBoundCardAsksTheDaemon() {
        let tid = UUID()
        #expect(TranscriptFullBodySource.resolve(terminalID: tid, detailPath: nil) == .daemon(terminalID: tid))
        // A terminal outranks a path: local panes never set one, but if both
        // arrived the daemon route is the one those cards always used.
        #expect(TranscriptFullBodySource.resolve(terminalID: tid, detailPath: "/c/transcript.jsonl")
            == .daemon(terminalID: tid))
    }

    @Test func fullBodySource_noTerminalWithAPathReadsTheFile() {
        #expect(TranscriptFullBodySource.resolve(terminalID: nil, detailPath: "/c/transcript.jsonl")
            == .file(path: "/c/transcript.jsonl"))
    }

    @Test func fullBodySource_noTerminalNoPathOffersNothing() {
        // The History pane's shape: the footer stays withheld.
        #expect(TranscriptFullBodySource.resolve(terminalID: nil, detailPath: nil) == nil)
        #expect(TranscriptFullBodySource.resolve(terminalID: nil, detailPath: "") == nil)
    }

    @Test func fileRoute_findsTheRecordInARemoteCacheFile() throws {
        let path = try #require(Bundle.module.url(
            forResource: "remote-transcript-sample", withExtension: "jsonl",
            subdirectory: "Fixtures")).path
        let result = TranscriptDetailReader.fullBody(path: path, itemID: "toolu_remote_1", includeBody: true)
        #expect(result.text.contains("Package.swift"))
    }

    // MARK: - A non-Bash card routes through the shared helper

    @Test func grepCard_withNoTerminalButAPath_readsItsFullBodyFromTheFile() async throws {
        let path = try #require(Bundle.module.url(
            forResource: "remote-transcript-sample", withExtension: "jsonl",
            subdirectory: "Fixtures")).path
        let truncated = ToolResult(text: "Sources/App", truncatedTo: 11, isError: false)
        let card = GrepCardBody(id: "toolu_remote_2", result: truncated, terminalID: nil, detailPath: path)
        // The footer's condition and the fetch's route are the same value.
        #expect(card.fullBodySource == .file(path: path))

        let suiteName = "TBDAppTests.RemoteGrepCard.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let full = await card.fullBodySource?.fetch(
            itemID: card.id, appState: AppState(userDefaults: defaults))
        #expect(full?.text.contains("let fixtureMarker = 1") == true)
    }

    @Test func grepCard_withNeitherTerminalNorPath_withholdsTheFooter() {
        let card = GrepCardBody(
            id: "toolu_remote_2", result: ToolResult(text: "x", truncatedTo: 1, isError: false),
            terminalID: nil, detailPath: nil)
        #expect(card.fullBodySource == nil)
    }

    // MARK: - Overlay frames carry the path

    @Test func overlayOpen_carriesTheDetailPath_andPushInheritsIt() {
        let c = TranscriptOverlayCoordinator()
        c.open(terminalID: nil, itemID: "a", historySessionID: "remote:acme/s1", detailPath: "/c/t.jsonl")
        #expect(c.current == .item(ItemFrame(
            terminalID: nil, itemID: "a", historySessionID: "remote:acme/s1", detailPath: "/c/t.jsonl")))
        c.pushItem(itemID: "b")
        #expect(c.current == .item(ItemFrame(
            terminalID: nil, itemID: "b", historySessionID: "remote:acme/s1", detailPath: "/c/t.jsonl")))
    }

    @Test func overlayOpen_withoutAPath_isUnchanged() {
        let c = TranscriptOverlayCoordinator()
        c.open(terminalID: nil, itemID: "a", historySessionID: "session")
        #expect(c.current == .item(ItemFrame(terminalID: nil, itemID: "a", historySessionID: "session")))
        guard case .item(let frame)? = c.current else {
            Issue.record("expected an item frame")
            return
        }
        #expect(frame.detailPath == nil)
    }
}
