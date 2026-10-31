import Foundation
import TBDShared
import os
// Internal so TOMLKit's literal-expressible types stay out of the type
// inference of modules that import this one (same reason as
// `DevServerDeclarationParser`).
internal import TOMLKit

private let switchLogger = Logger(subsystem: "com.tbd.daemon", category: "shadowPeer")

/// A repository's peer-messaging switch, as its `tbd.toml` states it:
///
/// ```toml
/// [remote_sessions]
/// peer_messaging = true
/// ```
///
/// The only values are `true` and `false`, and an absent file, table or key is
/// off. There is no "use the machine's setting" value and no machine-wide
/// switch: the setting is committed to the repository, so it means the same
/// thing on every machine that checks the repository out.
///
/// **Anything that is not a clear `true` is off, and anything malformed says
/// so.** A value of the wrong type, a `remote_sessions` that is not a table, a
/// file that is not valid TOML and a file that cannot be read each produce a
/// problem naming the file, and the switch reads as off. Sharing sessions
/// across machines is the one thing here that must never happen by accident,
/// so a file TBD cannot understand fails closed and visibly, never open.
///
/// Design: `docs/specs/2026-08-29-remote-peer-messaging-design.md`
/// § "The per-repository switch".
struct PeerMessagingSetting: Sendable, Equatable {
    /// The `tbd.toml` this setting was read from (or would have been).
    let path: String
    let enabled: Bool
    /// Why the file did not give a clear answer. Empty when it did, including
    /// when the file, the table or the key is simply absent.
    let problems: [String]

    static let tableKey = "remote_sessions"
    static let switchKey = "peer_messaging"

    /// Read the switch from the `tbd.toml` at the root of `checkoutPath`, fresh
    /// on every call.
    ///
    /// No cache, on purpose: the daemon re-reads it on every scope tick, which
    /// is what lets a change to the file take effect without a restart, and a
    /// small file read every thirty seconds per repository costs nothing.
    static func read(
        checkoutPath: String, fileManager: FileManager = .default
    ) -> PeerMessagingSetting {
        let path = RepoTOML.path(inCheckout: checkoutPath)
        guard fileManager.fileExists(atPath: path) else {
            return PeerMessagingSetting(path: path, enabled: false, problems: [])
        }
        guard let data = fileManager.contents(atPath: path),
              let text = String(data: data, encoding: .utf8)
        else {
            return PeerMessagingSetting(
                path: path, enabled: false,
                problems: ["could not read the file as UTF-8, so peer messaging is off"])
        }
        return parse(text, path: path)
    }

    /// Parse the switch out of `tbd.toml`'s text. Pure, so every branch is
    /// testable without a file.
    static func parse(_ text: String, path: String) -> PeerMessagingSetting {
        func off(_ problem: String? = nil) -> PeerMessagingSetting {
            PeerMessagingSetting(path: path, enabled: false, problems: problem.map { [$0] } ?? [])
        }
        let table: TOMLTable
        do {
            table = try TOMLTable(string: text)
        } catch let error as TOMLParseError {
            return off("not valid TOML (\(error.debugDescription)), so peer messaging is off")
        } catch {
            return off("not valid TOML (\(String(describing: error))), so peer messaging is off")
        }
        guard let sectionValue = table[tableKey] else { return off() }
        guard let section = sectionValue.table else {
            return off("`\(tableKey)` must be a table ([\(tableKey)]), so peer messaging is off")
        }
        guard let value = section[switchKey] else { return off() }
        guard let enabled = value.bool else {
            return off("""
                [\(tableKey)] `\(switchKey)` must be true or false, so peer messaging is off
                """)
        }
        return PeerMessagingSetting(path: path, enabled: enabled, problems: [])
    }
}

/// Remembers the problems last logged for each `tbd.toml`, so a malformed file
/// is logged when its problems change — and once when they clear — rather than
/// on every poll, scope tick and resolver call that reads it. Shared across
/// copies of the struct that owns it, and lock-guarded because those reads
/// come from several actors.
final class PeerMessagingProblemLog: Sendable {
    private let lastLogged = OSAllocatedUnfairLock<[String: [String]]>(initialState: [:])

    /// Log `setting`'s problems if they differ from what was last logged for
    /// its path. Returns whether anything was logged, for tests.
    @discardableResult
    func report(_ setting: PeerMessagingSetting) -> Bool {
        let previous = lastLogged.withLock { logged -> [String]? in
            let previous = logged[setting.path]
            if setting.problems.isEmpty {
                logged.removeValue(forKey: setting.path)
            } else {
                logged[setting.path] = setting.problems
            }
            return previous
        }
        if setting.problems.isEmpty {
            guard previous != nil else { return false }
            switchLogger.notice("""
                \(setting.path, privacy: .public): peer-messaging switch reads cleanly again
                """)
            return true
        }
        guard previous != setting.problems else { return false }
        for problem in setting.problems {
            switchLogger.error("""
                \(setting.path, privacy: .public): \(problem, privacy: .public)
                """)
        }
        return true
    }
}

/// Answers "is peer messaging on for this repository?" for the daemon.
///
/// **The repository's registered main checkout is the one whose `tbd.toml`
/// counts** — the path on the repo row — and no linked worktree's copy. What is
/// read is whatever that checkout's working tree holds right now: if the main
/// checkout is itself on a feature branch or carries an uncommitted edit, that
/// is what counts. The guarantee is narrower than "only the default branch
/// decides", and it is this:
///
/// - **A linked worktree cannot change the answer.** A branch checked out in a
///   TBD worktree can edit its own `tbd.toml` freely without switching
///   cross-machine messaging on or off for the repository's other sessions.
/// - **One answer per repository.** The switch scopes whole repositories in
///   both directions (outward announcement and inward shadow peers), so it
///   needs one value per repository, not one per worktree that could disagree.
/// - **Remote lanes have no local checkout of their own.** A remote session's
///   worktree row carries a synthetic `remote://` path with no files behind it,
///   so the repository's own directory is the only local `tbd.toml` there is.
struct RepoPeerMessagingSwitches: Sendable {
    /// Looks a repository row up. Throws when the database read fails, which
    /// callers treat as "unknown" rather than "off" — see `ProviderRepoScope`.
    let repo: @Sendable (UUID) async throws -> Repo?
    /// Reads the switch from a checkout. Injected so tests need no files.
    let read: @Sendable (String) -> PeerMessagingSetting
    /// Where problems are logged, at most once per change per file.
    let problemLog: PeerMessagingProblemLog

    init(
        repo: @escaping @Sendable (UUID) async throws -> Repo?,
        read: @escaping @Sendable (String) -> PeerMessagingSetting = {
            PeerMessagingSetting.read(checkoutPath: $0)
        },
        problemLog: PeerMessagingProblemLog = PeerMessagingProblemLog()
    ) {
        self.repo = repo
        self.read = read
        self.problemLog = problemLog
    }

    /// The setting for one repository row, logging any problem the file has.
    func setting(for repo: Repo) -> PeerMessagingSetting {
        setting(checkoutPath: repo.path)
    }

    /// The setting in one checkout. Problems are logged only when they change
    /// for that file; every read still returns them, so `tbd peer list` names
    /// them every time.
    func setting(checkoutPath: String) -> PeerMessagingSetting {
        let setting = read(checkoutPath)
        problemLog.report(setting)
        return setting
    }

    /// Whether peer messaging is on for `repoID`. False for a repository TBD
    /// has no row for. Throws only when the row could not be read.
    func isOn(repoID: UUID) async throws -> Bool {
        guard let repo = try await repo(repoID) else { return false }
        return setting(for: repo).enabled
    }
}

/// When TBD opens a provider's `messages` stream: when at least one repository
/// the provider runs sessions in has peer messaging switched on.
///
/// Pure over its inputs, so every branch is testable without a database or a
/// provider.
enum PeerMessagingStreamGate {
    /// The repositories `provider` runs sessions in, read from TBD's own
    /// worktree rows: a remote lane carries the provider that hosts it.
    static func repos(hostedBy provider: String, in worktrees: [Worktree]) -> Set<UUID> {
        Set(worktrees.compactMap { row in
            row.providerBinding?.provider == provider ? row.repoID : nil
        })
    }

    /// Whether to open `provider`'s `messages` stream. A provider whose
    /// sessions sit only in switched-off repositories gets no stream, even when
    /// another provider's repository is switched on.
    static func shouldOpenStream(
        provider: String,
        worktrees: [Worktree],
        repoIsOn: (UUID) async throws -> Bool
    ) async rethrows -> Bool {
        for repoID in repos(hostedBy: provider, in: worktrees).sorted(by: {
            $0.uuidString < $1.uuidString
        }) where try await repoIsOn(repoID) {
            return true
        }
        return false
    }
}
