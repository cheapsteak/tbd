import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

/// Tier 1. Every file the resolver would read is supplied through its injected
/// reader, so no real home directory — the developer's or a scratch one — is
/// involved and the suite needs no `TBD_HOME` serialization.
@Suite struct OperatorStatuslineResolverTests {

    private static func settings(_ command: String) -> String {
        #"{"statusLine":{"type":"command","command":"\#(command)"}}"#
    }

    /// A reader over an in-memory filesystem.
    private static func reader(_ files: [String: String]) -> (String) -> Data? {
        { path in files[path].map { Data($0.utf8) } }
    }

    private static let worktree = "/w"
    private static let hostHome = "/host/.claude"
    private static let environment = ["TBD_CLAUDE_HOST_HOME": hostHome]
    private static let localPath = "/w/.claude/settings.local.json"
    private static let projectPath = "/w/.claude/settings.json"
    private static let userPath = "/host/.claude/settings.json"

    /// Every scope populated. Removing scopes one at a time from the top walks
    /// the precedence order, so each case asserts the *whole* ladder rather
    /// than one rung.
    private static let allScopes: [String: String] = [
        localPath: settings("local"),
        projectPath: settings("project"),
        userPath: settings("user"),
    ]

    private static func resolve(
        perSpawn: String? = nil,
        repo: String? = nil,
        files: [String: String] = allScopes,
        worktreePath: String? = worktree
    ) -> String? {
        OperatorStatuslineResolver.resolve(
            perSpawnSettingsJSON: perSpawn,
            repoSettingsJSON: repo,
            worktreePath: worktreePath,
            environment: environment,
            readFile: reader(files)
        )
    }

    @Test func perSpawnFragmentWinsOverEveryOtherScope() {
        #expect(Self.resolve(perSpawn: Self.settings("spawn"), repo: Self.settings("repo")) == "spawn")
    }

    @Test func repoFragmentWinsOverTheFileScopes() {
        #expect(Self.resolve(repo: Self.settings("repo")) == "repo")
    }

    @Test func projectLocalWinsOverProjectAndUser() {
        #expect(Self.resolve() == "local")
    }

    @Test func projectWinsOverUser() {
        var files = Self.allScopes
        files[Self.localPath] = nil
        #expect(Self.resolve(files: files) == "project")
    }

    @Test func userScopeIsTheLastResort() {
        #expect(Self.resolve(files: [Self.userPath: Self.settings("user")]) == "user")
    }

    @Test func consultsExactlyTheDocumentedScopesInOrder() {
        // Whitelist, not blacklist: assert the composed list of paths the
        // resolver actually asked for. A managed/enterprise settings path must
        // not appear — a managed statusline outranks TBD's overlay, so the tee
        // never runs there and reading it would only invite acting on it.
        var asked: [String] = []
        _ = OperatorStatuslineResolver.resolve(
            worktreePath: Self.worktree,
            environment: Self.environment,
            readFile: { path in asked.append(path); return nil }
        )
        #expect(asked == [Self.localPath, Self.projectPath, Self.userPath])
    }

    @Test func userScopeHonorsTheClaudeHostHomeOverride() {
        // The path is derived through `TBDConstants.claudeHostHome`, so the
        // test fence redirects it exactly as it redirects `~/tbd`. A
        // hand-built `$HOME/.claude` here would read the developer's real one.
        var asked: [String] = []
        _ = OperatorStatuslineResolver.resolve(
            environment: ["TBD_CLAUDE_HOST_HOME": "/elsewhere/store"],
            readFile: { path in asked.append(path); return nil }
        )
        #expect(asked == ["/elsewhere/store/settings.json"])
    }

    @Test func noStatuslineAnywhereResolvesToNil() {
        #expect(Self.resolve(files: [:]) == nil)
    }

    @Test func missingUnreadableAndMalformedFilesAreSkipped() {
        let files = [
            Self.localPath: "{ not json at all",
            Self.projectPath: #"{"statusLine":"a bare string, not an object"}"#,
            Self.userPath: Self.settings("user"),
        ]
        // Each broken scope is stepped over rather than throwing or resolving
        // to a wrong value; the first well-formed one wins.
        #expect(Self.resolve(files: files) == "user")
    }

    @Test func statuslineWithoutACommandIsNotAScopeHit() {
        let files = [
            Self.localPath: #"{"statusLine":{"type":"command","padding":0}}"#,
            Self.projectPath: #"{"statusLine":{"type":"command","command":"   "}}"#,
            Self.userPath: Self.settings("user"),
        ]
        #expect(Self.resolve(files: files) == "user")
    }

    @Test func malformedFragmentDoesNotShadowALaterScope() {
        #expect(Self.resolve(perSpawn: "{oops", files: [Self.userPath: Self.settings("user")]) == "user")
    }

    @Test func withoutAWorktreePathOnlyTheUserScopeIsConsulted() {
        // A scratch space has no project scope to read; the project files must
        // not be consulted from some other session's cwd.
        #expect(Self.resolve(worktreePath: nil) == "user")
    }

    // MARK: - The user scope belongs to the session's own config dir

    private static let profileDir = "/profiles/p1"
    private static let profileUserPath = "/profiles/p1/settings.json"

    /// A desk spawned under a model profile runs with `CLAUDE_CONFIG_DIR`
    /// pointed at the profile directory, so Claude Code's user-scope
    /// `settings.json` for that session lives there — not in the host store.
    /// Reading the host store would hand the tee a statusline the session never
    /// sees.
    @Test func aProfileBackedSessionsUserScopeIsInsideItsConfigDir() {
        var asked: [String] = []
        _ = OperatorStatuslineResolver.resolve(
            worktreePath: Self.worktree,
            profileConfigDir: Self.profileDir,
            environment: Self.environment,
            readFile: { path in asked.append(path); return nil }
        )
        // Whitelist: exactly the three scopes, with the profile's own
        // `settings.json` standing in for the user one. The host store must not
        // appear at all — for this session it is not a scope.
        #expect(asked == [Self.localPath, Self.projectPath, Self.profileUserPath])
    }

    @Test func theProfilesUserScopeSuppliesTheDelegateCommand() {
        let command = OperatorStatuslineResolver.resolve(
            worktreePath: Self.worktree,
            profileConfigDir: Self.profileDir,
            environment: Self.environment,
            readFile: Self.reader([
                Self.userPath: Self.settings("host store"),
                Self.profileUserPath: Self.settings("profile store"),
            ])
        )
        #expect(command == "profile store")
    }

    /// And with no profile the host store is still the user scope — the fix
    /// adds a case, it does not move the ambient one.
    @Test func withoutAProfileTheHostStoreIsStillTheUserScope() {
        #expect(Self.resolve(files: [Self.userPath: Self.settings("user")]) == "user")
    }
}
