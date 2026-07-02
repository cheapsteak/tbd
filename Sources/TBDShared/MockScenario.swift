import Foundation

/// Mock-mode configuration parsed from a process environment.
///
/// The mock harness (`scripts/mock.sh`) launches an isolated daemon+app pair
/// with `TBD_MOCK=1` and `TBD_MOCK_FIXTURE=<scenario.json>`. Both the daemon
/// (to seed + skip reconciliation) and the app (to isolate UserDefaults +
/// suppress notifications) read this seam.
public enum MockMode: Equatable, Sendable {
    case enabled(fixturePath: String)

    /// Parse mock configuration. Returns `.enabled` only when `TBD_MOCK` is a
    /// truthy value (`"1"`/`"true"`, case-insensitive) AND `TBD_MOCK_FIXTURE`
    /// names a non-empty path. Returns `nil` otherwise (production).
    public static func fromEnvironment(_ env: [String: String]) -> MockMode? {
        let flag = env["TBD_MOCK"]?.lowercased()
        guard flag == "1" || flag == "true" else { return nil }
        guard let fixture = env["TBD_MOCK_FIXTURE"], !fixture.isEmpty else { return nil }
        return .enabled(fixturePath: fixture)
    }

    public static func isActive(in env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        fromEnvironment(env) != nil
    }

    /// UserDefaults suite the mock app uses so its window/settings never write
    /// back into the real `TBDApp.plist`.
    public static let appUserDefaultsSuiteName = "com.tbd.app.mock"
}

/// A hand-authored seed scenario: repos, their worktrees, and each worktree's
/// terminals. Decoded from `Tests/Fixtures/mock-state/scenario-*.json` and
/// materialized by `MockSeeder`. Fields with sensible defaults are Optional so
/// fixtures can omit them (Swift synthesizes `decodeIfPresent` for Optionals).
public struct MockScenario: Codable, Sendable {
    public var repos: [RepoSeed]

    public init(repos: [RepoSeed]) { self.repos = repos }

    public struct RepoSeed: Codable, Sendable {
        public var path: String
        public var displayName: String
        /// Defaults to "main" when omitted.
        public var defaultBranch: String?
        public var worktrees: [WorktreeSeed]

        public init(path: String, displayName: String, defaultBranch: String? = nil, worktrees: [WorktreeSeed]) {
            self.path = path
            self.displayName = displayName
            self.defaultBranch = defaultBranch
            self.worktrees = worktrees
        }
    }

    public struct WorktreeSeed: Codable, Sendable {
        public var name: String
        public var branch: String
        public var displayName: String?
        /// Appended under `<repo>/.tbd/worktrees/` for the row's `path`; defaults to `name`.
        public var pathSuffix: String?
        /// Defaults to `.active`.
        public var status: WorktreeStatus?
        /// Defaults to `false`.
        public var hasConflicts: Bool?
        public var prStatus: PRStatus?
        public var autoArchiveOnMerge: Bool?
        /// `name` of another worktree in the SAME repo, listed EARLIER in the array.
        public var parentName: String?
        public var terminals: [TerminalSeed]?

        public init(name: String, branch: String, displayName: String? = nil,
                    pathSuffix: String? = nil, status: WorktreeStatus? = nil,
                    hasConflicts: Bool? = nil, prStatus: PRStatus? = nil,
                    autoArchiveOnMerge: Bool? = nil, parentName: String? = nil,
                    terminals: [TerminalSeed]? = nil) {
            self.name = name
            self.branch = branch
            self.displayName = displayName
            self.pathSuffix = pathSuffix
            self.status = status
            self.hasConflicts = hasConflicts
            self.prStatus = prStatus
            self.autoArchiveOnMerge = autoArchiveOnMerge
            self.parentName = parentName
            self.terminals = terminals
        }
    }

    public struct TerminalSeed: Codable, Sendable {
        public var label: String?
        public var kind: TerminalKind?
        public var activityState: TerminalActivityState?
        public var claudeSessionID: String?
        /// Filename under the scenario's `transcripts/` directory; sets `transcriptPath`.
        public var transcriptFixture: String?
        /// Defaults to `false`.
        public var suspended: Bool?

        public init(label: String? = nil, kind: TerminalKind? = nil,
                    activityState: TerminalActivityState? = nil, claudeSessionID: String? = nil,
                    transcriptFixture: String? = nil, suspended: Bool? = nil) {
            self.label = label
            self.kind = kind
            self.activityState = activityState
            self.claudeSessionID = claudeSessionID
            self.transcriptFixture = transcriptFixture
            self.suspended = suspended
        }
    }
}
