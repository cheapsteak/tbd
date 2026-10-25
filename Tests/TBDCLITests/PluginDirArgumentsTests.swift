import ArgumentParser
import Foundation
import Testing
import TBDShared

@testable import TBDCLI

@Suite("--plugin-dir on terminal create")
struct PluginDirArgumentsTests {
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

    @Test func relativePathsBecomeAbsolute() {
        #expect(CLIPluginDirs.absolute(["./p", "/abs", "~/h"], cwd: "/work")
            == ["/work/p", "/abs", "~/h"])
    }

    @Test func parentStepsAreStandardized() {
        #expect(CLIPluginDirs.absolute(["../p", "q/./r"], cwd: "/work/sub")
            == ["/work/p", "/work/sub/q/r"])
    }

    @Test func repeatedPluginDirParsesInOrder() throws {
        let parsed = try TerminalCreate.parse(
            ["wt", "--type", "claude", "--plugin-dir", "a", "--plugin-dir", "/b"])
        #expect(parsed.pluginDirs == ["a", "/b"])
    }

    @Test func pluginDirsReachTheParamsAbsolute() throws {
        let parsed = try TerminalCreate.parse(
            ["wt", "--type", "claude", "--plugin-dir", "plug", "--plugin-dir", "~/h"])
        let params = parsed.createParams(worktreeID: UUID(), prompt: nil, cwd: "/work")
        #expect(params.pluginDirs == ["/work/plug", "~/h"])
    }

    @Test func noPluginDirSendsNone() throws {
        let parsed = try TerminalCreate.parse(["wt", "--type", "claude"])
        #expect(parsed.pluginDirs.isEmpty)
        let params = parsed.createParams(worktreeID: UUID(), prompt: nil, cwd: "/work")
        #expect(params.pluginDirs == nil)
    }

    // MARK: - Refusals

    /// A blank value would resolve to the current folder, which exists, and
    /// load it as a plugin folder.
    @Test(arguments: ["", "  ", "\t"])
    func blankPluginDirRefused(value: String) {
        #expect(refusal(["wt", "--type", "claude", "--plugin-dir", "/ok", "--plugin-dir", value])
            == CLIPluginDirs.blankValueMessage)
    }

    /// Every shape the daemon treats as a shell or Codex terminal: no type
    /// (with or without `--cmd`), shell and codex.
    @Test(arguments: [[], ["--cmd", "make"], ["--type", "shell"], ["--type", "codex"]])
    func pluginDirWithoutClaudeTypeRefused(typeArguments: [String]) {
        #expect(refusal(["wt"] + typeArguments + ["--plugin-dir", "/plug"])
            == TerminalCreateParams.pluginDirsRequireClaudeMessage)
    }

    /// `--cmd` does not make a Claude-typed terminal a shell; the daemon starts
    /// Claude, so the plugin folders are accepted.
    @Test func claudeTypeWithCmdAcceptsPluginDir() {
        #expect(refusal(["wt", "--type", "claude", "--cmd", "make", "--plugin-dir", "/plug"]) == nil)
    }

    @Test func noPluginDirLeavesOtherKindsAlone() {
        #expect(refusal(["wt"]) == nil)
        #expect(refusal(["wt", "--type", "shell"]) == nil)
    }
}
