import ArgumentParser
import Foundation
import Testing
import TBDShared

@testable import TBDCLI

@Suite("Codex model options on terminal create and worktree create")
struct CodexModelOptionParsingTests {
    @Test func terminalCreateAcceptsModelWithCodexType() throws {
        let parsed = try TerminalCreate.parse(["wt", "--type", "codex", "--model", "acme-model"])
        #expect(parsed.model == "acme-model")
        #expect(parsed.type == .codex)
    }

    @Test func terminalCreateWithoutModelLeavesItNil() throws {
        let parsed = try TerminalCreate.parse(["wt", "--type", "codex"])
        #expect(parsed.model == nil)
    }

    @Test(arguments: [["--type", "claude"], ["--type", "shell"], []])
    func terminalCreateRefusesModelWithoutCodexType(typeArguments: [String]) {
        #expect(throws: (any Error).self) {
            _ = try TerminalCreate.parse(["wt"] + typeArguments + ["--model", "acme-model"])
        }
    }

    @Test func terminalCreateRefusesAnEmptyModel() {
        #expect(throws: (any Error).self) {
            _ = try TerminalCreate.parse(["wt", "--type", "codex", "--model", " "])
        }
    }

    @Test func worktreeCreateAcceptsCodexModel() throws {
        let parsed = try WorktreeCreate.parse(["--codex-model", "acme-model"])
        #expect(parsed.codexModel == "acme-model")
        #expect(try WorktreeCreate.parse([]).codexModel == nil)
    }

    @Test func worktreeCreateRefusesAnEmptyCodexModel() {
        #expect(throws: (any Error).self) {
            _ = try WorktreeCreate.parse(["--codex-model", ""])
        }
    }

    @Test func createParamsDecodeWithoutTheNewFieldsFromOlderClients() throws {
        let worktreeID = UUID()
        let terminalJSON = Data(#"{"worktreeID":"\#(worktreeID.uuidString)","type":"codex"}"#.utf8)
        let terminal = try JSONDecoder().decode(TerminalCreateParams.self, from: terminalJSON)
        #expect(terminal.model == nil)

        let repoID = UUID()
        let worktreeJSON = Data(#"{"repoID":"\#(repoID.uuidString)"}"#.utf8)
        let worktree = try JSONDecoder().decode(WorktreeCreateParams.self, from: worktreeJSON)
        #expect(worktree.codexModel == nil)
    }
}
