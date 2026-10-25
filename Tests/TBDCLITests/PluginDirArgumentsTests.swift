import Foundation
import Testing
import TBDShared

@testable import TBDCLI

@Suite("--plugin-dir on terminal create")
struct PluginDirArgumentsTests {
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
}
