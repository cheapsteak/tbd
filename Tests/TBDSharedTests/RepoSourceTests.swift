import Testing
import Foundation
@testable import TBDShared

@Suite("RepoSource")
struct RepoSourceTests {
    private func parse(_ text: String, existing: Set<String> = []) -> RepoSource {
        RepoSource.parse(text, pathExists: { existing.contains($0) })
    }

    private func isInvalid(_ source: RepoSource) -> Bool {
        if case .invalid = source { return true }
        return false
    }

    @Test func existingPathWins() {
        #expect(parse("foo/bar", existing: ["foo/bar"]) == .local(path: "foo/bar"))
    }

    @Test func existingURLShapedFolderWins() {
        #expect(parse("host:repo", existing: ["host:repo"]) == .local(path: "host:repo"))
    }

    @Test func dotIsLocal() {
        #expect(parse(".", existing: ["."]) == .local(path: "."))
    }

    @Test func httpsURL() {
        let url = "https://github.com/acme/widgets.git"
        #expect(parse(url) == .remote(url: url, folderName: "widgets"))
    }

    @Test func eachScheme() {
        let urls = [
            "http://github.com/acme/widgets",
            "ssh://git@github.com/acme/widgets",
            "git://github.com/acme/widgets",
            "file:///tmp/acme/widgets.git",
            "HTTPS://github.com/acme/widgets",
        ]
        for url in urls {
            #expect(parse(url) == .remote(url: url, folderName: "widgets"), "\(url)")
        }
    }

    @Test func unsupportedScheme() {
        guard case .invalid(let reason) = parse("ftp://acme.example/widgets") else {
            Issue.record("expected invalid")
            return
        }
        #expect(reason.contains("ftp"))
    }

    @Test func scpWithUser() {
        let url = "git@github.com:acme/widgets.git"
        #expect(parse(url) == .remote(url: url, folderName: "widgets"))
    }

    @Test func scpHostAlias() {
        let url = "github-work:acme/widgets"
        #expect(parse(url) == .remote(url: url, folderName: "widgets"))
    }

    @Test func shortForm() {
        #expect(parse("acme/widgets") == .githubShortForm(owner: "acme", repo: "widgets"))
    }

    @Test func shortFormDotGit() {
        #expect(parse("acme/widgets.git") == .githubShortForm(owner: "acme", repo: "widgets"))
    }

    @Test func hostPrefixedShortForm() {
        #expect(
            parse("github.com/acme/widgets", existing: ["acme/widgets"])
                == .githubShortForm(owner: "acme", repo: "widgets")
        )
    }

    @Test func dotSlashNeverShortForm() {
        #expect(isInvalid(parse("./acme/widgets")))
    }

    @Test func tildeNeverShortForm() {
        #expect(isInvalid(parse("~/acme")))
    }

    @Test func illegalNames() {
        let inputs = [
            "ac me/widgets",
            "acme/wid gets",
            "acme/.",
            "acme/..",
            "acme/widgets/extra",
            "acme_x/widgets",
        ]
        for input in inputs {
            #expect(isInvalid(parse(input)), "\(input)")
        }
    }

    @Test func trimsSurroundingWhitespace() {
        #expect(
            parse("  https://github.com/acme/widgets\n")
                == .remote(url: "https://github.com/acme/widgets", folderName: "widgets")
        )
    }

    @Test func trailingSlashFolderName() {
        for url in ["https://github.com/acme/widgets/", "https://github.com/acme/widgets.git/"] {
            #expect(parse(url) == .remote(url: url, folderName: "widgets"), "\(url)")
        }
    }

    @Test func noFolderName() {
        #expect(isInvalid(parse("https://github.com/")))
    }

    @Test func emptyText() {
        #expect(isInvalid(parse("")))
        #expect(isInvalid(parse("   ")))
    }

    @Test func cloneFolderName() {
        #expect(RepoSource.remote(url: "u", folderName: "widgets").cloneFolderName == "widgets")
        #expect(RepoSource.githubShortForm(owner: "acme", repo: "widgets").cloneFolderName == "widgets")
        #expect(RepoSource.local(path: "/x").cloneFolderName == nil)
        #expect(RepoSource.invalid(reason: "r").cloneFolderName == nil)
    }
}
