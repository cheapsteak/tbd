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
        #expect(terminal.codexDisabledFeatures == nil)

        let repoID = UUID()
        let worktreeJSON = Data(#"{"repoID":"\#(repoID.uuidString)"}"#.utf8)
        let worktree = try JSONDecoder().decode(WorktreeCreateParams.self, from: worktreeJSON)
        #expect(worktree.codexModel == nil)
    }

    @Test func terminalCreateAcceptsRepeatedCodexDisable() throws {
        let parsed = try TerminalCreate.parse(
            ["wt", "--type", "codex", "--codex-disable", "computer_use", "--codex-disable", "apps"])
        #expect(parsed.codexDisable == ["computer_use", "apps"])
        #expect(try TerminalCreate.parse(["wt", "--type", "codex"]).codexDisable.isEmpty)
    }

    @Test(arguments: [["--type", "claude"], ["--type", "shell"], []])
    func terminalCreateRefusesCodexDisableWithoutCodexType(typeArguments: [String]) {
        #expect(throws: (any Error).self) {
            _ = try TerminalCreate.parse(["wt"] + typeArguments + ["--codex-disable", "computer_use"])
        }
    }

    @Test(arguments: ["", "Computer-Use", "a b", "x;y", "--model"])
    func terminalCreateRefusesMalformedCodexDisable(feature: String) {
        #expect(throws: (any Error).self) {
            _ = try TerminalCreate.parse(["wt", "--type", "codex", "--codex-disable", feature])
        }
    }

    @Test func disabledFeatureParamsRoundTripAndNormalize() throws {
        let params = TerminalCreateParams(
            worktreeID: UUID(), type: .codex, codexDisabledFeatures: ["browser_use"])
        let decoded = try JSONDecoder().decode(
            TerminalCreateParams.self, from: JSONEncoder().encode(params))
        #expect(decoded.codexDisabledFeatures == ["browser_use"])
        #expect(try TerminalCreateParams.normalizedCodexDisabledFeatures(
            ["apps", "computer_use", "apps"]) == ["apps", "computer_use"])
    }

    @Test func disabledFeatureWithSurroundingWhitespaceIsRefusedNotTrimmed() {
        #expect(throws: (any Error).self) {
            try TerminalCreateParams.normalizedCodexDisabledFeatures([" computer_use "])
        }
        #expect(throws: (any Error).self) {
            try TerminalCreateParams.normalizedCodexDisabledFeatures(["apps\n"])
        }
    }

    @Test func terminalCreateResolvesRelativeCodexHomeBeforeRequest() throws {
        let parsed = try TerminalCreate.parse(
            ["wt", "--type", "codex", "--codex-home", "profiles/../guarded"])
        #expect(TerminalCreate.normalizedCodexHomePath(
            parsed.codexHome, currentDirectoryPath: "/synthetic/worktree")
            == "/synthetic/worktree/guarded")
        #expect(TerminalCreate.normalizedCodexHomePath(
            "/synthetic/../guarded", currentDirectoryPath: "/synthetic/worktree")
            == "/synthetic/../guarded")
    }
}
