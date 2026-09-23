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

    init(from entry: TerminalHistoryEntry) {
        self.id = entry.id.uuidString
        self.worktreeID = entry.worktreeID.uuidString
        self.label = entry.label
        self.kind = entry.kind?.rawValue
        self.closedAt = entry.closedAt
        self.claudeSessionID = entry.claudeSessionID
        self.lineCount = entry.lineCount
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
            lineCount: lineCount
        )
    }
}

/// Read-only closed-terminal history: at close time the daemon captures the
/// pane's scrollback so the user can view it later.
///
/// Captured TEXT is file-backed at
/// `~/tbd/terminal-history/<worktreeID>/<terminalID>.txt`
/// (`TBDConstants.terminalHistoryPath`); the DB row keeps display metadata.
/// Empty/whitespace-only captures store nothing (no file, no row) on the
/// tmux path (`captureOnClose`); the holder path (`recordOnClose`) writes the
/// row without a file instead.
public struct TerminalHistoryStore: Sendable {
    // ponytail: hard cap of the newest 50 captures per worktree; make it a
    // config knob only if someone actually asks for more retention.
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

    /// Best-effort capture at terminal close. Runs `capture`, then stores the
    /// text (file + metadata row) and prunes the worktree to the newest
    /// `maxEntriesPerWorktree` records. NEVER throws — any failure is logged
    /// and the close proceeds unchanged. Empty/whitespace-only captures store
    /// nothing.
    public func captureOnClose(terminal: Terminal, capture: () async throws -> String) async {
        let text: String
        do {
            text = try await capture()
        } catch {
            logger.warning("scrollback capture failed for terminal \(terminal.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        await store(terminal: terminal, text: text, closedAt: Date())
    }

    /// Holder-transport close: writes an entry whether or not there is a
    /// capture. NEVER throws.
    ///
    /// Unlike `captureOnClose`, a missing or blank capture still writes the
    /// metadata row (no content file, `lineCount` 0). A holder's screen can be
    /// unreadable at close for a reason that says nothing about the session —
    /// a viewer holds the pty, so the daemon's copy is frozen — and the entry
    /// is still what lets a Claude session be revived by its session id.
    /// Revive already handles a missing file (the shell path skips the `cat`),
    /// and the viewer reads a missing file as empty.
    ///
    /// A capture-less close of a terminal that already has an entry leaves
    /// that entry alone. A second close of one terminal is a retried teardown
    /// (the rows survived a failed delete or an unrecorded reconcile kill), and
    /// by then the first close has disposed the holder, so the retry can only
    /// answer "no capture": overwriting would throw away the first close's
    /// capture, as the tmux path never does when its capture fails.
    public func recordOnClose(terminal: Terminal, capture: String?) async {
        if Self.nonBlank(capture) == nil {
            do {
                let existing = try await writer.read { db in
                    try TerminalHistoryRecord.exists(db, key: terminal.id.uuidString)
                }
                if existing { return }
            } catch {
                logger.warning("failed to read closed-terminal history for \(terminal.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        await persist(terminal: terminal, text: capture, closedAt: Date())
    }

    /// Store seam (internal so tests can control `closedAt` for deterministic
    /// prune ordering). Best-effort: failures are logged, never thrown.
    func store(terminal: Terminal, text: String, closedAt: Date) async {
        guard Self.nonBlank(text) != nil else { return }
        await persist(terminal: terminal, text: text, closedAt: closedAt)
    }

    /// `text` unless it is empty or whitespace-only — the one statement of
    /// what counts as "no capture" for both close paths.
    private static func nonBlank(_ text: String?) -> String? {
        text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    /// Writes the content file (when there is non-blank text), the metadata
    /// row, and prunes. Without text it writes the row alone and removes any
    /// stray content file at the terminal's path, so the row's `lineCount` 0
    /// and the file the viewer and revive read cannot disagree.
    private func persist(terminal: Terminal, text rawText: String?, closedAt: Date) async {
        let text = Self.nonBlank(rawText)
        let path = contentPath(worktreeID: terminal.worktreeID, terminalID: terminal.id)
        do {
            if let text {
                try FileManager.default.createDirectory(
                    atPath: (path as NSString).deletingLastPathComponent,
                    withIntermediateDirectories: true
                )
                try text.write(toFile: path, atomically: true, encoding: .utf8)
            } else if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
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
                } ?? 0
            )
            let record = TerminalHistoryRecord(from: entry)
            let worktreeID = terminal.worktreeID
            let pruned = try await writer.write { db -> [String] in
                try record.save(db)
                // Prune to the newest N; rowid breaks closedAt ties (insertion order).
                let stale = try String.fetchAll(db, sql: """
                    SELECT id FROM terminal_history WHERE worktreeID = ?
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

    // MARK: - Queries

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
