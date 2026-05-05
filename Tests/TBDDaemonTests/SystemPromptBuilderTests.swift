import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("SystemPromptBuilder Tests")
struct SystemPromptBuilderTests {

    // MARK: - Shell Escaping

    @Test("shellEscape wraps text in single quotes")
    func shellEscapeSimple() {
        let result = SystemPromptBuilder.shellEscape("hello world")
        #expect(result == "'hello world'")
    }

    @Test("shellEscape handles single quotes")
    func shellEscapeSingleQuotes() {
        let result = SystemPromptBuilder.shellEscape("don't mock")
        #expect(result == "'don'\\''t mock'")
    }

    @Test("shellEscape handles double quotes")
    func shellEscapeDoubleQuotes() {
        let result = SystemPromptBuilder.shellEscape("use \"pytest\"")
        #expect(result == "'use \"pytest\"'")
    }

    @Test("shellEscape handles newlines")
    func shellEscapeNewlines() {
        let result = SystemPromptBuilder.shellEscape("line1\nline2")
        #expect(result == "'line1\nline2'")
    }

    @Test("shellEscape handles special shell characters")
    func shellEscapeSpecialChars() {
        let result = SystemPromptBuilder.shellEscape("$HOME `cmd` $(eval)")
        #expect(result == "'$HOME `cmd` $(eval)'")
    }

    // MARK: - Build Prompt

    @Test("build returns nil for resumed sessions")
    func buildReturnsNilForResume() {
        let repo = Repo(path: "/test", displayName: "test", defaultBranch: "main")
        let wt = Worktree(repoID: repo.id, name: "test-wt", displayName: "test-wt",
                          branch: "tbd/test-wt", path: "/test/.tbd/worktrees/test-wt",
                          tmuxServer: "tbd-test")

        let result = SystemPromptBuilder.build(repo: repo, worktree: wt, isResume: true)
        #expect(result == nil)
    }

    @Test("build includes rename prompt when worktree not renamed")
    func buildIncludesRenameWhenNotRenamed() {
        let repo = Repo(path: "/test", displayName: "test", defaultBranch: "main")
        let wt = Worktree(repoID: repo.id, name: "gorgeous-panda", displayName: "gorgeous-panda",
                          branch: "tbd/gorgeous-panda", path: "/test/.tbd/worktrees/gorgeous-panda",
                          tmuxServer: "tbd-test")

        let result = SystemPromptBuilder.build(repo: repo, worktree: wt, isResume: false)
        #expect(result != nil)
        #expect(result!.contains("Rename the git branch"))
        #expect(result!.contains("git branch -m"))
        #expect(result!.contains("tbd worktree rename"))
    }

    @Test("build excludes rename prompt when worktree already renamed")
    func buildExcludesRenameWhenRenamed() {
        let repo = Repo(path: "/test", displayName: "test", defaultBranch: "main")
        let wt = Worktree(repoID: repo.id, name: "gorgeous-panda", displayName: "🔐 Auth Fix",
                          branch: "tbd/gorgeous-panda", path: "/test/.tbd/worktrees/gorgeous-panda",
                          tmuxServer: "tbd-test")

        let result = SystemPromptBuilder.build(repo: repo, worktree: wt, isResume: false)
        #expect(result != nil)
        #expect(!result!.contains("Rename the git branch"))
        #expect(result!.contains("TBD-managed worktree"))
    }

    @Test("build excludes rename prompt when explicitly disabled (empty string)")
    func buildExcludesRenameWhenDisabled() {
        let repo = Repo(path: "/test", displayName: "test", defaultBranch: "main",
                        renamePrompt: "")
        let wt = Worktree(repoID: repo.id, name: "gorgeous-panda", displayName: "gorgeous-panda",
                          branch: "tbd/gorgeous-panda", path: "/test/.tbd/worktrees/gorgeous-panda",
                          tmuxServer: "tbd-test")

        let result = SystemPromptBuilder.build(repo: repo, worktree: wt, isResume: false)
        #expect(result != nil)
        #expect(!result!.contains("Rename the git branch"))
        #expect(result!.contains("TBD-managed worktree"))
    }

    @Test("build uses custom rename prompt when set")
    func buildUsesCustomRenamePrompt() {
        let repo = Repo(path: "/test", displayName: "test", defaultBranch: "main",
                        renamePrompt: "Use cw/4/feat- prefix")
        let wt = Worktree(repoID: repo.id, name: "gorgeous-panda", displayName: "gorgeous-panda",
                          branch: "tbd/gorgeous-panda", path: "/test/.tbd/worktrees/gorgeous-panda",
                          tmuxServer: "tbd-test")

        let result = SystemPromptBuilder.build(repo: repo, worktree: wt, isResume: false)
        #expect(result != nil)
        #expect(result!.contains("cw/4/feat-"))
        #expect(!result!.contains("Rename the git branch"))
    }

    @Test("build always includes TBD context for fresh sessions")
    func buildAlwaysIncludesTBDContext() {
        let repo = Repo(path: "/test", displayName: "test", defaultBranch: "main")
        let wt = Worktree(repoID: repo.id, name: "test-wt", displayName: "🔐 Renamed",
                          branch: "tbd/test-wt", path: "/test/.tbd/worktrees/test-wt",
                          tmuxServer: "tbd-test")

        let result = SystemPromptBuilder.build(repo: repo, worktree: wt, isResume: false)
        #expect(result != nil)
        #expect(result!.contains("TBD-managed worktree"))
        #expect(result!.contains("`tbd` skill"))
    }

    @Test("build includes general instructions when set")
    func buildIncludesGeneralInstructions() {
        let repo = Repo(path: "/test", displayName: "test", defaultBranch: "main",
                        customInstructions: "Always use pytest. Never mock the DB.")
        let wt = Worktree(repoID: repo.id, name: "test-wt", displayName: "🔐 Renamed",
                          branch: "tbd/test-wt", path: "/test/.tbd/worktrees/test-wt",
                          tmuxServer: "tbd-test")

        let result = SystemPromptBuilder.build(repo: repo, worktree: wt, isResume: false)
        #expect(result != nil)
        #expect(result!.contains("Always use pytest"))
    }

    @Test("build excludes general instructions when empty/whitespace")
    func buildExcludesEmptyInstructions() {
        let repo = Repo(path: "/test", displayName: "test", defaultBranch: "main",
                        customInstructions: "   \n  ")
        let wt = Worktree(repoID: repo.id, name: "test-wt", displayName: "🔐 Renamed",
                          branch: "tbd/test-wt", path: "/test/.tbd/worktrees/test-wt",
                          tmuxServer: "tbd-test")

        let result = SystemPromptBuilder.build(repo: repo, worktree: wt, isResume: false)
        #expect(result != nil)
        #expect(!result!.contains("   \n  "))
        #expect(result!.contains("TBD-managed worktree"))
    }

    // MARK: - Slim context (skill pointer)

    @Test("builtInTBDContext names the tbd skill")
    func slimContextNamesSkill() {
        let ctx = SystemPromptBuilder.builtInTBDContext
        #expect(ctx.contains("`tbd` skill"))
    }

    @Test("builtInTBDContext references absolute fallback path")
    func slimContextReferencesFallbackPath() {
        let ctx = SystemPromptBuilder.builtInTBDContext
        #expect(ctx.contains("/Library/Application Support/TBD/skill/SKILL.md"))
    }

    @Test("builtInTBDContext is short (no longer a full CLI reference)")
    func slimContextIsShort() {
        // Generous upper bound — flag if anyone re-bloats this string.
        #expect(SystemPromptBuilder.builtInTBDContext.count < 600)
    }

    @Test("builtInTBDContext no longer enumerates every subcommand")
    func slimContextDoesNotEnumerateAllCommands() {
        let ctx = SystemPromptBuilder.builtInTBDContext
        #expect(!ctx.contains("tbd terminal send"))
        #expect(!ctx.contains("tbd terminal output"))
        #expect(!ctx.contains("--prompt-file"))
    }

    @Test("fresh session includes the slim pointer")
    func freshSessionIncludesSlimPointer() {
        let repo = Repo(path: "/test", displayName: "test", defaultBranch: "main")
        let wt = Worktree(repoID: repo.id, name: "test-wt", displayName: "🔐 Auth Fix",
                          branch: "tbd/test-wt", path: "/test/.tbd/worktrees/test-wt",
                          tmuxServer: "tbd-test")
        let prompt = SystemPromptBuilder.build(repo: repo, worktree: wt, isResume: false)
        #expect(prompt != nil)
        #expect(prompt?.contains("`tbd` skill") == true)
    }
}
