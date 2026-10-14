import Foundation
import TBDShared

/// The title a Claude session in a worktree should carry: what `--name` sets
/// at spawn and what the `UserPromptSubmit` hook hands back as
/// `hookSpecificOutput.sessionTitle` after a rename. One function for both, so
/// a spawn name and a later hook title never disagree.
///
/// - **Base:** the worktree's display name, through
///   `ClaudeSpawnCommandBuilder.sanitizedSessionName`.
/// - **Suffix:** the first counted Claude terminal in the worktree, by
///   creation order, gets none. Each later one gets ` · <tab name>` when the
///   user has renamed its tab (`tab.setLabel`), otherwise ` · <n>` with `n`
///   its 1-based position among the worktree's counted Claude terminals.
///   Profile login terminals are not counted; parked ones are.
/// - **Uniqueness:** a title another live terminal in the worktree was last
///   given is skipped by bumping the number, so two sessions never share a
///   peer address while one of them has not yet re-prompted.
///
/// See `docs/specs/2026-10-14-session-title-sync-design.md`.
enum ClaudeSessionTitle {
    /// Separator between the display name and a later terminal's suffix.
    static let separator = " · "

    /// The share of the length cap a tab name may never take from the
    /// display name: a long tab name is shortened before the base drops below
    /// this many characters.
    static let minimumBaseLength = 24

    /// Whether a row is a Claude terminal. A nil `kind` is a legacy row,
    /// which reads as Claude only when it carries a session id — the same
    /// reading `isClaudeResumable` gives such rows.
    static func isClaudeTerminal(_ terminal: Terminal) -> Bool {
        guard !terminal.isCodexTerminal else { return false }
        if let kind = terminal.kind { return kind == .claude }
        return terminal.claudeSessionID != nil
    }

    /// Whether a row takes a position when numbering a worktree's Claude
    /// sessions. A profile login terminal does not: it is a credentials
    /// errand, and counting it would shift every later tab's number while it
    /// is open. A parked terminal does, because it resumes under its name.
    static func isCountedClaudeTerminal(_ terminal: Terminal) -> Bool {
        isClaudeTerminal(terminal) && terminal.label != TerminalLabel.login
    }

    /// The wanted title for `terminalID`, or nil when the display name
    /// sanitizes to nothing.
    ///
    /// - Parameters:
    ///   - terminals: the worktree's rows. The target takes its creation-order
    ///     position whatever its row says, because the caller is asking on
    ///     behalf of a Claude session (a Codex tab handed over to Claude still
    ///     wears its old kind until the swap commits). When the target has no
    ///     row yet — a spawn whose row is written after the command is built —
    ///     it is placed after every counted Claude terminal.
    ///   - tabLabels: the worktree's custom tab names, keyed by tab id. A
    ///     terminal's tab shares the terminal's id, so a terminal that roots a
    ///     tab finds its name here. A terminal split into another tab's layout
    ///     roots no tab of its own and is numbered.
    ///   - appliedTitles: the title each terminal was last given. Entries for
    ///     the target and for terminals with no row in `terminals` are
    ///     ignored, so a stale entry can never block a title.
    static func wanted(
        displayName: String,
        terminalID: UUID,
        terminals: [Terminal],
        tabLabels: [UUID: String] = [:],
        appliedTitles: [UUID: String] = [:]
    ) -> String? {
        guard let base = ClaudeSpawnCommandBuilder.sanitizedSessionName(displayName) else {
            return nil
        }
        // The same order `TerminalStore.list` uses, so a title computed from
        // an unsorted array matches one computed from the store's.
        let claude = terminals
            .filter { $0.id == terminalID || isCountedClaudeTerminal($0) }
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        let position = claude.firstIndex(where: { $0.id == terminalID }) ?? claude.count
        let liveIDs = Set(terminals.map(\.id))
        let taken = Set(appliedTitles.compactMap { entry in
            entry.key != terminalID && liveIDs.contains(entry.key) ? entry.value : nil
        })

        let label = position == 0
            ? nil
            : ClaudeSpawnCommandBuilder.sanitizedSessionName(tabLabels[terminalID])
        var title: String
        var number: Int
        if position == 0 {
            title = base
            number = 2
        } else if let label {
            title = compose(base: base, label: label, number: nil)
            number = 2
        } else {
            title = compose(base: base, label: nil, number: position + 1)
            number = position + 2
        }
        // Every candidate ends in a different number, so each differs from
        // the last and the loop ends once it is past every taken title.
        while taken.contains(title) {
            title = compose(base: base, label: label, number: number)
            number += 1
        }
        return title
    }

    /// `base · label`, `base · n` or `base · label n`, within the length cap.
    ///
    /// The suffix is never cut by the cap, because two tabs whose suffixes
    /// were cut away would share a name. A long label is shortened first, so
    /// the base keeps `minimumBaseLength` characters (or all of itself when
    /// shorter); the base then gives up whatever room the suffix still needs.
    static func compose(base: String, label: String?, number: Int?) -> String {
        let limit = ClaudeSpawnCommandBuilder.maxSessionNameLength
        let numberText: String
        switch (label, number) {
        case (_, nil): numberText = ""
        case (nil, let n?): numberText = String(n)
        case (_?, let n?): numberText = " \(n)"
        }
        var labelText = label ?? ""
        let labelRoom = limit - separator.count - min(base.count, minimumBaseLength) - numberText.count
        if labelText.count > labelRoom {
            labelText = String(labelText.prefix(max(0, labelRoom)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let tail = separator + labelText + numberText
        let room = max(0, limit - tail.count)
        let shortened = String(base.prefix(room)).trimmingCharacters(in: .whitespacesAndNewlines)
        return ClaudeSpawnCommandBuilder.sanitizedSessionName(shortened + tail) ?? base
    }

    /// The worktree's custom tab names, keyed by tab id. A failed read is an
    /// empty map: every later terminal is then numbered.
    static func tabLabels(db: TBDDatabase, worktreeID: UUID) async -> [UUID: String] {
        let tabs = (try? await db.tabs.listForWorktree(worktreeID: worktreeID)) ?? []
        var labels: [UUID: String] = [:]
        for tab in tabs {
            if let label = tab.label { labels[tab.id] = label }
        }
        return labels
    }

    /// The `--name` for a Claude spawn of `terminalID` into `worktreeID`.
    ///
    /// Does not record it: the caller records the title in `store` once the
    /// spawn has succeeded, because a session that never started was never
    /// given a name. A failed read of the rows falls back to the bare display
    /// name, which is what every spawn passed before suffixes existed.
    static func forSpawn(
        db: TBDDatabase,
        store: ClaudeSessionTitleStore,
        worktreeID: UUID,
        displayName: String,
        terminalID: UUID
    ) async -> String? {
        let terminals = (try? await db.terminals.list(worktreeID: worktreeID)) ?? []
        let labels = await tabLabels(db: db, worktreeID: worktreeID)
        let applied = await store.titles(worktreeID: worktreeID)
        return wanted(
            displayName: displayName,
            terminalID: terminalID,
            terminals: terminals,
            tabLabels: labels,
            appliedTitles: applied)
    }

    /// The title to hand a Claude session on its next prompt, or nil when the
    /// session already carries it (or is not a Claude session at all).
    ///
    /// Sends only on change, against the title last given that session, so a
    /// user's own `/rename` survives until the wanted title next moves.
    static func forPrompt(
        db: TBDDatabase,
        store: ClaudeSessionTitleStore,
        terminal: Terminal
    ) async -> String? {
        guard isClaudeTerminal(terminal),
              let worktree = try? await db.worktrees.get(id: terminal.worktreeID),
              let terminals = try? await db.terminals.list(worktreeID: terminal.worktreeID)
        else { return nil }
        let labels = await tabLabels(db: db, worktreeID: terminal.worktreeID)
        let applied = await store.titles(worktreeID: terminal.worktreeID)
        guard let title = wanted(
            displayName: worktree.displayName,
            terminalID: terminal.id,
            terminals: terminals,
            tabLabels: labels,
            appliedTitles: applied)
        else { return nil }
        return await store.claim(
            terminalID: terminal.id, worktreeID: terminal.worktreeID, title: title)
    }
}

/// The title TBD last gave each Claude session, keyed by terminal id.
///
/// In memory only: after a daemon restart every live session gets its wanted
/// title once, on its next prompt. Persisting it would cost a column and a
/// migration for a rare, cosmetic case. Entries leave with their rows, on the
/// paths that delete terminal rows; one those paths miss is harmless, because
/// `ClaudeSessionTitle.wanted` only reads entries whose row still exists.
public actor ClaudeSessionTitleStore {
    private struct Entry: Sendable {
        let worktreeID: UUID
        let title: String
    }

    private var entries: [UUID: Entry] = [:]

    public init() {}

    /// The title last given `terminalID`, if any.
    func lastApplied(terminalID: UUID) -> String? {
        entries[terminalID]?.title
    }

    /// The title last given each terminal in `worktreeID`.
    func titles(worktreeID: UUID) -> [UUID: String] {
        var titles: [UUID: String] = [:]
        for (id, entry) in entries where entry.worktreeID == worktreeID {
            titles[id] = entry.title
        }
        return titles
    }

    /// Record the title a successful spawn gave its session. A nil title
    /// clears the entry.
    func record(terminalID: UUID, worktreeID: UUID, title: String?) {
        if let title {
            entries[terminalID] = Entry(worktreeID: worktreeID, title: title)
        } else {
            entries[terminalID] = nil
        }
    }

    /// Returns `title` and records it when it differs from the last one given;
    /// returns nil when the session already carries it.
    func claim(terminalID: UUID, worktreeID: UUID, title: String) -> String? {
        guard entries[terminalID]?.title != title else { return nil }
        entries[terminalID] = Entry(worktreeID: worktreeID, title: title)
        return title
    }

    func forget(terminalID: UUID) {
        entries[terminalID] = nil
    }

    func forget(worktreeID: UUID) {
        entries = entries.filter { $0.value.worktreeID != worktreeID }
    }
}
