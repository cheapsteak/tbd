import Foundation
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "transcript-sync")

/// Copy-if-newer synchronization of Claude session artifacts between
/// `projects/<munged-cwd>/` directories.
///
/// `claude --resume <id>` is cwd-scoped: it only looks for
/// `<projects-root>/<munged-current-cwd>/<id>.jsonl`. When a worktree's path
/// changes after a session's transcript was written — scratch-space promotion
/// moves the folder; the running session keeps appending to the transcript in
/// the OLD munged directory — the resume lookup misses. This unit mirrors
/// transcripts (and their `<id>/subagents/` companions) into the directory
/// derived from the worktree's CURRENT path.
///
/// Invariants:
/// - COPY, never move: live sessions keep appending to the original file, and
///   `terminal.transcriptPath` for a live session is never rewritten.
/// - Copy-if-newer: a destination file that is at least as fresh as the source
///   is left intact, so a newer forked/rolled-over transcript at the
///   destination is never clobbered by a stale snapshot.
/// - Best-effort: all failures are logged and swallowed; callers treat sync as
///   a freshness hint, not a precondition.
enum TranscriptProjectDirSync {

    // MARK: - Path derivation

    /// The munged project directory for `worktreePath` under `projectsRoot`,
    /// using Claude Code's exact encoding (`/` and `.` → `-`). Unlike
    /// `ClaudeProjectDirectory.resolve`, this does NOT require the directory to
    /// exist on disk — it names where the directory WOULD live, which is what a
    /// sync destination needs.
    static func derivedProjectDir(worktreePath: String, projectsRoot: URL) -> URL {
        let munged = worktreePath.map { "/.".contains($0) ? "-" : String($0) }.joined()
        return projectsRoot.appendingPathComponent(munged, isDirectory: true)
    }

    /// Projects root for a spawn's resolved profile config dir path. `nil` (an
    /// ambient spawn) falls back to the ambient host claude dir (`~/.claude`,
    /// honoring the `TBD_CLAUDE_HOST_HOME` test-isolation override). Handler
    /// code on `RPCRouter` should prefer `claudeProjectsRoot(...)` which routes
    /// through the router's injectable `configDirManager`.
    static func projectsRoot(profileConfigDirPath: String?) -> URL {
        if let path = profileConfigDirPath, !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent("projects", isDirectory: true)
        }
        return ClaudeProfileConfigDirManager().ambientConfigDirectory
            .appendingPathComponent("projects", isDirectory: true)
    }

    // MARK: - Copy-if-newer primitives

    private static func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// Copy `source` to `destination` unless the destination is already at
    /// least as fresh (mtime >= source's). Never overwrites a newer or
    /// equally-fresh destination. No-ops when source and destination resolve to
    /// the same physical file (symlinked `projects/` roots). Returns true when
    /// a copy actually happened.
    @discardableResult
    static func copyIfNewer(from source: URL, to destination: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return false }
        let sourceReal = source.resolvingSymlinksInPath().standardizedFileURL.path
        let destinationReal = destination.resolvingSymlinksInPath().standardizedFileURL.path
        guard sourceReal != destinationReal else { return false }

        if fm.fileExists(atPath: destination.path) {
            let sourceDate = modificationDate(source.path) ?? .distantPast
            let destinationDate = modificationDate(destination.path) ?? .distantPast
            guard destinationDate < sourceDate else { return false }  // destination fresh — leave intact
            do {
                try fm.removeItem(at: destination)
            } catch {
                logger.warning("copyIfNewer: could not replace stale \(destination.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return false
            }
        } else {
            try? fm.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        do {
            try fm.copyItem(at: source, to: destination)
            logger.debug("copyIfNewer: \(source.path, privacy: .public) -> \(destination.path, privacy: .public)")
            return true
        } catch {
            logger.warning("copyIfNewer: copy failed \(source.path, privacy: .public) -> \(destination.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Recursively sync the CONTENTS of `sourceDir` into `destDir`: files are
    /// copied with copy-if-newer semantics, subdirectories recurse. Missing or
    /// non-directory sources are a no-op, as is a destination that resolves to
    /// the same physical directory.
    static func syncDirectoryContents(from sourceDir: URL, to destDir: URL) {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: sourceDir.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }
        guard sourceDir.resolvingSymlinksInPath().standardizedFileURL.path
                != destDir.resolvingSymlinksInPath().standardizedFileURL.path else { return }

        let entries = (try? fm.contentsOfDirectory(
            at: sourceDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for entry in entries {
            let destination = destDir.appendingPathComponent(entry.lastPathComponent)
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                syncDirectoryContents(from: entry, to: destination)
            } else {
                copyIfNewer(from: entry, to: destination)
            }
        }
    }

    /// Sync one session's artifacts — the `<id>.jsonl` transcript plus its
    /// sibling `<id>/subagents/` directory — into `destProjectDir`, each with
    /// copy-if-newer semantics.
    static func syncSession(jsonl source: URL, intoProjectDir destProjectDir: URL) {
        let fileName = source.lastPathComponent                                 // <id>.jsonl
        let sessionDirName = source.deletingPathExtension().lastPathComponent   // <id>
        copyIfNewer(from: source, to: destProjectDir.appendingPathComponent(fileName))
        let sourceSubagents = source.deletingLastPathComponent()
            .appendingPathComponent(sessionDirName, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        let destSubagents = destProjectDir
            .appendingPathComponent(sessionDirName, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        syncDirectoryContents(from: sourceSubagents, to: destSubagents)
    }

    /// Locate `<sessionID>.jsonl` anywhere under `projectsRoot` — one shallow
    /// pass over the munged project directories, `fileExists` per dir. Session
    /// IDs are UUIDs, so any hit IS this session; when copy-if-newer snapshots
    /// have left multiple copies, the newest mtime wins. Used as the last
    /// resort by `ensureSessionResumable` when neither the stored transcript
    /// path nor the current path's resolved project dir has the file — the
    /// moved-while-archived case, where the transcript still sits under a slug
    /// derived from a path that no longer exists.
    static func locateSessionTranscript(sessionID: String, projectsRoot: URL) -> URL? {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
        var best: (url: URL, mtime: Date)?
        for dir in dirs {
            let values = try? dir.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            let candidate = dir.appendingPathComponent("\(sessionID).jsonl")
            guard fm.fileExists(atPath: candidate.path) else { continue }
            let mtime = modificationDate(candidate.path) ?? .distantPast
            if best == nil || mtime > best!.mtime {
                best = (candidate, mtime)
            }
        }
        return best?.url
    }

    /// Before a daemon-driven `claude --resume <sessionID>` spawn with cwd
    /// `worktreePath`: ensure `<derived-project-dir>/<sessionID>.jsonl` exists
    /// and is at least as fresh as the best-known source transcript; sync
    /// (copy-if-newer) when it's missing or stale.
    ///
    /// Source resolution, in order:
    /// 1. the stored `terminal.transcriptPath`, when it still exists on disk;
    /// 2. the session file inside the project dir `ClaudeProjectDirectory
    ///    .resolve` finds for the same path (which, when it IS the derived
    ///    dir, makes this a no-op);
    /// 3. a shallow by-session-ID scan across all of `projectsRoot`'s project
    ///    dirs (`locateSessionTranscript`) — covers archived sessions whose
    ///    worktree moved while no terminal row survived to store the path.
    /// With no source at all this is a no-op — the resume simply starts fresh,
    /// exactly as before.
    static func ensureSessionResumable(
        sessionID: String,
        worktreePath: String,
        projectsRoot: URL,
        storedTranscriptPath: String?
    ) {
        let fm = FileManager.default
        let destDir = derivedProjectDir(worktreePath: worktreePath, projectsRoot: projectsRoot)

        var source: URL?
        if let path = storedTranscriptPath, !path.isEmpty, fm.fileExists(atPath: path) {
            source = URL(fileURLWithPath: path)
        } else if let resolved = ClaudeProjectDirectory.resolve(
            worktreePath: worktreePath, projectsBase: projectsRoot
        ), fm.fileExists(atPath: resolved.appendingPathComponent("\(sessionID).jsonl").path) {
            source = resolved.appendingPathComponent("\(sessionID).jsonl")
        } else {
            source = locateSessionTranscript(sessionID: sessionID, projectsRoot: projectsRoot)
        }
        guard let source else { return }
        syncSession(jsonl: source, intoProjectDir: destDir)
    }

    // MARK: - Off-executor variants

    /// The synchronous entry points above do unbounded recursive filesystem
    /// work. Callers running on an actor's serial executor (e.g.
    /// `HibernationCoordinator.wake`) or inside RPC handler tasks must not
    /// block their executor on that walk — this repo has shipped two
    /// hang-class regressions from exactly this pattern. These wrappers hop
    /// to a detached task; awaiting them preserves per-call ordering (the
    /// sync completes before the dependent spawn) without monopolizing the
    /// caller's executor.
    static func ensureSessionResumableDetached(
        sessionID: String,
        worktreePath: String,
        projectsRoot: URL,
        storedTranscriptPath: String?
    ) async {
        await Task.detached {
            ensureSessionResumable(
                sessionID: sessionID,
                worktreePath: worktreePath,
                projectsRoot: projectsRoot,
                storedTranscriptPath: storedTranscriptPath
            )
        }.value
    }

    /// Detached-task variant of `syncDirectoryContents` — see
    /// `ensureSessionResumableDetached`.
    static func syncDirectoryContentsDetached(from sourceDir: URL, to destDir: URL) async {
        await Task.detached {
            syncDirectoryContents(from: sourceDir, to: destDir)
        }.value
    }

    /// Detached-task variant of `syncSession` — see
    /// `ensureSessionResumableDetached`.
    static func syncSessionDetached(jsonl source: URL, intoProjectDir destProjectDir: URL) async {
        await Task.detached {
            syncSession(jsonl: source, intoProjectDir: destProjectDir)
        }.value
    }
}
