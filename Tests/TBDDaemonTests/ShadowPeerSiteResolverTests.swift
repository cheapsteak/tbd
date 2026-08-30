import Foundation
import Testing

@testable import TBDDaemonLib
@testable import TBDShared

/// `WorktreeShadowPeerSiteResolver` — the production join from a provider's own
/// session id to the worktree row TBD adopted that session into.
///
/// A shadow peer needs both halves of a site and may invent neither: a made-up
/// display name is an identity peers would go on to address, and a made-up
/// `cwd` is a directory that does not exist. So every case that cannot produce
/// both halves resolves to nothing, and the manager's existing unmirrored path
/// takes it from there.
///
/// Tier 1: an in-memory database, and the directory check is injected — nothing
/// here touches `~/tbd` or a real checkout.
@Suite("Shadow peer site resolver")
struct ShadowPeerSiteResolverTests {

    private static let repoPath = "/opt/peertest/repos/acme"

    private struct Fixture {
        let db: TBDDatabase
        let repo: Repo
    }

    private static func makeFixture() async throws -> Fixture {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: repoPath, displayName: "acme", defaultBranch: "main")
        return Fixture(db: db, repo: repo)
    }

    private static func resolver(
        _ fixture: Fixture,
        provider: String = "acme-cloud",
        directoriesThatExist: Set<String> = [repoPath]
    ) -> WorktreeShadowPeerSiteResolver {
        WorktreeShadowPeerSiteResolver(
            provider: provider,
            worktrees: fixture.db.worktrees,
            repos: fixture.db.repos,
            directoryExists: { directoriesThatExist.contains($0) })
    }

    /// The join key is the provider's session id, and the answer is the row's
    /// own display name plus a directory that exists **here**. The row's
    /// `localPath` cannot supply the latter: on a remote row it is the
    /// synthetic `remote://` URI the column's NOT NULL constraint needs, with
    /// no files behind it.
    @Test func anAdoptedSessionResolvesToItsDisplayNameAndALocalDirectory() async throws {
        let fixture = try await Self.makeFixture()
        let row = try await fixture.db.worktrees.createRemote(
            repoID: fixture.repo.id,
            name: "api-lane",
            displayName: "api-lane",
            branch: "tbd/api-lane",
            provider: "acme-cloud",
            sessionID: "sess-42")

        let site = try #require(
            await Self.resolver(fixture).site(forProviderSessionID: "sess-42"))

        #expect(site.worktreeDisplayName == row.displayName)
        #expect(site.path == Self.repoPath)
        #expect(FileManager.default.fileExists(atPath: row.localPath) == false,
                "the row's own path is a remote:// URI, which is why it cannot be the cwd")
    }

    /// A session TBD adopted no row for is not mirrored. Nil here is "publish
    /// nothing", never "publish one with a guess".
    @Test func anUnadoptedSessionResolvesToNothing() async throws {
        let fixture = try await Self.makeFixture()
        _ = try await fixture.db.worktrees.createRemote(
            repoID: fixture.repo.id,
            name: "api-lane",
            displayName: "api-lane",
            branch: "tbd/api-lane",
            provider: "acme-cloud",
            sessionID: "sess-42")

        #expect(await Self.resolver(fixture).site(forProviderSessionID: "sess-99") == nil)
    }

    /// `providerSessionID` is unique only within a provider, so the resolver is
    /// scoped to one. A resolver that searched across providers could site a
    /// shadow into another provider's lane.
    @Test func aSessionIDBelongingToAnotherProviderResolvesToNothing() async throws {
        let fixture = try await Self.makeFixture()
        _ = try await fixture.db.worktrees.createRemote(
            repoID: fixture.repo.id,
            name: "api-lane",
            displayName: "api-lane",
            branch: "tbd/api-lane",
            provider: "other-cloud",
            sessionID: "sess-42")

        #expect(await Self.resolver(fixture).site(forProviderSessionID: "sess-42") == nil)
    }

    /// The `cwd` is verified rather than assumed. A repository whose checkout
    /// was moved or deleted would otherwise publish a shadow pointing at
    /// nothing, and a surface filtering on the directory existing would drop
    /// the row anyway — silently.
    @Test func aRepositoryDirectoryThatIsGoneResolvesToNothing() async throws {
        let fixture = try await Self.makeFixture()
        _ = try await fixture.db.worktrees.createRemote(
            repoID: fixture.repo.id,
            name: "api-lane",
            displayName: "api-lane",
            branch: "tbd/api-lane",
            provider: "acme-cloud",
            sessionID: "sess-42")

        let resolver = Self.resolver(fixture, directoriesThatExist: [])
        #expect(await resolver.site(forProviderSessionID: "sess-42") == nil)
    }
}
