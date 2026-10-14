import Foundation
import TBDShared

/// The title a Claude session in a worktree should carry: what `--name` sets
/// at spawn and what the `UserPromptSubmit` hook hands back as
/// `hookSpecificOutput.sessionTitle` after a rename. One function for both, so
/// a spawn name and a later hook title never disagree.
///
/// - **Base:** the worktree's display name, through
///   `ClaudeSpawnCommandBuilder.sanitizedSessionName`.
/// - **Suffix:** the first Claude terminal in the worktree, by creation order,
///   gets none. Each later one gets ` · <label>` when its label is one a
///   caller supplied, otherwise ` · <n>` with `n` its 1-based position among
///   the worktree's Claude terminals.
///
/// See `docs/specs/2026-10-14-session-title-sync-design.md`.
enum ClaudeSessionTitle {
    /// Separator between the display name and a later terminal's suffix.
    static let separator = " · "

    /// Whether a row counts as a Claude terminal when numbering a worktree's
    /// Claude sessions. A nil `kind` is a legacy row, which reads as Claude
    /// only when it carries a session id — the same reading
    /// `isClaudeResumable` gives such rows.
    static func isClaudeTerminal(_ terminal: Terminal) -> Bool {
        guard !terminal.isCodexTerminal else { return false }
        if let kind = terminal.kind { return kind == .claude }
        return terminal.claudeSessionID != nil
    }

    /// The wanted title for `terminalID`, or nil when the display name
    /// sanitizes to nothing.
    ///
    /// `terminals` is the worktree's rows. The target counts as a Claude
    /// terminal whatever its row says, because the caller is asking on behalf
    /// of a Claude session (a Codex tab handed over to Claude still wears its
    /// old kind until the swap commits). When the target has no row yet — a
    /// spawn whose row is written after the command is built — it is placed
    /// after every existing Claude terminal, with `label` as its label.
    static func wanted(
        displayName: String,
        terminalID: UUID,
        label: String?,
        terminals: [Terminal]
    ) -> String? {
        guard let base = ClaudeSpawnCommandBuilder.sanitizedSessionName(displayName) else {
            return nil
        }
        // The same order `TerminalStore.list` uses, so a title computed from
        // an unsorted array matches one computed from the store's.
        let claude = terminals
            .filter { $0.id == terminalID || isClaudeTerminal($0) }
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        let position: Int
        let ownLabel: String?
        if let index = claude.firstIndex(where: { $0.id == terminalID }) {
            position = index
            ownLabel = claude[index].label
        } else {
            position = claude.count
            ownLabel = label
        }
        guard position > 0 else { return base }
        let suffix = userLabel(ownLabel) ?? String(position + 1)
        // Shorten the base rather than letting the length cap cut the suffix
        // off: two tabs whose suffixes were truncated away would share a name.
        let tail = separator + suffix
        let room = max(0, ClaudeSpawnCommandBuilder.maxSessionNameLength - tail.count)
        let shortened = String(base.prefix(room)).trimmingCharacters(in: .whitespacesAndNewlines)
        return ClaudeSpawnCommandBuilder.sanitizedSessionName(shortened + tail) ?? base
    }

    /// A label worth putting in a title: one a caller supplied, not one of the
    /// daemon's identities. `"claude"` is excluded as well — the resume arm of
    /// `terminal.create` writes it, and it is not a name anybody chose.
    static func userLabel(_ label: String?) -> String? {
        guard let supplied = TerminalLabel.userSupplied(label),
              supplied.lowercased() != "claude" else { return nil }
        return ClaudeSpawnCommandBuilder.sanitizedSessionName(supplied)
    }

    /// The `--name` for a Claude spawn into `worktreeID`, recorded in `store`
    /// as the title that session was given.
    ///
    /// Reads the worktree's terminal rows; a failed read falls back to the
    /// bare display name, which is what every spawn passed before suffixes
    /// existed.
    static func forSpawn(
        db: TBDDatabase,
        store: ClaudeSessionTitleStore,
        worktreeID: UUID,
        displayName: String,
        terminalID: UUID,
        label: String?
    ) async -> String? {
        let terminals = (try? await db.terminals.list(worktreeID: worktreeID)) ?? []
        let title = wanted(
            displayName: displayName,
            terminalID: terminalID,
            label: label,
            terminals: terminals)
        await store.record(terminalID: terminalID, worktreeID: worktreeID, title: title)
        return title
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
        // Rows that are gone take their entries with them; this catches the
        // removal paths that do not tell the store themselves.
        await store.retainOnly(
            worktreeID: terminal.worktreeID,
            terminalIDs: Set(terminals.map(\.id)))
        guard let title = wanted(
            displayName: worktree.displayName,
            terminalID: terminal.id,
            label: terminal.label,
            terminals: terminals)
        else { return nil }
        return await store.claim(
            terminalID: terminal.id, worktreeID: terminal.worktreeID, title: title)
    }
}

/// The title TBD last gave each Claude session, keyed by terminal id.
///
/// In memory only: after a daemon restart every live session gets its wanted
/// title once, on its next prompt. Persisting it would cost a column and a
/// migration for a rare, cosmetic case.
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

    /// Record the title a spawn gave its session. A nil title clears the entry.
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

    /// Drop every entry for `worktreeID` whose terminal is not in
    /// `terminalIDs`.
    func retainOnly(worktreeID: UUID, terminalIDs: Set<UUID>) {
        entries = entries.filter {
            $0.value.worktreeID != worktreeID || terminalIDs.contains($0.key)
        }
    }
}
