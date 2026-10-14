import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 1: the wanted-title function and the last-applied store, in memory.
/// See docs/specs/2026-10-14-session-title-sync-design.md.
@Suite("ClaudeSessionTitle")
struct ClaudeSessionTitleTests {
    private let worktreeID = UUID()
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private func terminal(
        _ offset: TimeInterval,
        kind: TerminalKind? = .claude,
        label: String? = TerminalLabel.claudeCode,
        claudeSessionID: String? = "session"
    ) -> Terminal {
        Terminal(
            worktreeID: worktreeID,
            tmuxWindowID: "@\(Int(offset))",
            tmuxPaneID: "%\(Int(offset))",
            label: label,
            createdAt: epoch.addingTimeInterval(offset),
            claudeSessionID: claudeSessionID,
            kind: kind)
    }

    private func title(
        _ target: Terminal,
        in terminals: [Terminal],
        name: String = "acme-feature",
        tabs: [UUID: String] = [:],
        applied: [UUID: String] = [:]
    ) -> String? {
        ClaudeSessionTitle.wanted(
            displayName: name, terminalID: target.id, terminals: terminals,
            tabLabels: tabs, appliedTitles: applied)
    }

    @Test("the first Claude terminal gets the bare display name")
    func firstGetsBareName() {
        let first = terminal(0)
        #expect(title(first, in: [first]) == "acme-feature")
    }

    @Test("later unnamed Claude terminals are numbered by creation order")
    func laterAreNumbered() {
        let first = terminal(0)
        let second = terminal(1)
        let third = terminal(2)
        // Deliberately unsorted: the function owns the ordering.
        let all = [third, first, second]
        #expect(title(first, in: all) == "acme-feature")
        #expect(title(second, in: all) == "acme-feature · 2")
        #expect(title(third, in: all) == "acme-feature · 3")
    }

    @Test("a later terminal whose tab the user renamed gets the tab's name as its suffix")
    func renamedTabUsesTabName() {
        let first = terminal(0)
        let reviewer = terminal(1)
        let all = [first, reviewer]
        #expect(title(reviewer, in: all, tabs: [reviewer.id: "reviewer"]) == "acme-feature · reviewer")
        // A tab name on the first terminal leaves it bare.
        #expect(title(first, in: all, tabs: [first.id: "lead"]) == "acme-feature")
    }

    @Test("the terminal row's own label never becomes a suffix")
    func rowLabelIsIgnored() {
        let first = terminal(0)
        let resumed = terminal(1, label: "claude")
        let custom = terminal(2, label: "reviewer")
        let all = [first, resumed, custom]
        #expect(title(resumed, in: all) == "acme-feature · 2")
        #expect(title(custom, in: all) == "acme-feature · 3")
    }

    @Test("closing the first Claude terminal renumbers the rest")
    func closingFirstRenumbers() {
        let second = terminal(1)
        let third = terminal(2)
        #expect(title(second, in: [second, third]) == "acme-feature")
        #expect(title(third, in: [second, third]) == "acme-feature · 2")
    }

    @Test("shell and Codex terminals are not counted")
    func nonClaudeTerminalsAreIgnored() {
        let shell = terminal(0, kind: .shell, label: nil, claudeSessionID: nil)
        let codex = terminal(1, kind: .codex, label: TerminalLabel.codex)
        let legacyShell = terminal(2, kind: nil, label: nil, claudeSessionID: nil)
        let first = terminal(3)
        let second = terminal(4)
        let all = [shell, codex, legacyShell, first, second]
        #expect(title(first, in: all) == "acme-feature")
        #expect(title(second, in: all) == "acme-feature · 2")
    }

    @Test("a profile login terminal takes no position")
    func loginTerminalIsNotCounted() {
        let login = terminal(0, label: TerminalLabel.login)
        let first = terminal(1)
        let second = terminal(2)
        let all = [login, first, second]
        #expect(title(first, in: all) == "acme-feature")
        #expect(title(second, in: all) == "acme-feature · 2")
    }

    @Test("a parked Claude terminal keeps its position")
    func parkedTerminalIsCounted() {
        var parked = terminal(0)
        parked.hibernatedAt = epoch
        let second = terminal(1)
        #expect(title(second, in: [parked, second]) == "acme-feature · 2")
    }

    @Test("a legacy row with a session id counts as Claude")
    func legacyClaudeRowCounts() {
        let legacy = terminal(0, kind: nil, label: nil)
        let second = terminal(1)
        #expect(title(second, in: [legacy, second]) == "acme-feature · 2")
    }

    @Test("a terminal with no row yet is placed after every existing Claude terminal")
    func absentTargetIsAppended() {
        let first = terminal(0)
        let planned = UUID()
        #expect(ClaudeSessionTitle.wanted(
            displayName: "acme-feature", terminalID: planned,
            terminals: [first]) == "acme-feature · 2")
        #expect(ClaudeSessionTitle.wanted(
            displayName: "acme-feature", terminalID: planned,
            terminals: []) == "acme-feature")
    }

    @Test("the target counts as Claude even while its row still reads Codex")
    func targetCountsWhateverItsKind() {
        let first = terminal(0)
        let handedOver = terminal(1, kind: .codex, label: TerminalLabel.codex)
        #expect(title(handedOver, in: [first, handedOver]) == "acme-feature · 2")
    }

    @Test("the display name is sanitized, and a blank one yields no title")
    func sanitizationApplies() {
        let first = terminal(0)
        #expect(title(first, in: [first], name: "  acme\nfeature \t") == "acmefeature")
        #expect(title(first, in: [first], name: " \n ") == nil)
    }

    @Test("a long display name is shortened so the suffix survives the length cap")
    func suffixSurvivesLengthCap() throws {
        let first = terminal(0)
        let second = terminal(1)
        let long = String(repeating: "a", count: 100)
        let named = try #require(title(second, in: [first, second], name: long))
        #expect(named.hasSuffix(" · 2"))
        #expect(named.count == ClaudeSpawnCommandBuilder.maxSessionNameLength)
        // Idempotent under the builder's own sanitizer, so `--name` emits
        // exactly the title the store records.
        #expect(ClaudeSpawnCommandBuilder.sanitizedSessionName(named) == named)
    }

    @Test("a long tab name is shortened before the display name drops below its floor")
    func longTabNameKeepsTheBase() throws {
        let first = terminal(0)
        let second = terminal(1)
        let base = String(repeating: "b", count: 40)
        let label = String(repeating: "L", count: 60)
        let named = try #require(title(
            second, in: [first, second], name: base, tabs: [second.id: label]))
        let floor = ClaudeSessionTitle.minimumBaseLength
        #expect(named.count == ClaudeSpawnCommandBuilder.maxSessionNameLength)
        #expect(named.hasPrefix(String(repeating: "b", count: floor) + ClaudeSessionTitle.separator))
        #expect(named.hasSuffix(String(repeating: "L", count:
            ClaudeSpawnCommandBuilder.maxSessionNameLength - floor - ClaudeSessionTitle.separator.count)))
        // A display name shorter than the floor keeps all of itself and the
        // tab name takes the rest of the cap.
        let short = try #require(title(
            second, in: [first, second], name: "acme", tabs: [second.id: label]))
        #expect(short == "acme · " + String(repeating: "L", count:
            ClaudeSpawnCommandBuilder.maxSessionNameLength - "acme".count - ClaudeSessionTitle.separator.count))
    }

    // MARK: - Uniqueness

    @Test("a number another live terminal still carries is skipped")
    func numberCollisionIsBumped() {
        // The first tab closed; the old second still carries ` · 2` because it
        // has not prompted since. A new spawn lands in position 2.
        let survivor = terminal(1)
        let planned = UUID()
        let applied = [survivor.id: "acme-feature · 2"]
        #expect(ClaudeSessionTitle.wanted(
            displayName: "acme-feature", terminalID: planned,
            terminals: [survivor], appliedTitles: applied) == "acme-feature · 3")
        // The survivor's own entry never blocks its own title.
        #expect(title(survivor, in: [survivor], applied: applied) == "acme-feature")
    }

    @Test("the bare name and a tab name are bumped with a number when taken")
    func bareAndLabelCollisionsAreBumped() {
        let first = terminal(0)
        let second = terminal(1)
        let all = [first, second]
        #expect(title(first, in: all, applied: [second.id: "acme-feature"]) == "acme-feature · 2")
        #expect(title(
            second, in: all,
            tabs: [second.id: "reviewer"],
            applied: [first.id: "acme-feature · reviewer"]) == "acme-feature · reviewer 2")
        #expect(title(
            second, in: all,
            applied: [first.id: "acme-feature · 2"]) == "acme-feature · 3")
    }

    @Test("an entry for a terminal with no row does not block a title")
    func staleEntryIsIgnored() {
        let first = terminal(0)
        let second = terminal(1)
        #expect(title(second, in: [first, second], applied: [UUID(): "acme-feature · 2"])
            == "acme-feature · 2")
    }

    // MARK: - Store

    @Test("claim returns a title only when it differs from the last one given")
    func claimSendsOnlyOnChange() async {
        let store = ClaudeSessionTitleStore()
        let id = UUID()
        await store.record(terminalID: id, worktreeID: worktreeID, title: "acme")
        #expect(await store.claim(terminalID: id, worktreeID: worktreeID, title: "acme") == nil)
        #expect(await store.claim(terminalID: id, worktreeID: worktreeID, title: "renamed") == "renamed")
        #expect(await store.claim(terminalID: id, worktreeID: worktreeID, title: "renamed") == nil)
        #expect(await store.lastApplied(terminalID: id) == "renamed")
    }

    @Test("with no entry, the first claim returns the title")
    func claimWithoutEntryReturnsTitle() async {
        let store = ClaudeSessionTitleStore()
        let id = UUID()
        #expect(await store.claim(terminalID: id, worktreeID: worktreeID, title: "acme") == "acme")
    }

    @Test("entries are listed by worktree and dropped by terminal and by worktree")
    func entriesAreListedAndDropped() async {
        let store = ClaudeSessionTitleStore()
        let kept = UUID(), removed = UUID(), elsewhere = UUID()
        let otherWorktree = UUID()
        for id in [kept, removed] {
            await store.record(terminalID: id, worktreeID: worktreeID, title: "t-\(id)")
        }
        await store.record(terminalID: elsewhere, worktreeID: otherWorktree, title: "t")

        await store.forget(terminalID: removed)
        #expect(await store.lastApplied(terminalID: removed) == nil)
        #expect(await store.titles(worktreeID: worktreeID) == [kept: "t-\(kept)"])

        await store.forget(worktreeID: otherWorktree)
        #expect(await store.lastApplied(terminalID: elsewhere) == nil)
        #expect(await store.lastApplied(terminalID: kept) == "t-\(kept)")
    }

    // MARK: - Spawn helper

    @Test("forSpawn suffixes a second Claude terminal and leaves the recording to the caller")
    func forSpawnDoesNotRecord() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/title-repo-\(UUID().uuidString)",
            displayName: "title-repo",
            defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "acme-feature", branch: "tbd/acme-feature",
            path: "/tmp/title-wt-\(UUID().uuidString)", tmuxServer: "tbd-title")
        _ = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: TerminalLabel.claudeCode, claudeSessionID: "s1", kind: .claude)
        let store = ClaudeSessionTitleStore()
        let planned = UUID()

        let name = await ClaudeSessionTitle.forSpawn(
            db: db, store: store, worktreeID: wt.id, displayName: wt.displayName,
            terminalID: planned)

        #expect(name == "acme-feature · 2")
        // A spawn that then fails must leave no record, so the helper does
        // not write one; the spawn site records after it succeeds.
        #expect(await store.lastApplied(terminalID: planned) == nil)
    }

    @Test("forSpawn reads the worktree's tab names")
    func forSpawnReadsTabNames() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/title-repo-\(UUID().uuidString)",
            displayName: "title-repo",
            defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "acme-feature", branch: "tbd/acme-feature",
            path: "/tmp/title-wt-\(UUID().uuidString)", tmuxServer: "tbd-title")
        _ = try await db.terminals.create(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: TerminalLabel.claudeCode, claudeSessionID: "s1", kind: .claude)
        let second = try await db.terminals.create(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            worktreeID: wt.id, tmuxWindowID: "@2", tmuxPaneID: "%2",
            label: TerminalLabel.claudeCode, claudeSessionID: "s2", kind: .claude)
        try await db.tabs.setLabel(tabID: second.id, worktreeID: wt.id, label: "reviewer")

        let name = await ClaudeSessionTitle.forSpawn(
            db: db, store: ClaudeSessionTitleStore(), worktreeID: wt.id,
            displayName: wt.displayName, terminalID: second.id)

        #expect(name == "acme-feature · reviewer")
    }
}
