import ArgumentParser
import Foundation
import Testing
import TBDShared

@testable import TBDCLI

@Suite("--profile and --claude-model on terminal create")
struct TerminalCreateProfileFlagsTests {
    /// The message `terminal create` refuses these arguments with, or nil
    /// when they parse.
    private func refusal(_ arguments: [String]) -> String? {
        do {
            _ = try TerminalCreate.parse(arguments)
            return nil
        } catch {
            return TerminalCreate.message(for: error)
        }
    }

    @Test func terminalCreateAcceptsProfileWithClaudeType() throws {
        let parsed = try TerminalCreate.parse(["wt", "--type", "claude", "--profile", "acme-work"])
        #expect(parsed.profile == "acme-work")
        #expect(try TerminalCreate.parse(["wt", "--type", "claude"]).profile == nil)
    }

    /// Profiles are Claude accounts: no type (a shell), an explicit shell, and
    /// Codex are all refused.
    @Test(arguments: [[], ["--type", "shell"], ["--type", "codex"], ["--cmd", "make"]])
    func terminalCreateProfileRequiresClaudeType(typeArguments: [String]) {
        #expect(refusal(["wt"] + typeArguments + ["--profile", "acme-work"])
            == "--profile requires --type claude: profiles are Claude accounts.")
    }

    @Test func terminalCreateAcceptsProfileAndModelTogether() {
        #expect(refusal(
            ["wt", "--type", "claude", "--profile", "caller", "--model", "opus"]) == nil)
    }

    @Test func terminalCreateParamsCarryOverrideProfileID() throws {
        let profileID = UUID()
        let parsed = try TerminalCreate.parse(
            ["wt", "--type", "claude", "--profile", "acme-work", "--model", "opus"])
        let params = parsed.createParams(
            worktreeID: UUID(), prompt: nil, cwd: "/work", overrideProfileID: profileID)
        #expect(params.overrideProfileID == profileID)
        #expect(params.model == "opus")
        #expect(params.type == .claude)
    }

    @Test func terminalCreateParamsWithoutProfileSendNoOverride() throws {
        let parsed = try TerminalCreate.parse(["wt", "--type", "claude"])
        let params = parsed.createParams(worktreeID: UUID(), prompt: nil, cwd: "/work")
        #expect(params.overrideProfileID == nil)
        #expect(params.model == nil)
    }
}

@Suite("--profile and --claude-model on worktree create")
struct WorktreeCreateProfileFlagsTests {
    private let repoID = UUID()

    private func refusal(_ arguments: [String]) -> String? {
        do {
            _ = try WorktreeCreate.parse(arguments)
            return nil
        } catch {
            return WorktreeCreate.message(for: error)
        }
    }

    private func params(
        _ arguments: [String], profileID: UUID? = nil
    ) throws -> WorktreeCreateParams {
        try WorktreeCreate.parse(arguments).createParams(
            repoID: repoID, prompt: nil, cwd: "/work", callerEnvID: nil, profileID: profileID)
    }

    // MARK: - Validation

    @Test(arguments: ["", "  ", "\t"])
    func worktreeCreateRefusesEmptyClaudeModel(value: String) {
        #expect(refusal(["--claude-model", value]) == "--claude-model must not be empty.")
    }

    @Test func worktreeCreateRefusesProfileWithCodexModel() {
        #expect(refusal(["--profile", "acme-work", "--codex-model", "acme-model"])
            == "--profile and --claude-model ask for a Claude first tab, and --codex-model "
            + "asks for Codex. Use one or the other.")
    }

    @Test func worktreeCreateRefusesClaudeModelWithCodexModel() {
        #expect(refusal(["--claude-model", "opus", "--codex-model", "acme-model"])
            == "--profile and --claude-model ask for a Claude first tab, and --codex-model "
            + "asks for Codex. Use one or the other.")
    }

    @Test func worktreeCreateAcceptsEachFlagAlone() {
        #expect(refusal(["--profile", "acme-work"]) == nil)
        #expect(refusal(["--claude-model", "opus"]) == nil)
        #expect(refusal(["--profile", "caller", "--claude-model", "opus"]) == nil)
        #expect(refusal(["--codex-model", "acme-model"]) == nil)
    }

    // MARK: - Params

    @Test func worktreeCreateParamsSendClaudeWhenProfileGiven() throws {
        let profileID = UUID()
        let sent = try params(["--profile", "acme-work"], profileID: profileID)
        #expect(sent.profileID == profileID)
        #expect(sent.primaryAgentPreference == .claude)
        #expect(sent.model == nil)
    }

    /// `--claude-model` alone keeps the normal profile choice: no profile ID.
    @Test func worktreeCreateParamsSendClaudeWhenClaudeModelGiven() throws {
        let sent = try params(["--claude-model", "opus"])
        #expect(sent.model == "opus")
        #expect(sent.primaryAgentPreference == .claude)
        #expect(sent.profileID == nil)
    }

    @Test func worktreeCreateParamsSendBothWhenBothGiven() throws {
        let profileID = UUID()
        let sent = try params(
            ["--profile", "acme-personal", "--claude-model", "claude-acme-model-id"],
            profileID: profileID)
        #expect(sent.profileID == profileID)
        #expect(sent.model == "claude-acme-model-id")
        #expect(sent.primaryAgentPreference == .claude)
    }

    /// Without either flag the daemon picks the first tab's agent, so the CLI
    /// sends no preference — not even alongside `--codex-model`.
    @Test func worktreeCreateParamsLeaveAgentNilWithoutFlags() throws {
        let plain = try params([])
        #expect(plain.primaryAgentPreference == nil)
        #expect(plain.profileID == nil)
        #expect(plain.model == nil)

        let codex = try params(["--codex-model", "acme-model"])
        #expect(codex.primaryAgentPreference == nil)
        #expect(codex.codexModel == "acme-model")
    }

    /// The pure helper carries the fields `run()` used to build inline.
    @Test func worktreeCreateParamsKeepTheOtherFields() throws {
        let callerID = UUID()
        let sent = try WorktreeCreate.parse([
            "--folder", "acme-folder", "--branch", "tbd/acme", "--name", "Acme",
            "--plugin-dir", "plug", "--archive-on-merge",
        ]).createParams(repoID: repoID, prompt: "hello", cwd: "/work", callerEnvID: callerID)
        #expect(sent.repoID == repoID)
        #expect(sent.folder == "acme-folder")
        #expect(sent.branch == "tbd/acme")
        #expect(sent.displayName == "Acme")
        #expect(sent.prompt == "hello")
        #expect(sent.callerWorktreeID == callerID)
        #expect(sent.pluginDirs == ["/work/plug"])
        #expect(sent.autoArchiveOnMerge == true)
    }
}
