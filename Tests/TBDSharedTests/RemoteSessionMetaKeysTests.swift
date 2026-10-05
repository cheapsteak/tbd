import Testing
@testable import TBDShared

@Suite("Remote session meta keys")
struct RemoteSessionMetaKeysTests {

    // MARK: branch-name rule (docs/remote-provider-contract.md, land <id>)

    @Test("ordinary branch names are acceptable", arguments: [
        "main", "claude/fix-flaky-ci", "feature/x.y_z-1", "a", "release/2026.09",
    ])
    func acceptsOrdinary(_ name: String) {
        #expect(RemoteBranchName.isAcceptable(name))
    }

    @Test("names that break a contract rule are rejected", arguments: [
        "", "@", "-rf", ".hidden", "/abs", "trail/", "trail.", "x.lock",
        "a..b", "a//b", "a@{1}", "has space", "tab\there", "ctl\u{7}x",
        "caf\u{e9}", "semi;colon", "tilde~1", "caret^", "colon:x", "q?", "star*", "br[",
        "back\\slash",
    ])
    func rejectsRuleBreakers(_ name: String) {
        #expect(!RemoteBranchName.isAcceptable(name))
    }

    // MARK: live branch

    @Test("the live branch is meta.branch when it passes the rule")
    func liveBranchPresent() {
        #expect(RemoteSessionPayload.metaLiveBranch(["branch": "claude/fix-x"]) == "claude/fix-x")
    }

    @Test("absent, blank, or rule-breaking branch reads as no live branch")
    func liveBranchAbsentOrInvalid() {
        #expect(RemoteSessionPayload.metaLiveBranch(nil) == nil)
        #expect(RemoteSessionPayload.metaLiveBranch([:]) == nil)
        #expect(RemoteSessionPayload.metaLiveBranch(["branch": ""]) == nil)
        #expect(RemoteSessionPayload.metaLiveBranch(["branch": "   "]) == nil)
        // Not trimmed: a padded value is not a branch name, and trimming would
        // accept something the contract's rule rejects.
        #expect(RemoteSessionPayload.metaLiveBranch(["branch": " main"]) == nil)
        #expect(RemoteSessionPayload.metaLiveBranch(["branch": "-rf"]) == nil)
    }

    // MARK: location

    @Test("accepted location forms keep their verbatim value", arguments: [
        ("devbox:/srv/acme-api", "devbox", "/srv/acme-api"),
        ("dev@devbox.acme.example:/home/dev/acme-prod", "dev@devbox.acme.example", "/home/dev/acme-prod"),
        ("[fe80::1]:/srv/acme-api", "[fe80::1]", "/srv/acme-api"),
        ("host:/", "host", "/"),
    ])
    func acceptsLocation(_ raw: String, _ host: String, _ path: String) {
        let parsed = RemoteSessionLocation.parse(raw)
        #expect(parsed == RemoteSessionLocation(value: raw, host: host, path: path))
    }

    @Test("rejected location forms", arguments: [
        "devbox:srv/acme",          // relative path
        ":/srv/acme",               // missing host
        "/srv/acme",                // no host separator at all
        "fe80::1:/srv/acme",        // unbracketed IPv6 literal
        "devbox:22:/srv/acme",      // port
        "[fe80::1]:22:/srv/acme",   // port after bracketed host
        "[fe80::1]/srv/acme",       // bracket not followed by ':'
        "[]:/srv",                  // empty bracket
        "devbox:/srv/acme api",     // whitespace
        "devbox:/srv/\tacme",       // whitespace (tab)
        "devbox:/srv/\u{1}acme",    // control character
        "devbox:/srv/\u{7F}acme",   // DEL
        "ssh://devbox/srv/acme",    // scheme (Review Focus 1)
        "@devbox:/srv",             // empty user
        "dev@:/srv",                // empty hostname
        "",
    ])
    func rejectsLocation(_ raw: String) {
        #expect(RemoteSessionLocation.parse(raw) == nil)
    }

    @Test("metaLocation reads the well-known key and treats junk as absent")
    func metaLocationKey() {
        #expect(RemoteSessionPayload.metaLocation(["location": "devbox:/srv/a"])?.value == "devbox:/srv/a")
        #expect(RemoteSessionPayload.metaLocation(["location": "nope"]) == nil)
        #expect(RemoteSessionPayload.metaLocation(nil) == nil)
    }

    // MARK: prs

    @Test("prs keeps GitHub and GitLab URLs and drops junk entries individually")
    func prsParsesAndDropsJunk() throws {
        let list = try #require(RemoteSessionPayload.metaPRs(["prs":
            "https://github.com/acme/api/pull/7 junk\nhttps://gitlab.acme.example/acme/sub/web/-/merge_requests/3\thttp://x"]))
        #expect(list.accepted.map(\.number) == [7, 3])
        #expect(list.accepted[1].owner == "acme/sub")
        #expect(list.rejected == ["junk", "http://x"])
        #expect(list.overflow.isEmpty)
    }

    @Test("prs accepts a GitHub PR URL on a host other than github.com")
    func prsAcceptsGitHubEnterpriseHost() throws {
        let url = "https://ghe.acme.example/acme/api/pull/7"
        let list = try #require(RemoteSessionPayload.metaPRs(["prs": url]))
        let parsed = try #require(list.accepted.first)
        #expect(list.accepted.count == 1)
        #expect(list.rejected.isEmpty)
        #expect(parsed.host == "ghe.acme.example")
        #expect(parsed.owner == "acme")
        #expect(parsed.repo == "api")
        #expect(parsed.number == 7)
        #expect(parsed.url == url)
        #expect(Forge.forURL(parsed.url) == .github)
    }

    @Test("absent prs is nil; empty prs is an empty list")
    func prsAbsentVsEmpty() {
        #expect(RemoteSessionPayload.metaPRs(nil) == nil)
        #expect(RemoteSessionPayload.metaPRs(["repo": "acme/api"]) == nil)
        #expect(RemoteSessionPayload.metaPRs(["prs": "  "])?.accepted.isEmpty == true)
    }

    @Test("the same PR named twice uses one slot (Review Focus 2)")
    func prsDedupesCaseInsensitively() throws {
        let list = try #require(RemoteSessionPayload.metaPRs(["prs":
            "https://github.com/Acme/API/pull/7 https://github.com/acme/api/pull/7"]))
        #expect(list.accepted.count == 1)
        #expect(list.rejected.isEmpty)
    }

    @Test("at most 20 are accepted; the rest are reported as overflow")
    func prsCap() throws {
        let urls = (1...23).map { "https://github.com/acme/api/pull/\($0)" }.joined(separator: " ")
        let list = try #require(RemoteSessionPayload.metaPRs(["prs": urls]))
        #expect(list.accepted.map(\.number) == Array(1...20))
        #expect(list.overflow.map(\.number) == [21, 22, 23])
    }
}
