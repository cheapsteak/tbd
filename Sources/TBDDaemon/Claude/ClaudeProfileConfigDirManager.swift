import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "claudeProfileConfigDir")

/// Manages per-profile isolated `CLAUDE_CONFIG_DIR` directories under
/// `~/tbd/profiles/<profile-id>/claude/`. Serves oauth, direct apiKey, and
/// proxy apiKey profiles with an isolated config directory where they can
/// maintain independent credentials.
///
/// Each profile dir mirrors slots from the host's `~/.claude/` directory via
/// symlinks. Nine are host *customizations* — `projects/`, `plugins/`,
/// `skills/`, `agents/`, `commands/`, `hooks/`, `CLAUDE.md`,
/// `settings.json`, and `keybindings.json` — and the tenth, `sessions/`, is not a customization at all
/// but Claude Code's live cross-session peer registry, mirrored so profiles can
/// see each other's sessions (see `mirrorSlots`). Per-profile identity
/// (`.claude.json`, Keychain entry keyed on `CLAUDE_CONFIG_DIR` path, and
/// `.credentials.json` as a fallback when Keychain is unavailable) is
/// owned by each profile. The `apiKeyHelper` mode uses the profile's Keychain
/// entry as a bridge; do not store API keys outside the per-profile context.
///
/// On dir creation for API-key profiles, `.claude.json` is pre-populated with:
///   - `customApiKeyResponses.approved`: the last 20 chars of the profile's
///     API key (matches Claude Code's own storage format) so the user isn't
///     prompted to approve the key on first invocation.
///   - `hasCompletedOnboarding: true` so the spawn doesn't drop into the
///     onboarding flow inside an empty config dir.
///
/// For OAuth profiles, `.claude.json` is pre-populated with only:
///   - `hasCompletedOnboarding: true` (no `customApiKeyResponses`, since the
///     user will `/login` into this isolated config dir). An existing file
///     that lacks the key gets it added, every other key kept.
public struct ClaudeProfileConfigDirManager: Sendable {
    let baseDirectory: URL
    let hostBaseDirectory: URL

    /// The host Claude store: `TBD_CLAUDE_HOST_HOME` when set, `~/.claude`
    /// otherwise. **The single resolution point for that override** — anything
    /// that hand-builds `homeDirectoryForCurrentUser/.claude` escapes the fence
    /// `scripts/test.sh` puts around the developer's real store, which is how
    /// `LegacyHookScanner.globalSettingsPath` came to name the real
    /// `settings.json` under the wrapper.
    ///
    /// - Parameter environment: the environment to read, or `nil` for the
    ///   process's. `nil`-and-resolve-in-the-body rather than a
    ///   `ProcessInfo.processInfo.environment` default argument: a defaulted
    ///   cross-module computed class property is the shape behind the Xcode
    ///   26.3 `unsafeMutableAddressor` link failure (see
    ///   `Sources/TBDShared/HookResolver.swift`), and it would snapshot the
    ///   whole environ even at call sites that discard the result.
    ///
    ///   A test asserting the *production* `~/.claude` fallback passes `[:]`
    ///   rather than unsetting the process-global variable, which would hand
    ///   every concurrently running suite the real host store.
    public static func resolveHostBaseDirectory(environment: [String: String]? = nil) -> URL {
        // Delegates to `TBDConstants.claudeHostHome(environment:)`, which is
        // where the resolution actually lives now that `TBDApp` — which does
        // not link `TBDDaemonLib` — needs it as well. This entry point stays as
        // the daemon-side name every call site and doc reference already uses.
        TBDConstants.claudeHostHome(environment: environment ?? ProcessInfo.processInfo.environment)
    }

    /// - Parameter hostEnvironment: the environment `TBD_CLAUDE_HOST_HOME` is
    ///   read from when `hostBaseDirectory` is not injected, or `nil` for the
    ///   process's. Named for what it governs: `baseDirectory`'s own fallback
    ///   still reads `TBD_HOME` through `TBDConstants.configDir`, which this
    ///   parameter does not reach. Read below the `hostBaseDirectory` guard, so
    ///   an explicit injection never pays for an environ snapshot it discards.
    public init(baseDirectory: URL? = nil,
                hostBaseDirectory: URL? = nil,
                hostEnvironment: [String: String]? = nil) {
        // Resolve inside the init to keep the `TBDConstants.configDir` access
        // out of the caller's compilation context — see HookResolver for the
        // Xcode 26.3 unsafeMutableAddressor link-failure rationale.
        self.baseDirectory = baseDirectory
            ?? TBDConstants.configDir.appendingPathComponent("profiles", isDirectory: true)

        self.hostBaseDirectory = hostBaseDirectory
            ?? Self.resolveHostBaseDirectory(environment: hostEnvironment)
    }

    public func profileDirectory(forProfileID profileID: UUID) -> URL {
        baseDirectory
            .appendingPathComponent(profileID.uuidString.lowercased(), isDirectory: true)
    }

    public func configDirectory(forProfileID profileID: UUID) -> URL {
        profileDirectory(forProfileID: profileID)
            .appendingPathComponent("claude", isDirectory: true)
    }

    /// The ambient (non-profile) claude config dir — i.e. the host base dir
    /// (`~/.claude` in production, or the injected `hostBaseDirectory`). This is
    /// the config dir an ambient TBD session resolves to on this machine now
    /// that the zshenv-era ambient-dir switcher was retired. Used as the
    /// swap-to-ambient transcript destination.
    public var ambientConfigDirectory: URL {
        hostBaseDirectory
    }

    /// Slots that each TBD profile dir mirrors from the host's claude config dir.
    /// Symlinked from <profile>/claude/<slot> to <host-base>/<slot>.
    /// `projects` migrates pre-existing real-dir content into the host store
    /// before symlinking (byte-identical duplicates dropped, diverged
    /// transcripts resolved longer-wins with a backup, alias symlinks dropped;
    /// any other collision aborts the whole migration atomically), `sessions`
    /// merges its rows into the host registry, and every other slot with
    /// pre-existing real content is moved to `<slot>.profile-local` as a sidecar
    /// before the symlink is created — see `ensureMirrorSlot` for the full
    /// per-slot policy.
    private static let mirrorSlots: [String] = [
        "projects",
        "plugins",
        "skills",
        "agents",
        "commands",
        "hooks",
        "CLAUDE.md",
        "settings.json",
        "keybindings.json",
        // Claude Code's cross-session peer registry: one small JSON row per
        // live session (pid, session id, cwd, tmux pane, inbox socket path,
        // name, status), written to `$CLAUDE_CONFIG_DIR/sessions/<pid>.json`.
        // It is a discovery *index*, not transcript data, and because it lives
        // under the config dir, TBD profiles are otherwise mutually invisible
        // — measured: 24 live sessions in one profile could not be seen from a
        // session in another. The message sockets themselves already live in a
        // per-OS-user directory, so sharing the index is enough to make every
        // TBD session discoverable regardless of which profile spawned it.
        "sessions",
    ]

    /// Slots whose host directory is created on demand when it does not exist
    /// yet, instead of skipping the slot (the default in `ensureMirrorSlot`).
    ///
    /// Only `sessions` qualifies. The other nine are host *customizations* —
    /// a profile has nothing to gain from a symlink to an empty directory the
    /// user never created, and creating one would invent host state. The peer
    /// registry is the opposite: Claude Code creates it the first time a
    /// session registers, so on a machine where no session has run yet the
    /// skip would silently no-op and leave profiles fragmented forever — the
    /// exact failure this slot exists to prevent.
    private static let slotsCreatedOnHostIfMissing: Set<String> = ["sessions"]

    /// Slots whose pre-existing profile-side content is **merged** into the
    /// host entry instead of being parked in a `<slot>.profile-local` sidecar
    /// (the default in `ensureMirrorSlot`).
    ///
    /// Only `sessions` qualifies, and the distinction is not stylistic: the
    /// other nine slots hold inert user content, while a `sessions/` row is
    /// live process state. `ensureHostMirrors` runs on every spawn, so a
    /// sidecar move there would relocate *running* sessions' rows out from
    /// under them — nothing reads the sidecar, and each session's exit-time
    /// unlink targets the host path, so the row would be orphaned for good.
    /// Measured on one developer machine before this landed: 4 profiles held 48
    /// rows, 47 of them belonging to live PIDs.
    ///
    /// Merging is collision-free by construction because rows are named
    /// `<pid>.json` and PIDs are unique per OS user at any instant; the
    /// newest-wins tiebreak below exists only for a *stale* row left by a dead
    /// process whose PID a later session reused under another profile.
    private static let slotsMergedIntoHost: Set<String> = ["sessions"]

    /// Slots whose host entry must be a directory before it can be mirrored.
    ///
    /// Scoped to `sessions` deliberately. The other nine keep their
    /// pre-existing unchecked behaviour — three of them (`CLAUDE.md`,
    /// `settings.json`, `keybindings.json`) are files by design, and the rest
    /// have never been reported wedged. What makes `sessions` different is that TBD *writes*
    /// through the mirror: a host `sessions` that is a regular file would give
    /// every profile a symlink to a file and fail every registry write.
    private static let slotsRequiringHostDirectory: Set<String> = ["sessions"]

    /// Permissions Claude Code creates its own `sessions/` directory with.
    /// Field-measured on this machine: the host `~/.claude/sessions` and the
    /// `sessions/` dir of every profile that had run a session were all
    /// `drwx------`. Matched so a TBD-created directory is indistinguishable
    /// from one the CLI would have made, and so peer rows — which carry inbox
    /// socket paths — are not world-readable.
    private static let sessionsDirectoryPermissions = 0o700

    /// One pass-1 decision about a profile `projects/` entry that pass 2 applies.
    private enum ProjectsCollisionResolution {
        /// The profile file is byte-identical to the host file: remove the profile copy.
        /// The sizes pass 1 saw are re-checked at apply time, which makes it much
        /// less likely that a live writer appending in between loses bytes. It
        /// does not rule it out: an append between the re-check and the unlink,
        /// or a same-size rewrite, still gets past it.
        case dropDuplicate(profile: URL, host: URL, profileSize: UInt64, hostSize: UInt64)
        /// The profile entry is a symlink to its own host counterpart: remove only the link.
        case dropAliasLink(profile: URL)
        /// A differing transcript on both sides: the longer copy ends up at the
        /// host path and the other is kept beside it as a `.backup` file.
        case keepLonger(profile: URL, host: URL, profileSize: UInt64, hostSize: UInt64)
    }

    /// Pass-1 output: resolvable collisions plus every unresolvable one.
    private struct ProjectsMigrationPlan {
        var resolutions: [ProjectsCollisionResolution] = []
        /// Host-side paths that cannot be resolved without discarding data.
        var conflicts: [URL] = []
    }

    /// True when anything, including a dangling symlink, sits at `url`.
    /// `fileExists` answers false for a dangling link; `attributesOfItem` does not follow.
    private static func pathOccupied(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    /// True when `url` is itself a symlink. Never follows it.
    private static func isSymlink(_ url: URL) -> Bool {
        let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
        return type == .typeSymbolicLink
    }

    /// True when `url` resolves to a directory. Follows symlinks, so callers
    /// that must tell a link apart check `isSymlink` first.
    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func fileSize(of url: URL) -> UInt64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value
    }

    /// Walk the profile tree `src` against the host tree `dst`, recording how
    /// each collision resolves (or that it cannot). Read-only.
    ///
    /// Classification at every path where the profile has an entry:
    /// 1. Profile symlink: aliasing its own host counterpart is dropped (checked
    ///    first, so a link is never moved onto its own target); otherwise it is
    ///    moved as-is when the host path is free and a conflict when not. A
    ///    profile-side symlink is never followed or recursed into.
    /// 2. Host path unoccupied (a dangling host symlink counts as occupied): nothing to do.
    /// 3. File versus directory: conflict.
    /// 4. Two directories: recurse.
    /// 5. Two files: byte-identical is a duplicate; a differing `.jsonl`
    ///    transcript of another size keeps the longer; anything else conflicts.
    private func planProjectsMigration(src: URL, dst: URL, into plan: inout ProjectsMigrationPlan) {
        let fm = FileManager.default

        if Self.isSymlink(src) {
            if let dest = try? fm.destinationOfSymbolicLink(atPath: src.path) {
                let target = URL(fileURLWithPath: dest, relativeTo: src.deletingLastPathComponent())
                    .resolvingSymlinksInPath()
                if target.path == dst.resolvingSymlinksInPath().path {
                    plan.resolutions.append(.dropAliasLink(profile: src))
                    return
                }
            }
            if Self.pathOccupied(dst) { plan.conflicts.append(dst) }
            return
        }

        guard Self.pathOccupied(dst) else {
            // Free slot: the profile entry is moved whole later. A real directory
            // can still carry an alias link that would become a self-loop at
            // its new home, so look inside it too (every dst below is free, so
            // only alias links can come out of this walk).
            var freeSrcIsDir: ObjCBool = false
            if fm.fileExists(atPath: src.path, isDirectory: &freeSrcIsDir), freeSrcIsDir.boolValue {
                planChildren(of: src, against: dst, into: &plan)
            }
            return
        }

        // src vanished between enumeration and this call (rare race): nothing to merge.
        var srcIsDir: ObjCBool = false
        guard fm.fileExists(atPath: src.path, isDirectory: &srcIsDir) else { return }

        var dstIsDir: ObjCBool = false
        // Dangling host symlink: occupied but unresolvable.
        guard fm.fileExists(atPath: dst.path, isDirectory: &dstIsDir) else {
            plan.conflicts.append(dst)
            return
        }

        if srcIsDir.boolValue != dstIsDir.boolValue {
            plan.conflicts.append(dst)
            return
        }

        if srcIsDir.boolValue {
            planChildren(of: src, against: dst, into: &plan)
            return
        }

        // Both regular files.
        guard let profileSize = Self.fileSize(of: src),
              let hostSize = Self.fileSize(of: dst.resolvingSymlinksInPath()) else {
            plan.conflicts.append(dst)
            return
        }
        if profileSize == hostSize, fm.contentsEqual(atPath: src.path, andPath: dst.path) {
            plan.resolutions.append(
                .dropDuplicate(profile: src, host: dst, profileSize: profileSize, hostSize: hostSize)
            )
        } else if src.pathExtension == "jsonl", profileSize != hostSize, !Self.isSymlink(dst) {
            plan.resolutions.append(
                .keepLonger(profile: src, host: dst, profileSize: profileSize, hostSize: hostSize)
            )
        } else {
            plan.conflicts.append(dst)
        }
    }

    private func planChildren(of src: URL, against dst: URL, into plan: inout ProjectsMigrationPlan) {
        let entries = (try? FileManager.default.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)) ?? []
        for entry in entries {
            planProjectsMigration(src: entry, dst: dst.appendingPathComponent(entry.lastPathComponent), into: &plan)
        }
    }

    /// Throws unless both files still have the sizes pass 1 judged them by.
    private static func requireUnchanged(profile: URL, profileSize: UInt64, host: URL, hostSize: UInt64) throws {
        guard fileSize(of: profile) == profileSize,
              fileSize(of: host.resolvingSymlinksInPath()) == hostSize else {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedDescriptionKey: "\(host.lastPathComponent) changed since it was planned; will re-plan on the next spawn",
            ])
        }
    }

    /// First `<file>.backup`, `<file>.backup-2`, … beside `file` whose name is
    /// free both there and in `otherDirectory`, the profile directory being
    /// merged into `file`'s directory. A profile entry of that name moves into
    /// the host directory later in the same pass, so a backup under its name
    /// would collide with it and fail the merge.
    /// `.backup` does not end in `.jsonl`, so transcript scanners ignore it.
    private static func backupURL(for file: URL, avoidingNamesIn otherDirectory: URL) -> URL {
        var candidate = file.appendingPathExtension("backup")
        var n = 2
        while pathOccupied(candidate)
            || pathOccupied(otherDirectory.appendingPathComponent(candidate.lastPathComponent)) {
            candidate = file.deletingLastPathComponent()
                .appendingPathComponent("\(file.lastPathComponent).backup-\(n)")
            n += 1
        }
        return candidate
    }

    /// Apply one pass-1 resolution. Idempotent across a partial failure: a
    /// retry re-plans from the filesystem as it then stands.
    private func apply(_ resolution: ProjectsCollisionResolution, hostPrefix: String) throws {
        let fm = FileManager.default
        switch resolution {
        case .dropDuplicate(let profile, let host, let profileSize, let hostSize):
            try Self.requireUnchanged(profile: profile, profileSize: profileSize, host: host, hostSize: hostSize)
            try fm.removeItem(at: profile)
        case .dropAliasLink(let profile):
            // removeItem on a symlink unlinks it; the target is untouched.
            try fm.removeItem(at: profile)
        case .keepLonger(let profile, let host, let profileSize, let hostSize):
            try Self.requireUnchanged(profile: profile, profileSize: profileSize, host: host, hostSize: hostSize)
            let backup = Self.backupURL(for: host, avoidingNamesIn: profile.deletingLastPathComponent())
            let profileIsLonger = profileSize > hostSize
            if profileIsLonger {
                try fm.moveItem(at: host, to: backup)
                try fm.moveItem(at: profile, to: host)
            } else {
                try fm.moveItem(at: profile, to: backup)
            }
            let rel = host.path.hasPrefix(hostPrefix) ? String(host.path.dropFirst(hostPrefix.count)) : host.path
            logger.warning("diverged transcript \(rel, privacy: .public): kept the \(profileIsLonger ? "profile" : "host", privacy: .public) copy as the longer (profile \(profileSize, privacy: .public) bytes, host \(hostSize, privacy: .public) bytes); other copy saved as \(backup.lastPathComponent, privacy: .public)")
        }
    }

    /// Move every file/subdirectory in `src` into the corresponding location
    /// under `dst`. The caller must have already verified
    /// the projects plan had no conflicts and its resolutions were applied — no
    /// overwrite checks are performed here. After a successful merge, `src` is removed.
    private func mergeRecursive(src: URL, dst: URL) throws {
        let fm = FileManager.default

        if !fm.fileExists(atPath: dst.path) {
            try fm.moveItem(at: src, to: dst)  // whole-subtree move
            return
        }

        // dst exists; pre-check guarantees it's a directory and src is too.
        // Use `try` (not `try?`) so a listing failure surfaces to the caller
        // instead of producing a misleading ENOTEMPTY from `removeItem` below.
        let srcEntries = try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)
        for entry in srcEntries {
            let dstEntry = dst.appendingPathComponent(entry.lastPathComponent)
            try mergeRecursive(src: entry, dst: dstEntry)
        }
        try fm.removeItem(at: src)  // now empty
    }

    /// Last-modified stamp for a filesystem entry, `.distantPast` when it
    /// cannot be read. `attributesOfItem` does not follow symlinks, which is
    /// what we want: the stamp should describe the entry we are about to move
    /// or delete, not whatever it might point at.
    private static func modificationDate(of url: URL) -> Date {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.modificationDate] as? Date) ?? .distantPast
    }

    /// Move every row out of a profile's real registry directory into the host
    /// registry, then remove the emptied profile directory. Returns false when
    /// anything is left behind, in which case the caller must **not** symlink
    /// over it — a partial merge is retried on the next spawn rather than
    /// buried.
    ///
    /// Rows are named `<pid>.json` and PIDs are unique per OS user at any
    /// instant, so the merge is collision-free by construction. A same-named
    /// row on both sides therefore means one of them is stale — a dead
    /// process's row whose PID a later session reused under another profile —
    /// and the newer modification time wins. The loser is deleted, and logged
    /// so the deletion is observable. An unreadable stamp loses, since the host
    /// side is the one live sessions are writing to.
    private func mergeRegistryRows(from profileEntry: URL, into hostEntry: URL, slot: String) -> Bool {
        let fm = FileManager.default
        let rows: [URL]
        do {
            rows = try fm.contentsOfDirectory(at: profileEntry, includingPropertiesForKeys: nil)
        } catch {
            logger.warning("failed listing profile \(slot, privacy: .public)/ for merge: \(error.localizedDescription, privacy: .public)")
            return false
        }

        for row in rows {
            let rowName = row.lastPathComponent
            let destination = hostEntry.appendingPathComponent(rowName)
            do {
                if fm.fileExists(atPath: destination.path) {
                    if Self.modificationDate(of: row) > Self.modificationDate(of: destination) {
                        logger.warning("\(slot, privacy: .public) row \(rowName, privacy: .public) exists on both sides; discarding the older host copy")
                        try fm.removeItem(at: destination)
                        try fm.moveItem(at: row, to: destination)
                    } else {
                        logger.warning("\(slot, privacy: .public) row \(rowName, privacy: .public) exists on both sides; discarding the older profile copy")
                        try fm.removeItem(at: row)
                    }
                } else {
                    try fm.moveItem(at: row, to: destination)
                }
            } catch {
                logger.warning("failed merging \(slot, privacy: .public) row \(rowName, privacy: .public) into the host registry: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }

        do {
            try fm.removeItem(at: profileEntry)
        } catch {
            logger.warning("failed removing merged profile \(slot, privacy: .public)/: \(error.localizedDescription, privacy: .public)")
            return false
        }
        return true
    }

    /// Ensure one host-mirror slot is a symlink from the profile dir into the
    /// host base. Best-effort: filesystem errors are logged and swallowed.
    ///
    /// **Host side.** The slot is skipped unless the host entry is usable: a
    /// non-directory host entry for a slot in `slotsRequiringHostDirectory`, or
    /// an entry that exists only as a dangling symlink, is logged and left
    /// alone rather than symlinked at. When the host entry is absent, the slot
    /// is normally skipped — except for `slotsCreatedOnHostIfMissing`
    /// (`sessions`), where the directory is created on demand, non-recursively
    /// and only if the host base directory already exists. TBD never conjures
    /// the host store itself; a machine with no `~/.claude` gets no mirror.
    ///
    /// **Profile side**, in three policies:
    ///
    /// - `projects/` (migrateContent=true) migrates content into the host store
    ///   with the collision check described below.
    /// - `sessions/` (`slotsMergedIntoHost`) merges its rows into the host
    ///   registry entry-by-entry — newest modification time wins a same-named
    ///   row — then removes the emptied profile directory. It holds live
    ///   process state, so parking it in a sidecar would orphan running
    ///   sessions' rows.
    /// - Everything else with real content is moved to a `<slot>.profile-local`
    ///   sidecar, which lets the symlink be created without destroying what was
    ///   there.
    ///
    /// For `projects/` (migrateContent=true), pass 1 recursively walks the full tree
    /// and plans (`planProjectsMigration`); same-named directories on both sides
    /// recurse. Resolvable collisions: a byte-identical profile file is dropped, a
    /// profile symlink to its own host counterpart is unlinked, and a differing
    /// `.jsonl` transcript of another size keeps the longer copy at the host path
    /// with the other beside it as `<name>.backup`. Any other collision (type
    /// mismatch, a differing non-transcript file, a symlink pointing elsewhere onto
    /// an occupied host path) aborts the whole migration with nothing changed.
    /// Otherwise pass 2 applies the resolutions and merges everything else into the
    /// host store. Only byte-identical copies, alias links and a top-level Finder
    /// `.DS_Store` are ever deleted.
    /// Atomic with respect to conflicts: pass 1 confirms none exist before pass 2
    /// changes anything. Not atomic with respect to
    /// I/O failures during pass 2 — those leave partial state that the next call
    /// cleans up.
    ///
    /// For other slots (migrateContent=false) with real content, the content is moved
    /// to a `<slot>.profile-local` sidecar, allowing the symlink to be created and the
    /// profile to access host customizations.
    private func ensureMirrorSlot(
        _ name: String,
        in profileClaudeDir: URL,
        migrateContent: Bool
    ) {
        let fm = FileManager.default
        let hostEntry = hostBaseDirectory.appendingPathComponent(name)

        // Classify the host entry before treating it as a mirror target.
        // `fileExists` resolves symlinks, so on its own it cannot tell a usable
        // directory from a regular file, and it answers *false* for a dangling
        // symlink. `attributesOfItem` does not resolve links, so an entry it can
        // stat while `fileExists` denies is precisely a dangling link — which
        // would otherwise send us down the create branch, where
        // `createDirectory` fails EEXIST on every spawn, forever.
        var hostIsDir: ObjCBool = false
        let hostEntryResolves = fm.fileExists(atPath: hostEntry.path, isDirectory: &hostIsDir)
        let hostPathOccupied = (try? fm.attributesOfItem(atPath: hostEntry.path)) != nil

        if !hostEntryResolves {
            if hostPathOccupied {
                logger.warning("host slot \(name, privacy: .public) is a dangling symlink; leaving it alone")
                return
            }
            // Absent host slot: normally "the user does not use this feature",
            // so skip. For the create-on-demand slots it is instead the
            // ordinary first-run state, so create it — but never invent the
            // host store itself, and never recursively (see finding: 0700 on a
            // conjured `~/.claude` would be host state TBD had no business
            // making).
            guard Self.slotsCreatedOnHostIfMissing.contains(name) else { return }
            guard fm.fileExists(atPath: hostBaseDirectory.path) else {
                logger.warning("host claude store is absent; not creating slot \(name, privacy: .public)")
                return
            }
            do {
                try fm.createDirectory(
                    at: hostEntry,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: Self.sessionsDirectoryPermissions]
                )
            } catch {
                logger.warning("failed creating host slot \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return
            }
        } else if Self.slotsRequiringHostDirectory.contains(name), !hostIsDir.boolValue {
            logger.warning("host slot \(name, privacy: .public) is not a directory; leaving it alone")
            return
        }

        let profileEntry = profileClaudeDir.appendingPathComponent(name)

        // Already a symlink? Check target; if it's right, done. If wrong,
        // leave it and log (don't fight an owner we don't recognize).
        if let dest = try? fm.destinationOfSymbolicLink(atPath: profileEntry.path) {
            let resolved = URL(fileURLWithPath: dest, relativeTo: profileEntry.deletingLastPathComponent())
                .resolvingSymlinksInPath()
            if resolved == hostEntry.resolvingSymlinksInPath() { return }
            logger.warning("mirror slot \(name, privacy: .public) symlink for profile points elsewhere; leaving as-is")
            return
        }

        // Profile has a real entry. Handle per slot policy.
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: profileEntry.path, isDirectory: &isDir) {
            if isDir.boolValue, migrateContent {
                // projects/ special-case: file-level collision detection with one-level recursion.
                do {
                    try fm.createDirectory(at: hostEntry, withIntermediateDirectories: true)
                    let entries = (try? fm.contentsOfDirectory(at: profileEntry, includingPropertiesForKeys: nil)) ?? []

                    // Every top-level entry is planned, so a stray regular file is
                    // moved or reported as a conflict, never swept. The one exception
                    // is Finder's .DS_Store: view metadata Finder regenerates, which
                    // would otherwise turn a differing copy into a conflict that
                    // blocks the link forever.
                    func isPlannable(_ url: URL) -> Bool {
                        guard url.lastPathComponent == ".DS_Store" else { return true }
                        return Self.isSymlink(url) || Self.isDirectory(url)
                    }

                    // Pass 1 (read-only): plan resolutions and collect every conflict.
                    var plan = ProjectsMigrationPlan()
                    for entry in entries where isPlannable(entry) {
                        planProjectsMigration(
                            src: entry,
                            dst: hostEntry.appendingPathComponent(entry.lastPathComponent),
                            into: &plan
                        )
                    }

                    // Conflicts are logged relative to the host slot root
                    // (e.g. "-cwd-A/sub/leaf.md"), not as absolute host paths.
                    let hostPrefix = hostEntry.path + "/"
                    if !plan.conflicts.isEmpty {
                        let rels = plan.conflicts.map { conflict in
                            conflict.path.hasPrefix(hostPrefix)
                                ? String(conflict.path.dropFirst(hostPrefix.count))
                                : conflict.path
                        }
                        logger.warning("projects migration incomplete for profile due to file collision (\(rels.joined(separator: ", "), privacy: .public)); symlink will not be created. profile-side \(name, privacy: .public)/ dir preserved.")
                        return
                    }

                    // Pass 2: apply resolutions, then move everything else (now collision-free).
                    for resolution in plan.resolutions {
                        try apply(resolution, hostPrefix: hostPrefix)
                    }
                    for entry in entries where isPlannable(entry) {
                        // An alias link dropped above is gone; skip it.
                        guard Self.pathOccupied(entry) else { continue }
                        try mergeRecursive(src: entry, dst: hostEntry.appendingPathComponent(entry.lastPathComponent))
                    }

                    // Drop the unplanned Finder .DS_Store files explicitly so the
                    // removal is observable, then remove the directory itself
                    // non-recursively: rmdir refuses a non-empty directory, so
                    // anything a live writer created after planning is never deleted.
                    for entry in entries where !isPlannable(entry) {
                        logger.debug("removing Finder metadata \(entry.lastPathComponent, privacy: .public) from profile projects/ during migration")
                        try? fm.removeItem(at: entry)
                    }
                    if rmdir(profileEntry.path) != 0 {
                        let left = ((try? fm.contentsOfDirectory(atPath: profileEntry.path)) ?? []).sorted()
                        logger.warning("profile \(name, privacy: .public)/ not empty after migration (left: \(left.joined(separator: ", "), privacy: .public)); symlink will not be created, will re-plan on the next spawn")
                        return
                    }
                } catch {
                    logger.warning("failed migrating \(name, privacy: .public) for profile: \(error.localizedDescription, privacy: .public)")
                    return
                }
            } else if isDir.boolValue, Self.slotsMergedIntoHost.contains(name) {
                // Live-registry directory in profile: merge its rows into the
                // host registry rather than parking them in a sidecar nothing
                // reads. Bail without symlinking if anything is left behind, so
                // a partial merge is retried on the next spawn instead of being
                // buried under a symlink.
                guard mergeRegistryRows(from: profileEntry, into: hostEntry, slot: name) else { return }
            } else if isDir.boolValue {
                // Non-projects directory in profile: move to sidecar if non-empty, otherwise remove.
                let entries = (try? fm.contentsOfDirectory(at: profileEntry, includingPropertiesForKeys: nil)) ?? []
                if entries.isEmpty {
                    try? fm.removeItem(at: profileEntry)
                } else {
                    // Non-empty directory: rename to sidecar if it doesn't already exist.
                    let sidecarURL = profileEntry.appendingPathExtension("profile-local")
                    // Note: fileExists(atPath:) returns false for dangling symlinks. We never
                    // create dangling symlinks, so this is unlikely, but edge case documented.
                    if !fm.fileExists(atPath: sidecarURL.path) {
                        do {
                            try fm.moveItem(at: profileEntry, to: sidecarURL)
                            logger.warning("profile has real \(name, privacy: .public)/ with content; moved to \(sidecarURL.lastPathComponent, privacy: .public)")
                        } catch {
                            logger.warning("failed moving \(name, privacy: .public)/ to sidecar: \(error.localizedDescription, privacy: .public)")
                            return
                        }
                    } else {
                        logger.debug("profile has real \(name, privacy: .public)/ with content and sidecar already exists; skipping rename")
                    }
                }
            } else {
                // Real file (e.g. profile-side settings.json or CLAUDE.md).
                // Move to sidecar if it doesn't already exist.
                let sidecarURL = profileEntry.appendingPathExtension("profile-local")
                if !fm.fileExists(atPath: sidecarURL.path) {
                    do {
                        try fm.moveItem(at: profileEntry, to: sidecarURL)
                        logger.warning("profile has real \(name, privacy: .public) file; moved to \(sidecarURL.lastPathComponent, privacy: .public)")
                    } catch {
                        logger.warning("failed moving \(name, privacy: .public) file to sidecar: \(error.localizedDescription, privacy: .public)")
                        return
                    }
                } else {
                    logger.debug("profile has real \(name, privacy: .public) file and sidecar already exists; skipping rename")
                }
            }
        }

        // Create the symlink. Best-effort; on EEXIST race (concurrent winner),
        // verify idempotency before logging a warning.
        do {
            try fm.createSymbolicLink(at: profileEntry, withDestinationURL: hostEntry)
        } catch {
            // If entry now exists and is a symlink to the correct target,
            // treat as idempotent success. Otherwise log and return.
            if let dest = try? fm.destinationOfSymbolicLink(atPath: profileEntry.path) {
                let resolved = URL(fileURLWithPath: dest, relativeTo: profileEntry.deletingLastPathComponent())
                    .resolvingSymlinksInPath()
                if resolved == hostEntry.resolvingSymlinksInPath() { return }
            }
            logger.warning("failed creating mirror symlink for \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Ensure every host-mirror slot is symlinked into the profile dir.
    /// Best-effort and per-entry isolated — one failing slot does not block
    /// the others.
    private func ensureHostMirrors(in profileClaudeDir: URL) {
        for slot in Self.mirrorSlots {
            ensureMirrorSlot(slot, in: profileClaudeDir, migrateContent: slot == "projects")
        }
    }

    /// Ensure the per-profile claude config dir exists, and that `.claude.json`
    /// contains a pre-approval for the supplied API key (last-20-char form).
    ///
    /// If the dir already exists but `.claude.json` is missing or doesn't yet
    /// include the approval for this key, the file is rewritten with the
    /// correct content. Existing approvals for other keys are preserved.
    /// All unknown top-level keys in the existing `.claude.json` are preserved.
    /// Its read-merge-write of `.claude.json` runs inside the
    /// `ClaudeConfigDirSerializer` lane for this directory, because it is one of
    /// that file's four writers and the completions probe — which suspends for
    /// as long as a Claude Code process takes to answer — is another. Without
    /// the lane a probe's own rewrite can land between this read and this write,
    /// and the loser's keys (a folder-trust entry among them) are gone.
    ///
    /// Only the read-merge-write is inside. Creating the directory and ensuring
    /// the host mirror symlinks touch no `.claude.json`, so they stay outside
    /// and keep the critical section to the file it protects.
    ///
    /// - Parameter afterReadForTesting: a test-only seam, defaulted so no call
    ///   site changes, awaited between the read of `.claude.json` and the write
    ///   that replaces it. The merge is otherwise straight-line synchronous code
    ///   inside the lane body, so that window cannot be straddled from outside —
    ///   and a test that cannot straddle it cannot show what the lane is for.
    ///   `ClaudeConfigDirSerializerTests.anInterleavedEnsureLeavesTheTrustEntryIntact`
    ///   holds here while a trust entry is written, which is a lost trust key
    ///   when this call skips the lane and a preserved one when it takes it.
    @discardableResult
    public func ensureAPIKeyDir(
        forProfileID profileID: UUID,
        apiKey: String,
        afterReadForTesting: (@Sendable () async -> Void)? = nil
    ) async throws -> URL {
        let dir = configDirectory(forProfileID: profileID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let approvalToken = Self.approvalToken(forAPIKey: apiKey)
        let claudeJSONPath = dir.appendingPathComponent(".claude.json")

        try await ClaudeConfigDirSerializer.shared.run(configDir: dir.path) {
            var approved: [String] = []
            var rejected: [String] = []
            var hasOnboarding = true
            var unknownKeys: [String: Any] = [:]

            if let existing = try? Data(contentsOf: claudeJSONPath),
               let parsed = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] {
                if let responses = parsed["customApiKeyResponses"] as? [String: Any] {
                    approved = (responses["approved"] as? [String]) ?? []
                    rejected = (responses["rejected"] as? [String]) ?? []
                }
                hasOnboarding = (parsed["hasCompletedOnboarding"] as? Bool) ?? true

                // Preserve all unknown top-level keys from the existing file.
                for (key, value) in parsed {
                    if key != "customApiKeyResponses" && key != "hasCompletedOnboarding" {
                        unknownKeys[key] = value
                    }
                }
            }

            await afterReadForTesting?()

            if !approved.contains(approvalToken) {
                approved.append(approvalToken)
            }

            var payload: [String: Any] = unknownKeys
            payload["customApiKeyResponses"] = [
                "approved": approved,
                "rejected": rejected,
            ]
            payload["hasCompletedOnboarding"] = hasOnboarding

            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: claudeJSONPath, options: [.atomic])
        }

        ensureHostMirrors(in: dir)

        logger.debug("ensured claude config dir at \(dir.path, privacy: .public) for profile \(profileID, privacy: .public)")
        return dir
    }

    /// Ensure the per-profile claude config dir exists for an OAuth profile,
    /// and write a minimal `.claude.json` with only `hasCompletedOnboarding: true`
    /// if the file does not already exist. An existing file keeps every key it
    /// has; the one change is adding `hasCompletedOnboarding: true` when the
    /// key is absent (see `addOnboardingFlagIfMissing(at:profileID:)`).
    ///
    /// OAuth profiles do not need a pre-approved API key, so no
    /// `customApiKeyResponses` is written. The user will `/login` once into
    /// this isolated config dir, and the credential persists in the Keychain
    /// entry derived from the `CLAUDE_CONFIG_DIR` path.
    ///
    /// Host mirror slots are always ensured, regardless of whether `.claude.json`
    /// already existed. This is critical for profiles created before mirror support
    /// was added; without this, they would never get their symlinked customizations.
    ///
    /// The exists-check and the write are one critical section inside the
    /// `ClaudeConfigDirSerializer` lane for this directory, for the reason given
    /// on `ensureAPIKeyDir`. Checking outside the lane would be a race of its
    /// own shape rather than a smaller one: a probe that creates `.claude.json`
    /// between the check and the write turns "the file did not exist" into an
    /// overwrite of the file it just wrote.
    @discardableResult
    public func ensureOAuthDir(forProfileID profileID: UUID) async throws -> URL {
        let dir = configDirectory(forProfileID: profileID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let claudeJSONPath = dir.appendingPathComponent(".claude.json")

        try await ClaudeConfigDirSerializer.shared.run(configDir: dir.path) {
            if FileManager.default.fileExists(atPath: claudeJSONPath.path) {
                Self.addOnboardingFlagIfMissing(at: claudeJSONPath, profileID: profileID)
            } else {
                let payload: [String: Any] = [
                    "hasCompletedOnboarding": true,
                ]
                let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: claudeJSONPath, options: [.atomic])
            }
        }

        // Always ensure host mirrors, even if .claude.json already existed.
        // Profiles created before mirror support was added must get their
        // symlinks set up on subsequent calls.
        ensureHostMirrors(in: dir)

        logger.debug("ensured claude config dir at \(dir.path, privacy: .public) for oauth profile \(profileID, privacy: .public)")
        return dir
    }

    /// Add `hasCompletedOnboarding: true` to an existing `.claude.json` that
    /// lacks the key, keeping every other key.
    ///
    /// Something other than this manager can create the file first — any
    /// Claude Code process run with this `CLAUDE_CONFIG_DIR` before TBD's first
    /// spawn writes `numStartups` and friends without the flag. The first
    /// interactive session on the profile then stops at Claude Code's
    /// first-run screens (the theme picker), a stall no hook can see, and a
    /// balanced spawn can land a session there unattended. A file that already
    /// carries the key, either way, is not rewritten, so this writes at most
    /// once per directory and never overrides Claude Code's own answer. A file
    /// that cannot be read or parsed is left untouched, as `ClaudeTrustSeeder`
    /// does. Called inside the directory's `ClaudeConfigDirSerializer` lane.
    static func addOnboardingFlagIfMissing(at claudeJSONPath: URL, profileID: UUID) {
        guard let data = try? Data(contentsOf: claudeJSONPath),
              var parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            logger.warning("unreadable .claude.json for oauth profile \(profileID, privacy: .public); leaving it untouched")
            return
        }
        guard parsed["hasCompletedOnboarding"] == nil else { return }
        parsed["hasCompletedOnboarding"] = true
        do {
            let updated = try JSONSerialization.data(withJSONObject: parsed, options: [.prettyPrinted, .sortedKeys])
            try updated.write(to: claudeJSONPath, options: [.atomic])
            logger.info("added hasCompletedOnboarding to an existing .claude.json for oauth profile \(profileID, privacy: .public)")
        } catch {
            logger.warning("could not add hasCompletedOnboarding for oauth profile \(profileID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Read the login identity for a profile from its isolated config dir:
    /// the `oauthAccount.emailAddress` that Claude Code writes into
    /// `<configDir>/.claude.json` after the user completes `/login` inside a
    /// session using this profile.
    ///
    /// Returns nil when the profile dir or `.claude.json` is missing, the JSON
    /// is malformed, or no `oauthAccount` has been written yet — all of which
    /// mean "not logged in" for TBD-owned profile dirs. Best-effort and
    /// read-only; never throws.
    public func loginIdentity(forProfileID profileID: UUID) -> String? {
        let claudeJSONPath = configDirectory(forProfileID: profileID)
            .appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: claudeJSONPath),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = parsed["oauthAccount"] as? [String: Any],
              let email = account["emailAddress"] as? String,
              !email.isEmpty
        else { return nil }
        return email
    }

    /// Claude Code stores approved keys as the last 20 chars of the key
    /// (confirmed by inspecting `~/.claude.json#customApiKeyResponses.approved`).
    /// For keys shorter than 20 chars (unusual but possible in tests), use the
    /// full string — matches Claude Code's `.suffix(20)` behavior.
    public static func approvalToken(forAPIKey apiKey: String) -> String {
        String(apiKey.suffix(20))
    }
}

extension ClaudeProfileConfigDirManager {
    /// Ensure the per-profile claude config dir for a resolved profile and
    /// return its path. Returns nil for bedrock profiles (which do not
    /// need config-dir isolation), nil profile, and apiKey profiles with
    /// a missing secret.
    ///
    /// For `.oauth` and `.oauthToken` profiles, calls `ensureOAuthDir` — a
    /// token profile gets the same isolated dir; only its credential differs.
    /// For `.apiKey` profiles, calls `ensureAPIKeyDir` (needs `profile.secret`;
    /// if the secret is nil, logs a warning and returns nil).
    /// For `.bedrock` profiles, returns nil.
    ///
    /// Filesystem errors are logged and swallowed — failing to write
    /// the config dir shouldn't break terminal spawn.
    ///
    /// Deliberately an **instance** method with no static twin. A static
    /// version used to exist and silently built its own manager on
    /// `TBDConstants.configDir`, which resolves `TBD_HOME` on every access —
    /// so every caller that had carefully injected a temp-dir manager still
    /// wrote into the real `~/tbd/profiles`. There is one way to ask, and it
    /// goes through the manager you hold.
    func resolveConfigDir(for profile: ResolvedModelProfile?) async -> String? {
        guard let profile else { return nil }

        switch profile.kind {
        // A token profile is structurally identical to a signed-in one: same
        // isolated config dir, same mirror symlinks, same GC coverage. Only
        // the credential differs (an injected CLAUDE_CODE_OAUTH_TOKEN instead
        // of a /login inside the dir), and that is the spawn builder's job.
        case .oauth, .oauthToken:
            do {
                let url = try await ensureOAuthDir(forProfileID: profile.profileID)
                return url.path
            } catch {
                logger.warning("failed to ensure oauth config dir for profile \(profile.profileID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }

        case .apiKey:
            guard let apiKey = profile.secret else {
                logger.warning("api-key profile \(profile.profileID, privacy: .public) has no secret; skipping config dir")
                return nil
            }
            do {
                let url = try await ensureAPIKeyDir(forProfileID: profile.profileID, apiKey: apiKey)
                return url.path
            } catch {
                logger.warning("failed to ensure api-key config dir for profile \(profile.profileID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }

        case .bedrock:
            // Bedrock doesn't need config-dir isolation.
            return nil
        }
    }
}
