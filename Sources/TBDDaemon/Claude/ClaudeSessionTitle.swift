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
/// - **Uniqueness:** a title the store holds for any other terminal in the
///   worktree — given to it, or reserved by a spawn of it in flight — is
///   skipped by bumping the number, so two sessions never share a peer
///   address while one of them has not yet re-prompted.
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
    /// sessions, and whether it is titled at all. A profile login terminal is
    /// neither: it is a credentials errand, and counting it would shift every
    /// later tab's number while it is open. A parked terminal is both,
    /// because it resumes under its name.
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
    ///   - heldTitles: every title the store holds in the worktree, keyed by
    ///     terminal id — the title each terminal was last given and the ones
    ///     reserved by spawns still in flight. All but the target's own block
    ///     a title, whether or not `terminals` has a row for them: a spawn's
    ///     row is written only after it launches, and a snapshot of the rows
    ///     taken before a concurrent spawn confirmed would miss that spawn.
    ///     Entries leave with their rows (`ClaudeSessionTitleStore.forget`).
    static func wanted(
        displayName: String,
        terminalID: UUID,
        terminals: [Terminal],
        tabLabels: [UUID: String] = [:],
        heldTitles: [UUID: String] = [:]
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
        let taken = Set(heldTitles.compactMap { entry in
            entry.key != terminalID ? entry.value : nil
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

    /// The `--name` for a Claude spawn of `terminalID` into `worktreeID`,
    /// reserved in `store` until the caller confirms or releases it.
    ///
    /// The reservation is what lets concurrent spawns into one worktree see
    /// each other: a spawn's row is written only once it has launched, so
    /// without it two spawns in flight would compute the same title. The
    /// caller confirms once the session has really launched and releases on
    /// every other outcome, so a title that never reached a session can
    /// neither suppress a later send nor block another tab's title.
    ///
    /// A profile login spawn (`isLogin`, or a row labelled `login`) passes
    /// the bare display name and reserves nothing: a login tab is never
    /// titled, recorded or counted. A failed read of the rows falls back to
    /// the bare display name, bumped past any title another session holds.
    static func forSpawn(
        db: TBDDatabase,
        store: ClaudeSessionTitleStore,
        worktreeID: UUID,
        displayName: String,
        terminalID: UUID,
        isLogin: Bool = false
    ) async -> ClaudeSpawnTitle {
        let terminals = (try? await db.terminals.list(worktreeID: worktreeID)) ?? []
        let rowIsLogin = terminals.contains {
            $0.id == terminalID && $0.label == TerminalLabel.login
        }
        if isLogin || rowIsLogin {
            return ClaudeSpawnTitle(terminalID: terminalID, name: displayName, reservation: nil)
        }
        let labels = await tabLabels(db: db, worktreeID: worktreeID)
        return await store.reserve(
            terminalID: terminalID,
            worktreeID: worktreeID,
            displayName: displayName,
            terminals: terminals,
            tabLabels: labels)
    }

    /// The title to hand a Claude session on its next prompt, or nil when the
    /// session already carries it (or is not a titled Claude session at all:
    /// Codex, shell and profile login terminals get none).
    ///
    /// Sends only on change, against the title last given that session, so a
    /// user's own `/rename` survives until the wanted title next moves.
    static func forPrompt(
        db: TBDDatabase,
        store: ClaudeSessionTitleStore,
        terminal: Terminal
    ) async -> String? {
        guard isCountedClaudeTerminal(terminal),
              let worktree = try? await db.worktrees.get(id: terminal.worktreeID),
              let terminals = try? await db.terminals.list(worktreeID: terminal.worktreeID)
        else { return nil }
        let labels = await tabLabels(db: db, worktreeID: terminal.worktreeID)
        return await store.claimWanted(
            terminal: terminal,
            displayName: worktree.displayName,
            terminals: terminals,
            tabLabels: labels)
    }
}

/// The `--name` a Claude spawn passes, and the store's hold on it while the
/// spawn is in flight.
struct ClaudeSpawnTitle: Sendable, Equatable {
    let terminalID: UUID
    /// The `--name` value: the bare display name for a login spawn, nil
    /// when the display name sanitizes to nothing.
    let name: String?
    /// Identifies the reservation in `ClaudeSessionTitleStore`. Nil for a
    /// profile login spawn, which is never recorded.
    let reservation: UUID?
}

/// The title TBD last gave each Claude session, keyed by terminal id, plus
/// the titles reserved by spawns still in flight.
///
/// A spawn reserves its title when the title is computed
/// (`ClaudeSessionTitle.forSpawn`), so the uniqueness rule sees spawns whose
/// rows are not written yet. The spawn site then confirms the reservation
/// once the session has launched, or releases it — restoring whatever entry
/// it displaced — when nothing launched. Computing a title and reserving it
/// happen in one actor call, so two spawns can never both take the same one.
///
/// Every entry in a worktree, confirmed or reserved, blocks its title for
/// the worktree's other terminals, so entries must leave with their rows:
/// every path that deletes terminal rows calls `forget`. Rows removed by a
/// cascade from a deleted worktree leave entries behind that nothing reads,
/// since a deleted worktree gets no further spawns or prompts.
///
/// In memory only: after a daemon restart every live session gets its wanted
/// title once, on its next prompt. Persisting it would cost a column and a
/// migration for a rare, cosmetic case.
public actor ClaudeSessionTitleStore {
    private struct Entry: Sendable {
        let worktreeID: UUID
        /// Nil when the spawn passed no `--name`.
        let title: String?
        /// Set while the spawn that took `title` is in flight.
        let reservation: UUID?
    }

    private var entries: [UUID: Entry] = [:]
    /// For each reservation in flight, the confirmed entry it displaced, so
    /// a release can put that entry back.
    private var displaced: [UUID: Entry] = [:]

    public init() {}

    /// The title `terminalID` carries in the store — the last one given, or
    /// one reserved for a spawn of it in flight.
    func lastApplied(terminalID: UUID) -> String? {
        entries[terminalID]?.title
    }

    /// Whether a spawn of `terminalID` holds a reservation not yet confirmed
    /// or released.
    func isReserved(terminalID: UUID) -> Bool {
        entries[terminalID]?.reservation != nil
    }

    /// Every title held in `worktreeID`, given or reserved.
    func titles(worktreeID: UUID) -> [UUID: String] {
        var titles: [UUID: String] = [:]
        for (id, entry) in entries where entry.worktreeID == worktreeID {
            if let title = entry.title { titles[id] = title }
        }
        return titles
    }

    /// Set the title `terminalID` was given directly, as a confirmed entry.
    /// A nil title clears the entry.
    func record(terminalID: UUID, worktreeID: UUID, title: String?) {
        entries[terminalID] = title.map {
            Entry(worktreeID: worktreeID, title: $0, reservation: nil)
        }
    }

    /// Compute the wanted title for a spawn of `terminalID` and reserve it,
    /// in one step, so a concurrent spawn's computation sees it.
    func reserve(
        terminalID: UUID,
        worktreeID: UUID,
        displayName: String,
        terminals: [Terminal],
        tabLabels: [UUID: String]
    ) -> ClaudeSpawnTitle {
        let title = ClaudeSessionTitle.wanted(
            displayName: displayName,
            terminalID: terminalID,
            terminals: terminals,
            tabLabels: tabLabels,
            heldTitles: titles(worktreeID: worktreeID))
        let token = UUID()
        // A newer reservation supersedes an older one of the same terminal:
        // it takes over the entry the older displaced, so the older's
        // confirm or release becomes a no-op and this one's release restores
        // the entry from before both.
        var confirmed = entries[terminalID]
        if let older = confirmed?.reservation {
            confirmed = displaced.removeValue(forKey: older)
        }
        if let confirmed {
            displaced[token] = confirmed
        }
        entries[terminalID] = Entry(worktreeID: worktreeID, title: title, reservation: token)
        return ClaudeSpawnTitle(terminalID: terminalID, name: title, reservation: token)
    }

    /// The spawn launched: its reserved title is now the one it was given.
    /// A no-op when a newer reservation or a `forget` replaced it.
    func confirm(_ spawn: ClaudeSpawnTitle?) {
        guard let spawn, let token = spawn.reservation else { return }
        displaced[token] = nil
        guard let entry = entries[spawn.terminalID], entry.reservation == token else { return }
        entries[spawn.terminalID] = entry.title.map {
            Entry(worktreeID: entry.worktreeID, title: $0, reservation: nil)
        }
    }

    /// The spawn did not launch: drop its reservation and put back the entry
    /// it displaced. Only the reservation's own entry is touched, so a
    /// release never erases a newer entry.
    func release(_ spawn: ClaudeSpawnTitle?) {
        guard let spawn, let token = spawn.reservation else { return }
        let previous = displaced.removeValue(forKey: token)
        guard entries[spawn.terminalID]?.reservation == token else { return }
        entries[spawn.terminalID] = previous
    }

    /// Returns `title` and records it when it differs from the last one given;
    /// returns nil when the session already carries it.
    func claim(terminalID: UUID, worktreeID: UUID, title: String) -> String? {
        guard entries[terminalID]?.title != title else { return nil }
        entries[terminalID] = Entry(worktreeID: worktreeID, title: title, reservation: nil)
        return title
    }

    /// The prompt path: compute `terminal`'s wanted title and claim it, in
    /// one step. Nil while a spawn of the terminal is in flight, whose own
    /// `--name` lands with it. Nil, touching nothing, when `terminals` (the
    /// snapshot the caller read) has no row for the terminal: a late prompt
    /// hook from a closed tab must not re-create the entry `forget` removed.
    func claimWanted(
        terminal: Terminal,
        displayName: String,
        terminals: [Terminal],
        tabLabels: [UUID: String]
    ) -> String? {
        guard terminals.contains(where: { $0.id == terminal.id }) else { return nil }
        guard entries[terminal.id]?.reservation == nil else { return nil }
        guard let title = ClaudeSessionTitle.wanted(
            displayName: displayName,
            terminalID: terminal.id,
            terminals: terminals,
            tabLabels: tabLabels,
            heldTitles: titles(worktreeID: terminal.worktreeID))
        else { return nil }
        return claim(terminalID: terminal.id, worktreeID: terminal.worktreeID, title: title)
    }

    /// Drop `terminalID`'s entry, with whatever a reservation of it holds.
    /// Called on every path that deletes the terminal's row.
    func forget(terminalID: UUID) {
        if let token = entries[terminalID]?.reservation {
            displaced[token] = nil
        }
        entries[terminalID] = nil
    }

    func forget(worktreeID: UUID) {
        entries = entries.filter { $0.value.worktreeID != worktreeID }
        displaced = displaced.filter { $0.value.worktreeID != worktreeID }
    }
}
