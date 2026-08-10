import Foundation
import Testing
@testable import TBDCLI
@testable import TBDShared

@Suite("tbd pr commands")
struct PRCommandsTests {

    @Test("bind reads a hook payload from stdin and emits one attach per URL")
    func bindExtractsFromPayload() throws {
        let payload = """
        {"tool_name":"Bash",
         "tool_input":{"command":"gh pr create --fill"},
         "tool_response":{"stdout":"https://github.com/acme/acme-prod/pull/412"}}
        """
        let refs = PRBindCommand.references(fromPayload: Data(payload.utf8))
        #expect(refs.map(\.number) == [412])
    }

    @Test("bind on a non-create command yields no references")
    func bindIgnoresNonCreate() throws {
        let payload = """
        {"tool_name":"Bash",
         "tool_input":{"command":"gh pr view 412"},
         "tool_response":{"stdout":"https://github.com/acme/acme-prod/pull/412"}}
        """
        #expect(PRBindCommand.references(fromPayload: Data(payload.utf8)).isEmpty)
    }

    @Test("a PR reference parses from a URL or a bare number")
    func parseReference() throws {
        #expect(PRCommand.parseReference("https://github.com/acme/acme-prod/pull/412")?.number == 412)
        #expect(PRCommand.parseReference("412")?.number == 412)
        #expect(PRCommand.parseReference("#412")?.number == 412)
        #expect(PRCommand.parseReference("not-a-pr") == nil)
    }

    @Test("list renders one line per binding with state and branch")
    func listRendering() throws {
        let binding = PRBinding(
            worktreeID: UUID(), owner: "acme", repo: "acme-prod", number: 412,
            url: "https://github.com/acme/acme-prod/pull/412",
            headBranch: "fix-login-timeout", baseRef: "main",
            status: PRStatus(number: 412, url: "https://github.com/acme/acme-prod/pull/412",
                             state: .checksFailed, reason: "Checks failing"),
            source: .hook)
        let line = PRListCommand.renderLine(binding)
        #expect(line.contains("#412"))
        #expect(line.contains("Checks failing"))
        #expect(line.contains("fix-login-timeout"))
        #expect(line.contains("hook"))
    }

    @Test("list renders an unpolled binding without crashing")
    func listRenderingNoStatus() throws {
        let binding = PRBinding(
            worktreeID: UUID(), owner: "acme", repo: "acme-prod", number: 7,
            url: "https://github.com/acme/acme-prod/pull/7", source: .manual)
        let line = PRListCommand.renderLine(binding)
        #expect(line.contains("#7"))
        #expect(!line.isEmpty)
    }
}
