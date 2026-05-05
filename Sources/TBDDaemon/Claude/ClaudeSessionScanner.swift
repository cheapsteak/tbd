import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "session-scanner")

// MARK: - ClaudeProjectDirectory

/// Resolves the ~/.claude/projects/<encoded-cwd>/ directory for a worktree path.
/// Three-tier lookup: exact encoding → regex fallback → full content scan.
/// Results are cached after first resolution.
enum ClaudeProjectDirectory {
    /// Cache entries: `.some(url)` for resolved hits, `.none` for confirmed
    /// misses. Caching negatives is essential — the tier-3 fallback enumerates
    /// every directory under `~/.claude/projects` and reads the first line of
    /// every session JSONL. Without negative caching, every repeat call for a
    /// worktree with no matching project dir re-runs that scan, which pegs the
    /// daemon at ~95% CPU when the app's 2s poll lists archived worktrees.
    private nonisolated(unsafe) static var cache: [String: URL?] = [:]
    private static let lock = NSLock()

    static func resolve(worktreePath: String, projectsBase: URL? = nil) -> URL? {
        let base = projectsBase ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects")

        lock.lock()
        if let cached = cache[worktreePath] {
            lock.unlock()
            // Re-validate hits against the filesystem so a deleted project
            // directory doesn't leave stale results in the cache. Negative
            // entries are returned as-is — a previously-missing dir reappearing
            // is rare enough that we don't pay the fexist cost on every call.
            if let url = cached {
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }
            return nil
        }
        lock.unlock()

        let result = resolveUncached(worktreePath: worktreePath, projectsBase: base)
        lock.lock()
        cache[worktreePath] = result
        lock.unlock()
        return result
    }

    /// Wipe the in-memory cache (for testing).
    static func clearCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    // MARK: Private

    private static func resolveUncached(worktreePath: String, projectsBase: URL) -> URL? {
        // Tier 1: exact (/ and . → -)
        let exact = worktreePath.map { "/." .contains($0) ? "-" : String($0) }.joined()
        let tier1 = projectsBase.appendingPathComponent(exact)
        if FileManager.default.fileExists(atPath: tier1.path) {
            logger.debug("Session dir via exact: \(tier1.path, privacy: .public)")
            return tier1
        }

        // Tier 2: regex (any non-alphanumeric run → single -)
        let regex = regexEncode(worktreePath)
        if regex != exact {
            let tier2 = projectsBase.appendingPathComponent(regex)
            if FileManager.default.fileExists(atPath: tier2.path) {
                logger.debug("Session dir via regex: \(tier2.path, privacy: .public)")
                return tier2
            }
        }

        // Tier 3: scan all project dirs for a matching cwd field
        return scanForCWD(worktreePath: worktreePath, projectsBase: projectsBase)
    }

    private static func regexEncode(_ path: String) -> String {
        var result = ""
        var inNonAlpha = false
        for ch in path {
            if ch.isLetter || ch.isNumber {
                result.append(ch)
                inNonAlpha = false
            } else if !inNonAlpha {
                result.append("-")
                inNonAlpha = true
            }
        }
        return result
    }

    private static func scanForCWD(worktreePath: String, projectsBase: URL) -> URL? {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: projectsBase, includingPropertiesForKeys: nil
        ) else { return nil }

        for dir in dirs where dir.hasDirectoryPath {
            guard
                let firstJSONL = (try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: nil
                ))?.first(where: { $0.pathExtension == "jsonl" }),
                let firstLine = readFirstNonEmptyLine(of: firstJSONL),
                let data = firstLine.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let cwd = json["cwd"] as? String
            else { continue }

            if cwd == worktreePath {
                logger.debug("Session dir via scan: \(dir.path, privacy: .public)")
                return dir
            }
        }
        return nil
    }

    private static func readFirstNonEmptyLine(of url: URL) -> String? {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? handle.close() }
        let chunk = handle.readData(ofLength: 1024)
        return String(data: chunk, encoding: .utf8)?
            .components(separatedBy: "\n")
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    }
}

// MARK: - ClaudeSessionScanner

enum ClaudeSessionScanner {

    /// Cheap count of `.jsonl` session files in a project directory. Does
    /// not parse contents, so a returned count of N means "there are N
    /// session files on disk" — files may still be empty stubs that
    /// `listSessions` would skip. Sufficient for filtering archived
    /// worktrees that have nothing left on disk.
    static func countSessionFiles(projectDir: URL) -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: nil) else {
            return 0
        }
        return entries.filter { $0.pathExtension == "jsonl" }.count
    }

    /// Lists all sessions in a project directory, sorted by mtime descending.
    static func listSessions(projectDir: URL) -> [SessionSummary] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let entries = try? fm.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: keys) else {
            return []
        }
        return entries
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { parseSummary(file: $0) }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    // MARK: Private

    private static func parseSummary(file: URL) -> SessionSummary? {
        let rv = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modifiedAt = rv?.contentModificationDate ?? Date.distantPast
        let fileSize = Int64(rv?.fileSize ?? 0)

        guard let handle = FileHandle(forReadingAtPath: file.path) else { return nil }
        defer { try? handle.close() }

        var lineCount = 0
        var firstUserMessage: String? = nil
        var lastUserMessage: String? = nil
        var sessionId: String? = nil
        var cwd: String? = nil
        var gitBranch: String? = nil
        var lastMessageAt: Date? = nil
        var buffer = Data()
        let iso8601 = ISO8601DateFormatter()

        func processLine(_ lineData: Data) {
            guard !lineData.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { return }
            lineCount += 1
            if sessionId == nil {
                sessionId  = json["sessionId"]  as? String
                cwd        = json["cwd"]        as? String
                gitBranch  = json["gitBranch"]  as? String
            }
            if UserMessageClassifier.isRealUserMessage(json),
               let text = UserMessageClassifier.extractText(json) {
                let truncated = String(text.prefix(300))
                if firstUserMessage == nil { firstUserMessage = truncated }
                lastUserMessage = truncated
            }
            if let ts = json["timestamp"] as? String, let date = iso8601.date(from: ts) {
                lastMessageAt = date
            }
        }

        let chunkSize = 65_536
        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            guard !chunk.isEmpty else { break }
            buffer.append(chunk)
            while let nl = buffer.range(of: Data([0x0A])) {
                let lineData = Data(buffer[buffer.startIndex..<nl.lowerBound])
                buffer.removeSubrange(buffer.startIndex...nl.lowerBound)
                processLine(lineData)
            }
        }
        // Trailing line without newline
        if !buffer.isEmpty { processLine(buffer) }

        return SessionSummary(
            sessionId: sessionId ?? file.deletingPathExtension().lastPathComponent,
            filePath: file.path,
            modifiedAt: modifiedAt,
            fileSize: fileSize,
            lineCount: lineCount,
            firstUserMessage: firstUserMessage,
            lastUserMessage: lastUserMessage,
            cwd: cwd,
            gitBranch: gitBranch,
            lastMessageAt: lastMessageAt
        )
    }

    /// Returns true if the session JSONL for `sessionID` (resolved within the
    /// per-worktree project dir) is missing, empty, or contains no
    /// user/assistant entries with text content. Metadata-only files
    /// (permission-mode, file-history-snapshot, etc.) are considered blank.
    static func isSessionBlank(
        sessionID: String,
        worktreePath: String,
        projectsBase: URL? = nil
    ) -> Bool {
        guard let projectDir = ClaudeProjectDirectory.resolve(
            worktreePath: worktreePath,
            projectsBase: projectsBase
        ) else {
            logger.debug("isSessionBlank: project dir unresolved for \(worktreePath, privacy: .public) — treating as blank")
            return true
        }
        let file = projectDir.appendingPathComponent("\(sessionID).jsonl")
        guard FileManager.default.fileExists(atPath: file.path) else {
            logger.debug("isSessionBlank: file missing \(file.path, privacy: .public)")
            return true
        }
        guard let handle = FileHandle(forReadingAtPath: file.path) else { return true }
        defer { try? handle.close() }

        var buffer = Data()
        var hasContent = false

        func processLine(_ lineData: Data) {
            guard !hasContent, !lineData.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { return }
            let type = json["type"] as? String
            guard type == "user" || type == "assistant" else { return }
            guard let message = json["message"] as? [String: Any] else { return }
            if let content = message["content"] as? String, !content.isEmpty {
                hasContent = true
                return
            }
            if let array = message["content"] as? [[String: Any]] {
                for block in array {
                    if let text = block["text"] as? String, !text.isEmpty {
                        hasContent = true
                        return
                    }
                }
            }
        }

        let chunkSize = 65_536
        while !hasContent {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nl = buffer.range(of: Data([0x0A])) {
                let lineData = Data(buffer[buffer.startIndex..<nl.lowerBound])
                buffer.removeSubrange(buffer.startIndex...nl.lowerBound)
                processLine(lineData)
                if hasContent { break }
            }
        }
        if !hasContent && !buffer.isEmpty { processLine(buffer) }

        return !hasContent
    }

    /// Load all chat messages from a JSONL session file, in file order.
    static func loadMessages(filePath: String) -> [ChatMessage] {
        guard let handle = FileHandle(forReadingAtPath: filePath) else { return [] }
        defer { try? handle.close() }

        var messages: [ChatMessage] = []
        var buffer = Data()
        let iso8601 = ISO8601DateFormatter()

        func processLine(_ lineData: Data) {
            guard !lineData.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { return }

            let timestamp: Date? = (json["timestamp"] as? String).flatMap { iso8601.date(from: $0) }
            // Stable per-line ID from the JSONL — keeps SwiftUI ForEach diffing
            // and live-pane equality checks correct across re-parses. Falls back
            // to a fresh UUID for older lines that predate the field.
            let lineID = (json["uuid"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()

            let typeStr = json["type"] as? String

            if typeStr == "user" && UserMessageClassifier.isRealUserMessage(json),
               let text = UserMessageClassifier.extractText(json) {
                messages.append(ChatMessage(id: lineID, role: .user, text: text, timestamp: timestamp))
                return
            }

            if typeStr == "assistant" {
                guard let message = json["message"] as? [String: Any] else { return }
                let text: String?
                if let contentStr = message["content"] as? String {
                    text = contentStr.isEmpty ? nil : contentStr
                } else if let contentArray = message["content"] as? [[String: Any]] {
                    text = contentArray
                        .first(where: { $0["type"] as? String == "text" })
                        .flatMap { $0["text"] as? String }
                        .flatMap { $0.isEmpty ? nil : $0 }
                } else {
                    text = nil
                }
                if let text {
                    messages.append(ChatMessage(id: lineID, role: .assistant, text: text, timestamp: timestamp))
                }
            }
        }

        let chunkSize = 65_536
        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            guard !chunk.isEmpty else { break }
            buffer.append(chunk)
            while let nl = buffer.range(of: Data([0x0A])) {
                let lineData = Data(buffer[buffer.startIndex..<nl.lowerBound])
                buffer.removeSubrange(buffer.startIndex...nl.lowerBound)
                processLine(lineData)
            }
        }
        if !buffer.isEmpty { processLine(buffer) }

        return messages
    }
}
