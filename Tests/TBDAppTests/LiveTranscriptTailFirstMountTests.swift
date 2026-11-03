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

    /// Each state takes precedence over every one after it, so each input
    /// below also carries every condition the later states test for.
    @Test("the pane's branches resolve in precedence: error, no session, waiting, table")
    func branchesResolveInPrecedence() {
        typealias Branch = TableTranscriptPaneView.Branch
        let error = Branch.resolve(
            loadError: "Lost connection to the daemon.", sessionID: nil,
            messagesEmpty: true, hasShownInitialMessages: false)
        let noSession = Branch.resolve(
            loadError: nil, sessionID: nil, messagesEmpty: true, hasShownInitialMessages: false)
        let waiting = Branch.resolve(
            loadError: nil, sessionID: "s", messagesEmpty: true, hasShownInitialMessages: false)
        let tableAfterShowing = Branch.resolve(
            loadError: nil, sessionID: "s", messagesEmpty: true, hasShownInitialMessages: true)
        let tableWithMessages = Branch.resolve(
            loadError: nil, sessionID: "s", messagesEmpty: false, hasShownInitialMessages: false)

        #expect(error == .error("Lost connection to the daemon."))
        #expect(noSession == .noSession)
        #expect(waiting == .waiting)
        #expect(tableAfterShowing == .table)
        #expect(tableWithMessages == .table)
    }

    /// The widen is cleared whenever this key changes. Retry after an error
    /// rebuilds the table under the identity that widened; the error between
    /// is what changes the key, so that table mounts windowed.
    @Test("the widen's clear key moves when the table leaves or changes identity, never on a re-render")
    func shownTableKeyMovesOnlyWhenTheTableDoes() {
        let terminalID = UUID()
        let identityA = PaneIdentity(terminalID: terminalID, sessionID: "a")
        let identityB = PaneIdentity(terminalID: terminalID, sessionID: "b")
        let shownA = TableTranscriptPaneView.shownTableKey(.table, identity: identityA)
        let reRendered = TableTranscriptPaneView.shownTableKey(.table, identity: identityA)
        let error = TableTranscriptPaneView.shownTableKey(.error("Lost connection"), identity: identityA)
        let waiting = TableTranscriptPaneView.shownTableKey(.waiting, identity: identityA)
        let shownB = TableTranscriptPaneView.shownTableKey(.table, identity: identityB)

        #expect(shownA == identityA)
        #expect(reRendered == shownA, "a re-render of the same table must not clear its own widen")
        #expect(error == nil)
        #expect(waiting == nil)
        #expect(error != shownA, "the error between a widen and Retry must clear it")
        #expect(shownB != shownA)
    }

    /// The tail read numbers a line with no `uuid` from the start of its
    /// window, so a slot an earlier tail filled can hold the same ID for a
    /// different line.
    @Test("an opening tail that starts on a line with no uuid leaves a filled slot alone")
    func openingTailStartingOnAPositionalIDLeavesTheSlot() {
        let earlier = [TranscriptItem.userPrompt(id: "tail-0", text: "an older line", timestamp: nil)]
            + LiveTailFirstFixtures.conversation(count: 59)
        let tail = [TranscriptItem.userPrompt(id: "tail-0", text: "a newer line", timestamp: nil)]
            + LiveTailFirstFixtures.conversation(count: 59)

        #expect(TableTranscriptPaneView.openingTailMerge(slot: earlier, tail: tail) == nil)
        #expect(TableTranscriptPaneView.openingTailMerge(slot: [], tail: tail) == tail,
                "an empty slot still takes the tail")
    }

    /// The predicate is checked against what the parsers actually mint, not
    /// against a copy of their formats.
    @Test("the parsers' IDs for lines with no uuid are positional fallbacks, and real ones are not")
    func positionalFallbackIDsMatchWhatTheParsersMint() throws {
        let fixture = try LiveTailFirstFixtures.uuidlessSession()
        defer { fixture.remove() }
        let fullIDs = TranscriptParser.parse(filePath: fixture.path).map(\.id)
        let tailIDs = TranscriptParser.parseTail(filePath: fixture.path, limit: 6).map(\.id)
        let fullFallbacks = fullIDs.filter { TranscriptParser.isPositionalFallbackID($0) }
        let tailFallbacks = tailIDs.filter { TranscriptParser.isPositionalFallbackID($0) }
        let realIDs = (fullIDs + tailIDs).filter { !TranscriptParser.isPositionalFallbackID($0) }
        let allRealIDsAreUUIDs = realIDs.allSatisfy { $0.hasPrefix("real-") }
        let fullFallbacksAreLineIDs = fullFallbacks.allSatisfy { $0.hasPrefix("line-") }
        let tailFallbacksAreTailIDs = tailFallbacks.allSatisfy { $0.hasPrefix("tail-") }
        let someFallbackHasABlockSuffix = fullFallbacks.contains { $0.contains("#") }

        #expect(fullFallbacks.count == LiveTailFirstFixtures.uuidlessLines,
                "full parse IDs: \(fullIDs)")
        #expect(!tailFallbacks.isEmpty, "tail IDs: \(tailIDs)")
        #expect(allRealIDsAreUUIDs, "IDs not taken for fallbacks: \(realIDs)")
        #expect(fullFallbacksAreLineIDs)
        #expect(tailFallbacksAreTailIDs)
        #expect(someFallbackHasABlockSuffix, "an assistant line's item carries a #<block> suffix")

        let notFallbacks = ["line-", "tail-", "line-3a", "lines-3", "real-line-3", "toolu_01"]
        let misread = notFallbacks.filter { TranscriptParser.isPositionalFallbackID($0) }
        #expect(misread.isEmpty, "read as positional fallbacks: \(misread)")
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

        guard let mounted = await Self.firstSight(in: host, excluding: []) else {
            Issue.record(HostSettleTimedOut(waitingFor: "the live table to mount", observed: "no table"))
            return
        }
        #expect(mounted.rows == TranscriptTailFirstOpen.tailLimit,
                "the live table mounted holding \(mounted.rows) rows")

        await Self.requireWidened(in: host, container: mounted.container, appState: appState, sessionID: session.id, memo: memo)
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

        guard let tableA = await Self.firstSight(in: host, excluding: []) else {
            Issue.record(HostSettleTimedOut(waitingFor: "session A's table to mount", observed: "no table"))
            return
        }
        guard await Self.requireWidened(in: host, container: tableA.container, appState: appState, sessionID: sessionA.id, memo: memo)
        else { return }

        roll(sessionB)
        guard let tableB = await Self.firstSight(in: host, excluding: [tableA.container]) else {
            Issue.record(HostSettleTimedOut(waitingFor: "session B's table to mount", observed: "no new table"))
            return
        }
        #expect(tableB.rows == TranscriptTailFirstOpen.tailLimit,
                "session B's table mounted holding \(tableB.rows) rows")
        guard await Self.requireWidened(in: host, container: tableB.container, appState: appState, sessionID: sessionB.id, memo: memo)
        else { return }

        roll(nil)
        let tableGone = await host.settle { host.firstDescendant(TranscriptContainerView.self) == nil }
        guard tableGone else {
            Issue.record(HostSettleTimedOut(
                waitingFor: "a terminal with no session to show no table", observed: "a table"))
            return
        }

        roll(sessionB)
        guard let tableBAgain = await Self.firstSight(in: host, excluding: [tableA.container, tableB.container]) else {
            Issue.record(HostSettleTimedOut(
                waitingFor: "session B's table to mount again", observed: "no table"))
            return
        }
        #expect(tableBAgain.rows == TranscriptTailFirstOpen.tailLimit,
                "session B's table mounted again holding \(tableBAgain.rows) rows")
        await Self.requireWidened(in: host, container: tableBAgain.container, appState: appState, sessionID: sessionB.id, memo: memo)
    }

    /// Session A widens; the terminal rolls to session B, whose table mounts
    /// but is taken out of its window before its open settles, as
    /// `WorktreePager` takes out a background worktree's pane, so B holds its
    /// report; the terminal goes back to A, with the pane still out. A's new
    /// table has the identity of the one that widened and the table never
    /// left the body, so only clearing the widen on the identity change keeps
    /// it from mounting with every row.
    ///
    /// The pane goes back into its window after the change to A. B's held
    /// report is then queued a turn behind the window insertion, and SwiftUI
    /// builds A's table in the layout that insertion triggers; B's table is
    /// gone by then and keeps its report.
    @Test("returning to a table identity that widened, through one that never settled, mounts it on the tail")
    func returningToAWidenedIdentityMountsSmall() async throws {
        let suite = TestDefaultsSuite("live-tail-first-return")
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
        let roll: @MainActor (LiveTailFirstFixtures.Session) -> Void = { session in
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

        guard let tableA = await Self.firstSight(in: host, excluding: []) else {
            Issue.record(HostSettleTimedOut(waitingFor: "session A's table to mount", observed: "no table"))
            return
        }
        guard await Self.requireWidened(
            in: host, container: tableA.container, appState: appState, sessionID: sessionA.id, memo: memo)
        else { return }

        roll(sessionB)
        guard let tableB = await Self.firstSight(in: host, excluding: [tableA.container]) else {
            Issue.record(HostSettleTimedOut(waitingFor: "session B's table to mount", observed: "no new table"))
            return
        }
        let ground = host.contentView
        host.window.contentView = nil
        await drainMainQueue()
        guard tableB.container.coordinator?.pendingOpenSettled != nil else {
            Issue.record(ArrangementFailed(
                description: "session B's table holds no open-settled report out of the window, "
                    + "so its open settled first and the return to A would test nothing"))
            return
        }

        roll(sessionA)
        host.window.contentView = ground
        guard let tableAAgain = await Self.firstSight(
            in: host, excluding: [tableA.container, tableB.container]) else {
            Issue.record(HostSettleTimedOut(
                waitingFor: "session A's table to mount again", observed: "no new table"))
            return
        }
        #expect(tableAAgain.rows == TranscriptTailFirstOpen.tailLimit,
                "session A's table mounted again holding \(tableAAgain.rows) rows")
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

        guard let first = await Self.firstSight(in: host, excluding: []) else {
            Issue.record(HostSettleTimedOut(waitingFor: "the first terminal's table to mount", observed: "no table"))
            return
        }
        guard await Self.requireWidened(in: host, container: first.container, appState: appState, sessionID: session.id, memo: memo)
        else { return }

        pane.terminalID = secondTerminalID
        guard let second = await Self.firstSight(in: host, excluding: [first.container]) else {
            Issue.record(HostSettleTimedOut(
                waitingFor: "the second terminal's table to mount", observed: "no new table"))
            return
        }
        #expect(second.rows == TranscriptTailFirstOpen.tailLimit,
                "the second terminal's table mounted holding \(second.rows) rows")
        await Self.requireWidened(in: host, container: second.container, appState: appState, sessionID: session.id, memo: memo)
    }

    // MARK: Helpers

    /// The first table found that is none of `excluding`, with the row count
    /// it was built with (`rowsAtMount`), or nil when none appeared within
    /// `settle`'s bound.
    private static func firstSight<Root: View>(
        in host: OffscreenHost<Root>, excluding: [TranscriptContainerView]
    ) async -> (container: TranscriptContainerView, rows: Int)? {
        var found: (container: TranscriptContainerView, rows: Int)?
        _ = await host.settle {
            guard let container = host.firstDescendant(
                    TranscriptContainerView.self, where: { view in !excluding.contains { $0 === view } }),
                  let rows = container.coordinator?.rowsAtMount else { return false }
            found = (container: container, rows: rows)
            return true
        }
        return found
    }

    /// Waits for `container`'s table, the one the test saw mount, to hold
    /// every node the store's transcript for `sessionID` renders as, and
    /// records the timeout otherwise. The same container, not any table: a
    /// widen that rebuilt the table would remount it holding every row, the
    /// very mount these tests rule out.
    @discardableResult
    private static func requireWidened<Root: View>(
        in host: OffscreenHost<Root>, container: TranscriptContainerView, appState: AppState,
        sessionID: String, memo: TranscriptPresentationMemo
    ) async -> Bool {
        let expected: () -> Int = {
            TranscriptPresentation.build(
                items: appState.sessionTranscripts[sessionID] ?? [], memo: memo).nodes.count
        }
        let widened = await host.settle {
            let total = expected()
            return total > TranscriptTailFirstOpen.tailLimit
                && host.firstDescendant(TranscriptContainerView.self) === container
                && container.coordinator?.tableView?.numberOfRows == total
        }
        if !widened {
            let shown = host.firstDescendant(TranscriptContainerView.self)
            let observed: String
            if let shown, shown !== container {
                observed = "a different table, of \(shown.coordinator?.tableView?.numberOfRows ?? -1) rows"
            } else if let rows = container.coordinator?.tableView?.numberOfRows {
                observed = "\(rows) rows"
            } else {
                observed = "no table"
            }
            Issue.record(HostSettleTimedOut(
                waitingFor: "the mounted table to widen to all \(expected()) rows", observed: observed))
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

/// A state a test arranges that did not take hold, so the assertions after it
/// would test nothing; recorded as an error so it reaches the CI summary.
private struct ArrangementFailed: Error, CustomStringConvertible {
    let description: String
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

    /// One JSONL file in a fresh directory under the run's scratch root.
    struct SessionFile {
        let directory: String
        let path: String

        func remove() {
            try? FileManager.default.removeItem(atPath: directory)
        }
    }

    /// How many of `uuidlessSession`'s lines carry no `uuid`; each parses to
    /// one item.
    static let uuidlessLines = 6

    /// Twelve lines alternating user and assistant in pairs, every even one
    /// with no `uuid` and every odd one with `uuid` `real-<n>`, so the parsers
    /// give both line kinds both item kinds: `<line>` and `<line>#0`.
    static func uuidlessSession() throws -> SessionFile {
        let directory = fencedScratchRoot(prefix: "live-tail-ids")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = "\(directory)/session.jsonl"
        let body = (0..<(uuidlessLines * 2)).map { index -> String in
            let uuid = index.isMultiple(of: 2) ? "" : "\"uuid\":\"real-\(index)\","
            let timestamp = "\"timestamp\":\"2026-05-05T10:00:00Z\","
            if index % 4 < 2 {
                return "{\"type\":\"user\",\(uuid)\(timestamp)"
                    + "\"message\":{\"role\":\"user\",\"content\":\"hello \(index)\"}}"
            }
            return "{\"type\":\"assistant\",\(uuid)\(timestamp)"
                + "\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"reply \(index)\"}]}}"
        }
        try body.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return SessionFile(directory: directory, path: path)
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
