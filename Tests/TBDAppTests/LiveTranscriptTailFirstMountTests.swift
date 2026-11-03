import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

// Tier 1, except the mount tests, which are tier 2: they host the real live
// pane in an offscreen window, turn the run loop a bounded number of times,
// and let the pane's app-side poll loop read real JSONL fixtures under the
// run's scratch root. No subprocesses, no daemon, no sleeps of the test's own,
// no `~/tbd`; every `AppState` gets a throwaway `UserDefaults` suite.
//
// The live pane mounts its table on the last `TranscriptTailFirstOpen.tailLimit`
// render nodes and widens once the open settles, whatever the store already
// holds, so a pane remounted over a populated store does not mount the table
// holding every row. See `TranscriptTailFirstOpen`.

/// The tail-first open's first store write.
@Suite("Live transcript opening tail")
@MainActor
struct LiveTranscriptOpeningTailTests {

    @Test("the opening tail does not replace a transcript the store already holds")
    func openingTailKeepsAPopulatedStore() {
        let suite = TestDefaultsSuite("live-tail-first-populated")
        defer { suite.tearDown() }
        let appState = AppState(userDefaults: suite.defaults)
        let full = LiveTailFirstFixtures.conversation(count: 200)
        let tail = Array(full.suffix(TranscriptTailFirstOpen.tailLimit))
        appState.sessionTranscripts["s"] = full

        TableTranscriptPaneView.publishOpeningTail(tail, sessionID: "s", into: appState)

        #expect(appState.sessionTranscripts["s"] == full)
    }

    @Test("the opening tail fills a slot that holds nothing", arguments: [false, true])
    func openingTailFillsAnEmptySlot(slotHoldsEmptyArray: Bool) {
        let suite = TestDefaultsSuite("live-tail-first-empty")
        defer { suite.tearDown() }
        let appState = AppState(userDefaults: suite.defaults)
        let tail = Array(LiveTailFirstFixtures.conversation(count: 200)
            .suffix(TranscriptTailFirstOpen.tailLimit))
        if slotHoldsEmptyArray { appState.sessionTranscripts["s"] = [] }

        TableTranscriptPaneView.publishOpeningTail(tail, sessionID: "s", into: appState)

        #expect(appState.sessionTranscripts["s"] == tail)
    }

    /// The slot a pane left behind on leaving the keep-alive set: the session
    /// as it stood then. The tail reads it as it stands now.
    @Test("an opening tail refreshes the bottom of an older snapshot and keeps its history")
    func openingTailRefreshesAStaleBottom() {
        let now = LiveTailFirstFixtures.conversation(count: 200)
        let then = Array(now.prefix(150))
        let tail = Array(now.suffix(TranscriptTailFirstOpen.tailLimit))

        let merged = TableTranscriptPaneView.openingTailMerge(slot: then, tail: tail)

        #expect(merged == now)
    }

    @Test("an opening tail the slot already ends with changes nothing")
    func openingTailMatchingTheBottomChangesNothing() {
        let full = LiveTailFirstFixtures.conversation(count: 200)
        let tail = Array(full.suffix(TranscriptTailFirstOpen.tailLimit))

        #expect(TableTranscriptPaneView.openingTailMerge(slot: full, tail: tail) == nil)
    }

    @Test("an opening tail that reaches nothing in the slot leaves it alone")
    func openingTailReachingNothingLeavesTheSlot() {
        let now = LiveTailFirstFixtures.conversation(count: 300)
        let then = Array(now.prefix(100))
        let tail = Array(now.suffix(TranscriptTailFirstOpen.tailLimit))

        #expect(TableTranscriptPaneView.openingTailMerge(slot: then, tail: tail) == nil)
    }

    @Test("an empty opening tail changes nothing")
    func emptyOpeningTailChangesNothing() {
        let full = LiveTailFirstFixtures.conversation(count: 200)

        #expect(TableTranscriptPaneView.openingTailMerge(slot: full, tail: []) == nil)
        #expect(TableTranscriptPaneView.openingTailMerge(slot: [], tail: []) == nil)
    }

    /// The live pane clears its widen whenever `body` stops showing the table,
    /// so a table rebuilt under the same identity mounts windowed again. Every
    /// state other than `.table` is such a stop, an error first of all: Retry
    /// after one rebuilds the table with the identity of the one that widened.
    @Test("an error, a terminal with no session and the waiting state all take the table out")
    func branchesOtherThanTheTableTakeItOut() {
        let error = TableTranscriptPaneView.Branch.resolve(
            loadError: "Lost connection to the daemon.", sessionID: "s",
            messagesEmpty: false, hasShownInitialMessages: true)
        let noSession = TableTranscriptPaneView.Branch.resolve(
            loadError: nil, sessionID: nil, messagesEmpty: false, hasShownInitialMessages: true)
        let waiting = TableTranscriptPaneView.Branch.resolve(
            loadError: nil, sessionID: "s", messagesEmpty: true, hasShownInitialMessages: false)
        let table = TableTranscriptPaneView.Branch.resolve(
            loadError: nil, sessionID: "s", messagesEmpty: true, hasShownInitialMessages: true)

        #expect(error == .error("Lost connection to the daemon."))
        #expect(noSession == .noSession)
        #expect(waiting == .waiting)
        #expect(table == .table)
    }
}

/// The live pane mounted over a store that already holds its session.
///
/// Each table's row count is the one its coordinator recorded inside
/// `makeNSView`, right after `reloadData` (`rowsAtMount`), so it is the count
/// the table was built with, whatever updates landed before the test looked.
///
/// The terminals carry a transcript path, so the pane polls app-side and
/// publishes the fixture file's own transcript over the one put in the store;
/// the daemon poll would fail here, with no daemon, and swap the table for an
/// error. Expected row counts are read from the store as it stands.
@Suite("Live transcript tail-first mount")
@MainActor
struct LiveTranscriptTailFirstMountTests {

    @Test("a long session already in the store mounts the live table on the tail, then widens")
    func storedLongSessionMountsSmallThenWidens() async throws {
        let suite = TestDefaultsSuite("live-tail-first-mount")
        defer { suite.tearDown() }
        let fixture = try LiveTailFirstFixtures.Sessions(names: ["a"])
        defer { fixture.remove() }
        let appState = AppState(userDefaults: suite.defaults)
        let worktreeID = UUID()
        let terminalID = UUID()
        let session = try #require(fixture.sessions["a"])
        appState.sessionTranscripts[session.id] = session.items
        appState.terminals[worktreeID] = [LiveTailFirstFixtures.terminal(
            id: terminalID, worktreeID: worktreeID, session: session)]
        let memo = TranscriptPresentationMemo()

        let pane = PaneTerminal(terminalID: terminalID)
        let host = OffscreenHost(
            root: LivePaneHarness(pane: pane, worktreeID: worktreeID).environment(appState),
            size: NSSize(width: 900, height: 600))
        defer { host.tearDown() }

        guard let mounted = await Self.firstSight(in: host, other: nil) else {
            Issue.record(HostSettleTimedOut(waitingFor: "the live table to mount", observed: "no table"))
            return
        }
        #expect(mounted.rows == TranscriptTailFirstOpen.tailLimit,
                "the live table mounted holding \(mounted.rows) rows")

        await Self.requireWidened(in: host, appState: appState, sessionID: session.id, memo: memo)
    }

    /// Session A widens; the terminal rolls to session B, whose table must
    /// mount windowed; B widens; the terminal loses its session, so the pane
    /// shows no table; it gets B back. B is still in the store and its table
    /// has the identity of the one that widened, so only clearing the widen
    /// when the table leaves the body keeps it from mounting with every row.
    /// The error and waiting states leave the body by the same rule.
    @Test("a session change mounts the next table on the tail, even back to a widened session")
    func sessionChangeMountsTheNextTableSmall() async throws {
        let suite = TestDefaultsSuite("live-tail-first-rollover")
        defer { suite.tearDown() }
        let fixture = try LiveTailFirstFixtures.Sessions(names: ["a", "b"])
        defer { fixture.remove() }
        let appState = AppState(userDefaults: suite.defaults)
        let worktreeID = UUID()
        let terminalID = UUID()
        let sessionA = try #require(fixture.sessions["a"])
        let sessionB = try #require(fixture.sessions["b"])
        appState.sessionTranscripts[sessionA.id] = sessionA.items
        appState.sessionTranscripts[sessionB.id] = sessionB.items
        let roll: @MainActor (LiveTailFirstFixtures.Session?) -> Void = { session in
            appState.terminals[worktreeID] = [LiveTailFirstFixtures.terminal(
                id: terminalID, worktreeID: worktreeID, session: session)]
        }
        roll(sessionA)
        let memo = TranscriptPresentationMemo()

        let pane = PaneTerminal(terminalID: terminalID)
        let host = OffscreenHost(
            root: LivePaneHarness(pane: pane, worktreeID: worktreeID).environment(appState),
            size: NSSize(width: 900, height: 600))
        defer { host.tearDown() }

        guard let tableA = await Self.firstSight(in: host, other: nil) else {
            Issue.record(HostSettleTimedOut(waitingFor: "session A's table to mount", observed: "no table"))
            return
        }
        guard await Self.requireWidened(in: host, appState: appState, sessionID: sessionA.id, memo: memo)
        else { return }

        roll(sessionB)
        guard let tableB = await Self.firstSight(in: host, other: tableA.container) else {
            Issue.record(HostSettleTimedOut(waitingFor: "session B's table to mount", observed: "no new table"))
            return
        }
        #expect(tableB.rows == TranscriptTailFirstOpen.tailLimit,
                "session B's table mounted holding \(tableB.rows) rows")
        guard await Self.requireWidened(in: host, appState: appState, sessionID: sessionB.id, memo: memo)
        else { return }

        roll(nil)
        let tableGone = await host.settle { host.firstDescendant(TranscriptContainerView.self) == nil }
        guard tableGone else {
            Issue.record(HostSettleTimedOut(
                waitingFor: "a terminal with no session to show no table", observed: "a table"))
            return
        }

        roll(sessionB)
        guard let tableBAgain = await Self.firstSight(in: host, other: nil) else {
            Issue.record(HostSettleTimedOut(
                waitingFor: "session B's table to mount again", observed: "no table"))
            return
        }
        #expect(tableBAgain.rows == TranscriptTailFirstOpen.tailLimit,
                "session B's table mounted again holding \(tableBAgain.rows) rows")
        await Self.requireWidened(in: host, appState: appState, sessionID: sessionB.id, memo: memo)
    }

    /// A terminal switch reuses the pane and rebuilds its table. When the new
    /// terminal carries the same Claude session, as after `claude --resume`,
    /// a widen keyed by session alone would still match in the very pass that
    /// builds the new table; keyed by the table's identity, it cannot.
    @Test("a terminal switch onto the same session mounts the next table on the tail")
    func terminalSwitchMountsTheNextTableSmall() async throws {
        let suite = TestDefaultsSuite("live-tail-first-terminal")
        defer { suite.tearDown() }
        let fixture = try LiveTailFirstFixtures.Sessions(names: ["a"])
        defer { fixture.remove() }
        let appState = AppState(userDefaults: suite.defaults)
        let worktreeID = UUID()
        let firstTerminalID = UUID()
        let secondTerminalID = UUID()
        let session = try #require(fixture.sessions["a"])
        appState.sessionTranscripts[session.id] = session.items
        appState.terminals[worktreeID] = [
            LiveTailFirstFixtures.terminal(id: firstTerminalID, worktreeID: worktreeID, session: session),
            LiveTailFirstFixtures.terminal(id: secondTerminalID, worktreeID: worktreeID, session: session),
        ]
        let memo = TranscriptPresentationMemo()

        let pane = PaneTerminal(terminalID: firstTerminalID)
        let host = OffscreenHost(
            root: LivePaneHarness(pane: pane, worktreeID: worktreeID).environment(appState),
            size: NSSize(width: 900, height: 600))
        defer { host.tearDown() }

        guard let first = await Self.firstSight(in: host, other: nil) else {
            Issue.record(HostSettleTimedOut(waitingFor: "the first terminal's table to mount", observed: "no table"))
            return
        }
        guard await Self.requireWidened(in: host, appState: appState, sessionID: session.id, memo: memo)
        else { return }

        pane.terminalID = secondTerminalID
        guard let second = await Self.firstSight(in: host, other: first.container) else {
            Issue.record(HostSettleTimedOut(
                waitingFor: "the second terminal's table to mount", observed: "no new table"))
            return
        }
        #expect(second.rows == TranscriptTailFirstOpen.tailLimit,
                "the second terminal's table mounted holding \(second.rows) rows")
        await Self.requireWidened(in: host, appState: appState, sessionID: session.id, memo: memo)
    }

    // MARK: Helpers

    /// The first table found that is not `other`, with the row count it was
    /// built with (`rowsAtMount`), or nil when none appeared within `settle`'s
    /// bound.
    private static func firstSight<Root: View>(
        in host: OffscreenHost<Root>, other: TranscriptContainerView?
    ) async -> (container: TranscriptContainerView, rows: Int)? {
        var found: (container: TranscriptContainerView, rows: Int)?
        _ = await host.settle {
            guard let container = host.firstDescendant(TranscriptContainerView.self, where: { $0 !== other }),
                  let rows = container.coordinator?.rowsAtMount else { return false }
            found = (container: container, rows: rows)
            return true
        }
        return found
    }

    /// Waits for the table to hold every node the store's transcript for
    /// `sessionID` renders as, and records the timeout otherwise.
    @discardableResult
    private static func requireWidened<Root: View>(
        in host: OffscreenHost<Root>, appState: AppState, sessionID: String,
        memo: TranscriptPresentationMemo
    ) async -> Bool {
        let expected: () -> Int = {
            TranscriptPresentation.build(
                items: appState.sessionTranscripts[sessionID] ?? [], memo: memo).nodes.count
        }
        let widened = await host.settle {
            let total = expected()
            return total > TranscriptTailFirstOpen.tailLimit
                && host.firstDescendant(TranscriptContainerView.self)?.coordinator?.tableView?.numberOfRows
                    == total
        }
        if !widened {
            let rows = host.firstDescendant(TranscriptContainerView.self)?.coordinator?.tableView?.numberOfRows
            Issue.record(HostSettleTimedOut(
                waitingFor: "the table to widen to all \(expected()) rows",
                observed: rows.map { "\($0) rows" } ?? "no table"))
        }
        return widened
    }
}

/// Which terminal the pane shows, as a test drives a terminal switch.
@MainActor
@Observable
private final class PaneTerminal {
    var terminalID: UUID

    init(terminalID: UUID) {
        self.terminalID = terminalID
    }
}

/// The live pane as `PanePlaceholder` builds it: one `TableTranscriptPaneView`
/// in a fixed place, handed whichever terminal it shows, so its state
/// outlives a terminal switch.
private struct LivePaneHarness: View {
    let pane: PaneTerminal
    let worktreeID: UUID

    var body: some View {
        TableTranscriptPaneView(terminalID: pane.terminalID, worktreeID: worktreeID)
    }
}

/// A bounded wait on the offscreen host that ran out, with what it last saw,
/// as the error a timeout records, so it reaches the CI summary.
private struct HostSettleTimedOut: Error, CustomStringConvertible {
    let waitingFor: String
    let observed: String

    var description: String {
        "timed out waiting for \(waitingFor): observed \(observed)"
    }
}

private enum LiveTailFirstFixtures {
    /// One session's JSONL on disk and the transcript it parses to.
    struct Session {
        let id: String
        let path: String
        let items: [TranscriptItem]
    }

    /// Long sessions written to a fresh directory under the run's scratch
    /// root, one per name, each 600 lines with ids of its own.
    struct Sessions {
        let directory: String
        let sessions: [String: Session]

        init(names: [String]) throws {
            let directory = fencedScratchRoot(prefix: "live-tail")
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            var sessions: [String: Session] = [:]
            for name in names {
                let path = "\(directory)/\(name).jsonl"
                try LiveTailFirstFixtures.jsonl(lines: 600, prefix: name)
                    .write(toFile: path, atomically: true, encoding: .utf8)
                let items = TranscriptParser.parse(filePath: path)
                sessions[name] = Session(id: "live-tail-first-\(name)", path: path, items: items)
            }
            self.directory = directory
            self.sessions = sessions
        }

        func remove() {
            try? FileManager.default.removeItem(atPath: directory)
        }
    }

    /// `count` items alternating a user prompt and an assistant reply.
    static func conversation(count: Int) -> [TranscriptItem] {
        (0..<count).map { index -> TranscriptItem in
            if index.isMultiple(of: 2) {
                return .userPrompt(id: "u-\(index)", text: "Prompt \(index)", timestamp: nil)
            }
            return .assistantText(id: "a-\(index)", text: "Reply \(index)", timestamp: nil, usage: nil)
        }
    }

    /// `lines` alternating user and assistant JSONL lines, their uuids
    /// prefixed with `prefix`.
    static func jsonl(lines: Int, prefix: String) -> String {
        (0..<lines).map { index -> String in
            let timestamp = "2026-05-05T10:00:00Z"
            if index.isMultiple(of: 2) {
                return "{\"type\":\"user\",\"uuid\":\"\(prefix)-u\(index)\",\"timestamp\":\"\(timestamp)\","
                    + "\"message\":{\"role\":\"user\",\"content\":\"hello \(index)\"}}"
            }
            return "{\"type\":\"assistant\",\"uuid\":\"\(prefix)-a\(index)\",\"timestamp\":\"\(timestamp)\","
                + "\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"reply \(index)\"}]}}"
        }
        .joined(separator: "\n")
    }

    /// A live Claude terminal on `session`'s transcript file, or with no
    /// session at all.
    static func terminal(id: UUID, worktreeID: UUID, session: Session?) -> TBDShared.Terminal {
        TBDShared.Terminal(
            id: id,
            worktreeID: worktreeID,
            tmuxWindowID: "@1",
            tmuxPaneID: "%1",
            label: "Claude",
            createdAt: Date(timeIntervalSince1970: 0),
            claudeSessionID: session?.id,
            transcriptPath: session?.path)
    }
}
