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

    private func title(_ target: Terminal, in terminals: [Terminal], name: String = "acme-feature") -> String? {
        ClaudeSessionTitle.wanted(
            displayName: name, terminalID: target.id, label: target.label, terminals: terminals)
    }

    @Test("the first Claude terminal gets the bare display name")
    func firstGetsBareName() {
        let first = terminal(0)
        #expect(title(first, in: [first]) == "acme-feature")
    }

    @Test("later unlabelled Claude terminals are numbered by creation order")
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

    @Test("a later terminal with a user-supplied label gets the label as its suffix")
    func labelledLaterTerminalUsesLabel() {
        let first = terminal(0)
        let reviewer = terminal(1, label: "reviewer")
        #expect(title(reviewer, in: [first, reviewer]) == "acme-feature · reviewer")
    }

    @Test("daemon identity labels and the resume label never become a suffix")
    func identityLabelsAreNumbered() {
        let first = terminal(0)
        let resumed = terminal(1, label: "claude")
        let login = terminal(2, label: TerminalLabel.login)
        let all = [first, resumed, login]
        #expect(title(resumed, in: all) == "acme-feature · 2")
        #expect(title(login, in: all) == "acme-feature · 3")
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
            label: TerminalLabel.claudeCode, terminals: [first]) == "acme-feature · 2")
        #expect(ClaudeSessionTitle.wanted(
            displayName: "acme-feature", terminalID: planned,
            label: TerminalLabel.claudeCode, terminals: []) == "acme-feature")
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

    @Test("entries are dropped by terminal, by worktree, and for rows that are gone")
    func entriesAreDropped() async {
        let store = ClaudeSessionTitleStore()
        let kept = UUID(), gone = UUID(), removed = UUID(), elsewhere = UUID()
        let otherWorktree = UUID()
        for id in [kept, gone, removed] {
            await store.record(terminalID: id, worktreeID: worktreeID, title: "t")
        }
        await store.record(terminalID: elsewhere, worktreeID: otherWorktree, title: "t")

        await store.forget(terminalID: removed)
        #expect(await store.lastApplied(terminalID: removed) == nil)

        await store.retainOnly(worktreeID: worktreeID, terminalIDs: [kept])
        #expect(await store.lastApplied(terminalID: kept) == "t")
        #expect(await store.lastApplied(terminalID: gone) == nil)
        #expect(await store.lastApplied(terminalID: elsewhere) == "t")

        await store.forget(worktreeID: otherWorktree)
        #expect(await store.lastApplied(terminalID: elsewhere) == nil)
        #expect(await store.lastApplied(terminalID: kept) == "t")
    }

    // MARK: - Spawn helper

    @Test("forSpawn suffixes a second Claude terminal and records what it returned")
    func forSpawnRecords() async throws {
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
            terminalID: planned, label: TerminalLabel.claudeCode)

        #expect(name == "acme-feature · 2")
        #expect(await store.lastApplied(terminalID: planned) == "acme-feature · 2")
    }
}
