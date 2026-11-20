import Foundation
import GRDB
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "terminalHistory")

/// GRDB Record type for the `terminal_history` table.
struct TerminalHistoryRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "terminal_history"

    var id: String
    var worktreeID: String
    var label: String?
    var kind: String?
    var closedAt: Date
    var claudeSessionID: String?
    var lineCount: Int
    var serverName: String?
    var exitCode: Int32?
    /// JSON-encoded `ClaudeSpawnExtras` copied from the closing terminal row.
    var claudeSpawnExtras: String?
    /// The tmux server a deleted live tmux row's session may still run in
    /// (`TerminalHistoryEntry.liveOnTmuxServer`).
    var liveOnTmuxServer: String?

    init(from entry: TerminalHistoryEntry) {
        self.id = entry.id.uuidString
        self.worktreeID = entry.worktreeID.uuidString
        self.label = entry.label
        self.kind = entry.kind?.rawValue
        self.closedAt = entry.closedAt
        self.claudeSessionID = entry.claudeSessionID
        self.lineCount = entry.lineCount
        self.serverName = entry.serverName
        self.exitCode = entry.exitCode
        self.claudeSpawnExtras = ClaudeSpawnExtrasColumn.encode(entry.claudeSpawnExtras)
        self.liveOnTmuxServer = entry.liveOnTmuxServer
    }

    /// Failable decode: skips (returns nil after a logged warning) rather than
    /// crashing when a required UUID fails to parse.
    func toModel() -> TerminalHistoryEntry? {
        guard let uuid = UUID(uuidString: id) else {
            logger.warning("Skipping terminal_history row \(id, privacy: .public): malformed id")
            return nil
        }
        guard let wtID = UUID(uuidString: worktreeID) else {
            logger.warning("Skipping terminal_history row \(id, privacy: .public): malformed worktreeID \(worktreeID, privacy: .public)")
            return nil
        }
        return TerminalHistoryEntry(
            id: uuid,
            worktreeID: wtID,
            label: label,
            kind: kind.flatMap(TerminalKind.init(rawValue:)),
            closedAt: closedAt,
            claudeSessionID: claudeSessionID,
            lineCount: lineCount,
            serverName: serverName,
            exitCode: exitCode,
            claudeSpawnExtras: ClaudeSpawnExtrasColumn.decode(
                claudeSpawnExtras, table: Self.databaseTableName, rowID: id),
            liveOnTmuxServer: liveOnTmuxServer
        )
    }
}

/// Read-only closed-terminal history: at close time the daemon captures the
/// terminal's screen and scrollback so the user can view it later.
///
/// Captured TEXT is file-backed at
/// `~/tbd/terminal-history/<worktreeID>/<terminalID>.txt`
/// (`TBDConstants.terminalHistoryPath`); the DB row keeps display metadata.
/// A close with no capture, or an empty or whitespace-only one, writes the
/// row without a file (`recordOnClose`). Entries for a dev server's saved last
/// output carry `serverName` and `exitCode` (`recordServerExit`). The entry of
/// a live tmux row TBD deleted carries the tmux server its session may still
/// run in (`recordLiveTmuxClose`).
public struct TerminalHistoryStore: Sendable {
    // ponytail: hard cap of the newest 50 captures per worktree; make it a
    // config knob only if someone actually asks for more retention. An entry
    // marked `liveOnTmuxServer` is outside the cap: the mark is what keeps a
    // resume of its session from starting a second agent, so it stays until
    // the worktree's history is deleted.
    static let maxEntriesPerWorktree = 50

    let writer: any DatabaseWriter
    /// Injection seam for tests (like `NoteStore.notesDirOverride`): nil
    /// resolves `TBDConstants.terminalHistoryDir` (which honors TBD_HOME)
    /// at call time.
    let historyDirOverride: String?

    init(writer: any DatabaseWriter, historyDir: String? = nil) {
        self.writer = writer
        self.historyDirOverride = historyDir
    }

    // MARK: - Content files

    func worktreeDir(worktreeID: UUID) -> String {
        let base = historyDirOverride ?? TBDConstants.terminalHistoryDir.path
        return (base as NSString).appendingPathComponent(worktreeID.uuidString)
    }

    func contentPath(worktreeID: UUID, terminalID: UUID) -> String {
        (worktreeDir(worktreeID: worktreeID) as NSString)
            .appendingPathComponent("\(terminalID.uuidString).txt")
    }

    // MARK: - Capture

    /// Terminal close: writes an entry whether or not there is a capture, then
    /// prunes the worktree to the newest `maxEntriesPerWorktree` records.
    /// NEVER throws — any failure is logged and the close proceeds unchanged.
    ///
    /// A missing or blank capture still writes the metadata row (no content
    /// file, `lineCount` 0). A holder's screen can be unreadable at close for a
    /// reason that says nothing about the session — a viewer holds the pty, so
    /// the daemon's copy is frozen — and the entry is still what lets a Claude
    /// session be revived by its session id.
    /// Revive already handles a missing file (the shell path skips the `cat`),
    /// and the viewer reads a missing file as empty.
    ///
    /// A capture-less close of a terminal that already has an entry leaves
    /// that entry alone. A second close of one terminal is a retried teardown
    /// (the rows survived a failed delete or an unrecorded reconcile teardown),
    /// and by then the first close has disposed the holder, so the retry can
    /// only answer "no capture": overwriting would throw away the first
    /// close's capture. The check and the insert are one transaction, and a
    /// capture-less close touches no file, so it cannot remove a capture a
    /// concurrent close is writing.
    public func recordOnClose(terminal: Terminal, capture: String?) async {
        await persist(
            terminal: terminal, text: Self.nonBlank(capture), closedAt: Date(),
            keepingExistingEntryWithoutText: true)
    }

    /// Close of a live tmux row, which TBD deletes without running tmux, so
    /// the session it carried may keep running in `server`. Writes the entry
    /// as a capture-less `recordOnClose` does, marked with `server`, and marks
    /// the terminal's existing entry when it already has one. The mark is what
    /// every resume of the entry's session id asks about before it starts that
    /// session on the pty holder (`TmuxResumeGate`). NEVER throws.
    public func recordLiveTmuxClose(terminal: Terminal, server: String) async {
        await persist(
            terminal: terminal, text: nil, closedAt: Date(),
            keepingExistingEntryWithoutText: true, liveOnTmuxServer: server)
    }

    /// Store seam (internal so tests can control `closedAt` for deterministic
    /// prune ordering). Best-effort: failures are logged, never thrown.
    func store(terminal: Terminal, text: String, closedAt: Date) async {
        guard let text = Self.nonBlank(text) else { return }
        await persist(terminal: terminal, text: text, closedAt: closedAt)
    }

    /// `text` unless it is empty or whitespace-only — the one statement of
    /// what counts as "no capture" for every close path. Scans only up to the
    /// first visible character rather than trimming a copy of the capture.
    private static func nonBlank(_ text: String?) -> String? {
        guard let text, text.unicodeScalars.contains(where: {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }) else { return nil }
        return text
    }

    /// Writes the content file (when there is text — callers pass it through
    /// `nonBlank`), the metadata row, and prunes. Without text it writes the
    /// row alone, and with `keepingExistingEntryWithoutText` only when the
    /// terminal has no entry yet; a kept entry still takes `liveOnTmuxServer`.
    /// A re-save never clears a mark the entry already has.
    private func persist(
        terminal: Terminal, text: String?, closedAt: Date,
        keepingExistingEntryWithoutText: Bool = false,
        liveOnTmuxServer: String? = nil
    ) async {
        let path = contentPath(worktreeID: terminal.worktreeID, terminalID: terminal.id)
        let keepExisting = keepingExistingEntryWithoutText && text == nil
        do {
            if let text {
                try FileManager.default.createDirectory(
                    atPath: (path as NSString).deletingLastPathComponent,
                    withIntermediateDirectories: true
                )
                try text.write(toFile: path, atomically: true, encoding: .utf8)
            }

            let entry = TerminalHistoryEntry(
                id: terminal.id,
                worktreeID: terminal.worktreeID,
                label: terminal.label,
                kind: terminal.kind,
                closedAt: closedAt,
                claudeSessionID: terminal.claudeSessionID,
                lineCount: text.map {
                    $0.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
                } ?? 0,
                // A Claude tab's values only. A failed pre-session hook's
                // shell row keeps the create's values while its tab lives,
                // and a reopen of a shell entry has no use for them.
                claudeSpawnExtras: terminal.isClaudeTab ? terminal.claudeSpawnExtras : nil,
                liveOnTmuxServer: liveOnTmuxServer
            )
            let record = TerminalHistoryRecord(from: entry)
            let worktreeID = terminal.worktreeID
            let pruned = try await writer.write { db -> [String] in
                if keepExisting,
                   try TerminalHistoryRecord.exists(db, key: record.id) {
                    if let liveOnTmuxServer {
                        try db.execute(
                            sql: "UPDATE terminal_history SET liveOnTmuxServer = ? WHERE id = ?",
                            arguments: [liveOnTmuxServer, record.id])
                    }
                    return []
                }
                // A re-save (a later close of the same tab) carries no server
                // fields — they are stamped only by `recordServerExit`. Keep
                // the stored ones, or closing an exited server's tab would
                // silently clear its saved last output. Its tmux mark is kept
                // the same way.
                var saved = record
                if let existing = try TerminalHistoryRecord.fetchOne(db, key: saved.id) {
                    if saved.serverName == nil {
                        saved.serverName = existing.serverName
                        saved.exitCode = existing.exitCode
                    }
                    saved.liveOnTmuxServer = saved.liveOnTmuxServer ?? existing.liveOnTmuxServer
                }
                try saved.save(db)
                // Prune to the newest N unmarked entries; rowid breaks
                // closedAt ties (insertion order).
                let stale = try String.fetchAll(db, sql: """
                    SELECT id FROM terminal_history
                    WHERE worktreeID = ? AND liveOnTmuxServer IS NULL
                    ORDER BY closedAt DESC, rowid DESC LIMIT -1 OFFSET ?
                    """, arguments: [worktreeID.uuidString, Self.maxEntriesPerWorktree])
                if !stale.isEmpty {
                    try TerminalHistoryRecord.filter(keys: stale).deleteAll(db)
                }
                return stale
            }
            for staleID in pruned {
                guard let staleUUID = UUID(uuidString: staleID) else { continue }
                let stalePath = contentPath(worktreeID: worktreeID, terminalID: staleUUID)
                try? FileManager.default.removeItem(atPath: stalePath)
            }
        } catch {
            logger.warning("failed to store closed-terminal history for \(terminal.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Dev server last output

    /// A dev server's final output, saved when its holder-backed command
    /// exits (docs/specs/2026-10-11-dev-servers-design.md, "Exited servers
    /// keep their last output"). Writes the entry exactly as `recordOnClose`
    /// does, then stamps the server's name and exit code on it — only while
    /// the terminal row still exists. A stop closes the server's tab, which
    /// deletes the row, before it detaches the server's entries, so an exit
    /// the stop itself caused can never leave the server reading *Exited*.
    /// NEVER throws.
    public func recordServerExit(
        terminal: Terminal, serverName: String, capture: String?, exitCode: Int32?
    ) async {
        await recordOnClose(terminal: terminal, capture: capture)
        let id = terminal.id.uuidString
        do {
            try await writer.write { db in
                try db.execute(sql: """
                    UPDATE terminal_history SET serverName = ?, exitCode = ?
                    WHERE id = ? AND EXISTS (SELECT 1 FROM terminal WHERE id = ?)
                    """, arguments: [serverName, exitCode, id, id])
            }
        } catch {
            logger.warning("failed to stamp dev server output for \(terminal.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Claude session IDs of closed-terminal history rows whose worktree is not
    /// archived: sessions a person can still resume through
    /// `terminalHistory.revive`. Raw columns, so a row whose other columns fail
    /// to decode still counts; `OrphanGC`'s session-directory arm reclaims
    /// whatever is NOT referenced. Codex native thread IDs never own a Claude
    /// session directory, including rows identified by the legacy Codex label.
    public func claudeSessionReferencesInUnarchivedWorktrees() async throws -> Set<String> {
        try await writer.read { db in
            Set(try String.fetchAll(db, sql: """
                SELECT h.claudeSessionID FROM terminal_history h
                JOIN worktree w ON w.id = h.worktreeID
                WHERE h.claudeSessionID IS NOT NULL AND w.status != ?
                AND h.kind IS NOT ? AND h.label IS NOT ?
                """, arguments: [WorktreeStatus.archived.rawValue,
                    TerminalKind.codex.rawValue, TerminalLabel.codex]))
        }
    }

    /// The newest entry still attached to each dev server in a worktree,
    /// keyed by server name. Ties on `closedAt` break by insertion order, as
    /// the prune does.
    public func latestServerOutputs(worktreeID: UUID) async throws -> [String: TerminalHistoryEntry] {
        try await writer.read { db in
            let records = try TerminalHistoryRecord.fetchAll(db, sql: """
                SELECT * FROM terminal_history
                WHERE worktreeID = ? AND serverName IS NOT NULL
                ORDER BY closedAt DESC, rowid DESC
                """, arguments: [worktreeID.uuidString])
            var latest: [String: TerminalHistoryEntry] = [:]
            for record in records {
                guard let name = record.serverName, latest[name] == nil,
                      let entry = record.toModel() else { continue }
                latest[name] = entry
            }
            return latest
        }
    }

    /// Detaches a server's saved outputs from it; `server.start` and
    /// `server.stop` call this. The entries stay in Closed Terminals as
    /// ordinary entries but no longer make the server read *Exited*.
    /// NEVER throws.
    public func detachServerOutput(worktreeID: UUID, serverName: String) async {
        do {
            try await writer.write { db in
                try db.execute(sql: """
                    UPDATE terminal_history SET serverName = NULL, exitCode = NULL
                    WHERE worktreeID = ? AND serverName = ?
                    """, arguments: [worktreeID.uuidString, serverName])
            }
        } catch {
            logger.warning("failed to detach dev server output for \(serverName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Detaches every server's saved outputs in a worktree; archive calls
    /// this once the worktree's terminal rows are gone, so no exit archive
    /// itself caused — nor any earlier one — makes a server read *Exited*
    /// after a revive. NEVER throws.
    public func detachAllServerOutputs(worktreeID: UUID) async {
        do {
            try await writer.write { db in
                try db.execute(sql: """
                    UPDATE terminal_history SET serverName = NULL, exitCode = NULL
                    WHERE worktreeID = ? AND serverName IS NOT NULL
                    """, arguments: [worktreeID.uuidString])
            }
        } catch {
            logger.warning("failed to detach dev server outputs for \(worktreeID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Queries

    /// The tmux servers the marked entries of `sessionIDs` name, in any
    /// worktree, each once and in name order: the servers those sessions may
    /// still be running in (`recordLiveTmuxClose`). Empty when none of them is
    /// marked, which is one read of the marked entries' index.
    public func liveOnTmuxServers(sessionIDs: [String]) async throws -> [String] {
        guard !sessionIDs.isEmpty else { return [] }
        return try await writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT liveOnTmuxServer FROM terminal_history
                WHERE liveOnTmuxServer IS NOT NULL
                AND claudeSessionID IN (\(databaseQuestionMarks(count: sessionIDs.count)))
                ORDER BY liveOnTmuxServer
                """, arguments: StatementArguments(sessionIDs))
        }
    }

    /// List capture metadata for a worktree, newest first.
    public func list(worktreeID: UUID) async throws -> [TerminalHistoryEntry] {
        try await writer.read { db in
            try TerminalHistoryRecord
                .filter(Column("worktreeID") == worktreeID.uuidString)
                .order(Column("closedAt").desc)
                .fetchAll(db)
                .compactMap { $0.toModel() }
        }
    }

    /// Delete all history rows for a worktree AND its content directory.
    /// Called from the worktree hard-delete paths (forget, scratch delete,
    /// recovery cleanup) — archive deliberately keeps history.
    public func deleteForWorktree(worktreeID: UUID) async throws {
        _ = try await writer.write { db in
            try TerminalHistoryRecord
                .filter(Column("worktreeID") == worktreeID.uuidString)
                .deleteAll(db)
        }
        let dir = worktreeDir(worktreeID: worktreeID)
        if FileManager.default.fileExists(atPath: dir) {
            try? FileManager.default.removeItem(atPath: dir)
        }
    }
}
