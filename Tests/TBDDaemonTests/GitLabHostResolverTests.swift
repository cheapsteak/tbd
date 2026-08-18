import Foundation
import Testing
@testable import TBDDaemonLib

@Suite("GitLab host resolution")
struct GitLabHostResolverTests {

    /// Real `glab auth status` output shape: host lines are flush-left, detail
    /// lines are indented. Reproduced from a self-managed instance (#673).
    static let realOutput = """
    git.acme.example
      ✓ Logged in to git.acme.example as someone (/Users/x/.config/glab-cli/config.yml)
      ! Invalid token provided in configuration file
      ✓ Git operations for git.acme.example configured to use ssh protocol.
    gitlab.com
      x gitlab.com: API call failed: GET https://gitlab.com/api/v4/user: 401 {message: 401 Unauthorized}
      ! No token found (checked config file, keyring, and environment variables).
    """

    @Test("extracts every configured host from flush-left lines")
    func parsesHosts() {
        let hosts = GitLabHostResolver.parseAuthStatusHosts(Self.realOutput)
        #expect(hosts == ["git.acme.example", "gitlab.com"])
    }

    @Test("a host reporting both logged-in and invalid-token is still a GitLab host")
    func contradictoryBlockStillYieldsHost() {
        // TBD reads the host LIST, never the auth verdict — the verdict text is
        // measurably self-contradictory while calls succeed (#673).
        #expect(GitLabHostResolver.parseAuthStatusHosts(Self.realOutput).contains("git.acme.example"))
    }

    @Test("exit status 1 does not suppress the host list")
    func exitOneStillYieldsHosts() async {
        // glab exits 1 if ANY configured host fails, so a working setup reports
        // failure whenever an unused gitlab.com entry sits alongside it.
        let resolver = GitLabHostResolver(glRunner: { _, _ in
            GHCommandResult(stdout: Self.realOutput, stderr: "", exitStatus: 1)
        })
        #expect(await resolver.isGitLabHost("git.acme.example", repoPath: "/tmp/x"))
    }

    @Test("github.com is never probed")
    func githubIsNotProbed() async {
        let probed = Probe()
        let resolver = GitLabHostResolver(glRunner: { _, _ in
            await probed.mark()
            return GHCommandResult(stdout: Self.realOutput)
        })
        #expect(await resolver.isGitLabHost("github.com", repoPath: "/tmp/x") == false)
        #expect(await probed.count == 0)
    }

    @Test("an unlisted host is not GitLab")
    func unlistedHostIsNotGitLab() async {
        let resolver = GitLabHostResolver(glRunner: { _, _ in
            GHCommandResult(stdout: Self.realOutput)
        })
        #expect(await resolver.isGitLabHost("git.other.example", repoPath: "/tmp/x") == false)
    }

    @Test("absent glab yields no hosts")
    func absentGlab() async {
        let resolver = GitLabHostResolver(glRunner: { _, _ in nil })
        #expect(await resolver.isGitLabHost("git.acme.example", repoPath: "/tmp/x") == false)
    }

    @Test("the host list is fetched once and cached for the resolver's life")
    func cachesAcrossCalls() async {
        let probed = Probe()
        let resolver = GitLabHostResolver(glRunner: { _, _ in
            await probed.mark()
            return GHCommandResult(stdout: Self.realOutput)
        })
        _ = await resolver.isGitLabHost("git.acme.example", repoPath: "/tmp/x")
        _ = await resolver.isGitLabHost("git.acme.example", repoPath: "/tmp/x")
        #expect(await probed.count == 1)
    }

    @Test("host matching is case-insensitive in both directions")
    func hostMatchingIsCaseInsensitive() async {
        let resolver = GitLabHostResolver(glRunner: { _, _ in
            GHCommandResult(stdout: "GIT.Acme.Example\n  ✓ Logged in\n")
        })
        #expect(await resolver.isGitLabHost("git.ACME.example", repoPath: "/tmp/x"))
    }

    @Test("indented detail lines never become hosts")
    func indentedLinesAreNotHosts() {
        // The failing host's detail line contains a bare "gitlab.com:" token and
        // a full URL; neither may be mistaken for a declared host.
        let hosts = GitLabHostResolver.parseAuthStatusHosts("""
        git.acme.example
          x gitlab.com: API call failed: GET https://gitlab.com/api/v4/user
        """)
        #expect(hosts == ["git.acme.example"])
    }

    /// CRLF is not exotic here: `glab auth status` is read through a pipe whose
    /// contents come from whatever the host and the user's terminal settings
    /// produced. A trailing `\r` clears both guards below the split — it is not
    /// a space and it is not a dot — so the parse "succeeds" with a host name
    /// nobody will ever ask about, and GitLab is silently off with no error
    /// anywhere.
    @Test("a CRLF-terminated host line still resolves")
    func crlfTerminatedHostResolves() async {
        let crlf = "git.acme.example\r\n  ✓ Logged in to git.acme.example as someone\r\n"
        #expect(GitLabHostResolver.parseAuthStatusHosts(crlf) == ["git.acme.example"])

        let resolver = GitLabHostResolver(glRunner: { _, _ in GHCommandResult(stdout: crlf) })
        #expect(await resolver.isGitLabHost("git.acme.example", repoPath: "/tmp/x"))
    }
}

private actor Probe {
    private(set) var count = 0
    func mark() { count += 1 }
}
