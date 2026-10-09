import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib

@Suite("GitHub authenticated-host resolution")
struct GitHubHostResolverTests {

    /// `gh auth status` shape: host lines flush-left, details indented.
    static let output = """
    github.com
      ✓ Logged in to github.com account someone (keyring)
      - Active account: true
    ghe.acme.example
      ✓ Logged in to ghe.acme.example account someone (keyring)
    """

    private actor Calls {
        var count = 0
        func bump() { count += 1 }
    }

    @Test("a host gh is logged in to is allowed; any other host is not")
    func listedHostsOnly() async {
        let resolver = GitHubHostResolver(ghRunner: { _, _ in GHCommandResult(stdout: Self.output) })
        #expect(await resolver.isAuthenticatedHost("ghe.acme.example", repoPath: "/tmp/x"))
        #expect(await resolver.isAuthenticatedHost("GHE.acme.example", repoPath: "/tmp/x"))
        #expect(await resolver.isAuthenticatedHost("evil.example", repoPath: "/tmp/x") == false)
    }

    @Test("github.com is allowed without spawning gh")
    func gitHubDotComShortCircuits() async {
        let calls = Calls()
        let resolver = GitHubHostResolver(ghRunner: { _, _ in await calls.bump(); return nil })
        #expect(await resolver.isAuthenticatedHost("github.com", repoPath: "/tmp/x"))
        #expect(await calls.count == 0)
    }

    @Test("gh failing to launch allows nothing and is not remembered")
    func launchFailureAllowsNothing() async {
        let calls = Calls()
        let resolver = GitHubHostResolver(ghRunner: { _, _ in await calls.bump(); return nil })
        #expect(await resolver.isAuthenticatedHost("ghe.acme.example", repoPath: "/tmp/x") == false)
        #expect(await resolver.isAuthenticatedHost("ghe.acme.example", repoPath: "/tmp/x") == false)
        #expect(await calls.count == 2)
    }

    @Test("the host list is cached within its lifetime and re-read after it")
    func hostListAgesOut() async {
        let calls = Calls()
        let dates = TestDateSource()
        let resolver = GitHubHostResolver(
            ghRunner: { _, _ in await calls.bump(); return GHCommandResult(stdout: Self.output) },
            now: dates.provider)
        _ = await resolver.isAuthenticatedHost("ghe.acme.example", repoPath: "/tmp/x")
        _ = await resolver.isAuthenticatedHost("evil.example", repoPath: "/tmp/x")
        #expect(await calls.count == 1)
        dates.advance(by: GitHubHostResolver.hostListLifetime - 1)
        _ = await resolver.isAuthenticatedHost("ghe.acme.example", repoPath: "/tmp/x")
        #expect(await calls.count == 1)
        dates.advance(by: 2)
        _ = await resolver.isAuthenticatedHost("ghe.acme.example", repoPath: "/tmp/x")
        #expect(await calls.count == 2)
    }
}
