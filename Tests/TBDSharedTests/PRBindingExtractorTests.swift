import Foundation
import Testing
@testable import TBDShared

@Suite("PR binding extraction")
struct PRBindingExtractorTests {

    private func payload(command: String, output: String) -> Data {
        let obj: [String: Any] = [
            "tool_name": "Bash",
            "tool_input": ["command": command],
            "tool_response": ["stdout": output, "stderr": "", "interrupted": false]
        ]
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    @Test("recognizes gh pr create with flags and surrounding pipeline")
    func recognizesCreate() {
        #expect(PRBindingExtractor.isPRCreateCommand("gh pr create --fill"))
        #expect(PRBindingExtractor.isPRCreateCommand("cd /tmp && gh  pr   create -t x"))
        #expect(!PRBindingExtractor.isPRCreateCommand("gh pr view 12"))
        #expect(!PRBindingExtractor.isPRCreateCommand("gh pr list"))
        #expect(!PRBindingExtractor.isPRCreateCommand("echo gh-pr-create"))
    }

    /// The false-positive guard. A quoted `gh pr create` is an argument, not a
    /// command — and treating it as one binds any PR URL in that command's
    /// output, which for an already-merged PR can hand `allResolved` an
    /// auto-archive on a worktree that never opened a PR.
    @Test("a quoted gh pr create inside another command is not a create")
    func quotedPhraseIsNotACreate() {
        #expect(!PRBindingExtractor.isPRCreateCommand("git log --grep 'gh pr create'"))
        #expect(!PRBindingExtractor.isPRCreateCommand(#"grep -rn "gh pr create" docs/"#))
        #expect(!PRBindingExtractor.isPRCreateCommand(#"echo "gh pr create""#))
        // A separator inside the quotes must not manufacture a segment either.
        #expect(!PRBindingExtractor.isPRCreateCommand(#"echo "x && gh pr create""#))
    }

    /// The false-negative half: `-R` / `--repo` between `gh` and its subcommand
    /// is the normal way to target another repo, and used to match nothing.
    @Test("repo-targeting flags before the subcommand still count as a create")
    func repoFlagsBeforeSubcommand() {
        #expect(PRBindingExtractor.isPRCreateCommand("gh --repo acme/acme-prod pr create"))
        #expect(PRBindingExtractor.isPRCreateCommand("gh -R acme/acme-prod pr create --fill"))
        #expect(PRBindingExtractor.isPRCreateCommand("gh --repo=acme/acme-prod pr create"))
    }

    /// A quoted phrase must not bind even when the surrounding command really
    /// does print a PR URL — the end-to-end shape of the false positive.
    @Test("a grep for the phrase binds nothing even when its output holds a PR URL")
    func quotedPhrasePayloadBindsNothing() {
        let found = PRBindingExtractor.extract(fromHookPayload: payload(
            command: "git log --grep 'gh pr create'",
            output: "https://github.com/acme/acme-prod/pull/412"))
        #expect(found.isEmpty)
    }

    @Test("a repo-flagged create payload binds")
    func repoFlaggedCreatePayloadBinds() {
        let found = PRBindingExtractor.extract(fromHookPayload: payload(
            command: "gh -R acme/acme-prod pr create --fill",
            output: "https://github.com/acme/acme-prod/pull/412"))
        #expect(found.map(\.number) == [412])
    }

    @Test("parses one PR URL")
    func parsesOne() {
        let found = PRBindingExtractor.parsePRURLs(
            in: "https://github.com/acme/acme-prod/pull/412\n")
        #expect(found.count == 1)
        #expect(found[0].owner == "acme")
        #expect(found[0].repo == "acme-prod")
        #expect(found[0].number == 412)
        #expect(found[0].host == "github.com")
    }

    @Test("parses several URLs and de-duplicates")
    func parsesMany() {
        let text = """
        created https://github.com/acme/acme-prod/pull/412
        also https://github.com/acme/other-repo/pull/7
        again https://github.com/acme/acme-prod/pull/412
        """
        let found = PRBindingExtractor.parsePRURLs(in: text)
        #expect(found.count == 2)
        #expect(found.map(\.number).sorted() == [7, 412])
    }

    @Test("rejects dot path segments")
    func rejectsDotSegments() {
        #expect(PRBindingExtractor.parsePRURLs(
            in: "https://github.com/../acme-prod/pull/1").isEmpty)
        #expect(PRBindingExtractor.parsePRURLs(
            in: "https://github.com/acme/./pull/1").isEmpty)
    }

    @Test("ignores non-github and non-pull URLs")
    func ignoresOthers() {
        #expect(PRBindingExtractor.parsePRURLs(
            in: "https://gitlab.com/acme/acme-prod/pull/1").isEmpty)
        #expect(PRBindingExtractor.parsePRURLs(
            in: "https://github.com/acme/acme-prod/issues/1").isEmpty)
    }

    @Test("extracts from a create payload")
    func extractsFromCreate() {
        let found = PRBindingExtractor.extract(fromHookPayload: payload(
            command: "gh pr create --fill",
            output: "https://github.com/acme/acme-prod/pull/412"))
        #expect(found.count == 1)
        #expect(found[0].number == 412)
    }

    @Test("a non-create command mentioning a PR URL binds nothing")
    func nonCreateBindsNothing() {
        let found = PRBindingExtractor.extract(fromHookPayload: payload(
            command: "echo https://github.com/acme/acme-prod/pull/412",
            output: "https://github.com/acme/acme-prod/pull/412"))
        #expect(found.isEmpty)
    }

    @Test("a create command with no URL in output binds nothing")
    func createWithNoURL() {
        let found = PRBindingExtractor.extract(fromHookPayload: payload(
            command: "gh pr create --fill", output: "error: no commits"))
        #expect(found.isEmpty)
    }

    @Test("malformed JSON yields nothing rather than throwing")
    func malformedJSON() {
        #expect(PRBindingExtractor.extract(
            fromHookPayload: Data("not json".utf8)).isEmpty)
    }

    @Test("scans a string tool_response as well as an object one")
    func stringToolResponse() {
        let obj: [String: Any] = [
            "tool_name": "Bash",
            "tool_input": ["command": "gh pr create"],
            "tool_response": "https://github.com/acme/acme-prod/pull/9"
        ]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        #expect(PRBindingExtractor.extract(fromHookPayload: data).first?.number == 9)
    }
}
