import Testing
import Foundation
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("SystemPromptBuilder Tests")
struct SystemPromptBuilderTests {

    // MARK: - Shell Escaping

    @Test("shellEscape wraps text in single quotes")
    func shellEscapeSimple() {
        let result = shellEscape("hello world")
        #expect(result == "'hello world'")
    }

    @Test("shellEscape handles single quotes")
    func shellEscapeSingleQuotes() {
        let result = shellEscape("don't mock")
        #expect(result == "'don'\\''t mock'")
    }

    @Test("shellEscape handles double quotes")
    func shellEscapeDoubleQuotes() {
        let result = shellEscape("use \"pytest\"")
        #expect(result == "'use \"pytest\"'")
    }

    @Test("shellEscape handles newlines")
    func shellEscapeNewlines() {
        let result = shellEscape("line1\nline2")
        #expect(result == "'line1\nline2'")
    }

    @Test("shellEscape handles special shell characters")
    func shellEscapeSpecialChars() {
        let result = shellEscape("$HOME `cmd` $(eval)")
        #expect(result == "'$HOME `cmd` $(eval)'")
    }

    /// Text whose apostrophe a neighbouring scalar joins into one `Character`:
    /// a combining acute accent (U+0301), an emoji variation selector
    /// (U+FE0F) and a combining enclosing keycap (U+20E3) after it, and a
    /// prepended concatenation mark (U+0600) before it. Each continues with a
    /// command, so an apostrophe left unescaped ends the quoted word and the
    /// shell runs `echo injected`, which writes only to stdout.
    static let joinedApostrophes: [String] = [
        "x'\u{301}; echo injected; echo '",
        "y'\u{FE0F}; echo injected; echo '",
        "z'\u{20E3}; echo injected; echo '",
        "\u{600}'; echo injected; echo '",
        "a'\u{301}'\u{FE0F}'\u{20E3}b",
    ]

    @Test("shellEscape writes one '\\'' per apostrophe scalar, whatever mark follows it",
          arguments: joinedApostrophes)
    func shellEscapeEscapesEveryApostropheScalar(_ text: String) {
        let apostrophes = text.unicodeScalars.filter { $0 == "'" }.count
        let escaped = shellEscape(text)
        // Counted over scalars: a `String` search would compare composed
        // character sequences and miss an escape a mark follows.
        let escapes = Self.scalarOccurrences(of: #"'\''"#, in: escaped)
        #expect(escapes == apostrophes)
        // Two outer quotes, and three for each escaped apostrophe.
        let quotes = escaped.unicodeScalars.filter { $0 == "'" }.count
        #expect(quotes == 2 + 3 * apostrophes)
    }

    /// Tier 2: spawns `/bin/sh`, the shell the tmux transport runs a spawn
    /// command through. The output is compared as bytes, because `String`
    /// equality is canonical equivalence.
    @Test("shellEscape round-trips through /bin/sh whatever mark follows an apostrophe",
          .fastPassBounded, arguments: joinedApostrophes)
    func shellEscapeRoundTripsThroughTheShell(_ text: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf %s \(shellEscape(text))"]
        process.environment = ["PATH": "/usr/bin:/bin"]
        // An immediate end-of-file on stdin, and no cooperative-pool thread
        // parked on the child.
        let output = try await collectOutput(of: process, stdin: Data())
        #expect(output.status == 0)
        #expect(output.stdout == Data(text.utf8),
                "printed \(String(decoding: output.stdout, as: UTF8.self).debugDescription)")
    }

    /// How many times `needle`'s scalars occur in `haystack`'s, without overlap.
    private static func scalarOccurrences(of needle: String, in haystack: String) -> Int {
        let pattern = Array(needle.unicodeScalars)
        let scalars = Array(haystack.unicodeScalars)
        var count = 0
        var index = 0
        while index + pattern.count <= scalars.count {
            if scalars[index..<index + pattern.count].elementsEqual(pattern) {
                count += 1
                index += pattern.count
            } else {
                index += 1
            }
        }
        return count
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

    @Test("builtInTBDContext does not reference a fallback path")
    func slimContextDoesNotReferenceFallbackPath() {
        let ctx = SystemPromptBuilder.builtInTBDContext
        #expect(!ctx.contains("Application Support"))
        #expect(!ctx.contains("If unavailable"))
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

    // MARK: - Scratch layer

    @Test("build injects scratch layer and no repo/rename layer for scratch worktree")
    func buildScratchLayer() {
        let wt = Worktree(repoID: nil, name: "20260702-worrying-pike", displayName: "20260702-worrying-pike",
                          branch: "", path: "/tmp/scratch/x", tmuxServer: "tbd-scratch")
        let result = SystemPromptBuilder.build(repo: nil, worktree: wt, isResume: false)
        #expect(result != nil)
        #expect(result!.contains("scratch space"))
        #expect(result!.contains("tbd scratch promote"))
        #expect(!result!.contains("Rename the git branch"))
    }

    @Test("scratch layer absent for a normal repo worktree")
    func buildNoScratchLayerForRepoWorktree() {
        let repo = Repo(path: "/test", displayName: "test", defaultBranch: "main")
        let wt = Worktree(repoID: repo.id, name: "gorgeous-panda", displayName: "gorgeous-panda",
                          branch: "tbd/gorgeous-panda", path: "/test/.tbd/worktrees/gorgeous-panda", tmuxServer: "tbd-test")
        let result = SystemPromptBuilder.build(repo: repo, worktree: wt, isResume: false)
        #expect(result != nil)
        #expect(!result!.contains("tbd scratch promote"))
    }

    @Test("build uses custom scratchInstructions for a scratch worktree")
    func buildUsesCustomScratchInstructions() {
        let wt = Worktree(repoID: nil, name: "20260702-worrying-pike", displayName: "20260702-worrying-pike",
                          branch: "", path: "/tmp/scratch/x", tmuxServer: "tbd-scratch")
        let result = SystemPromptBuilder.build(
            repo: nil, worktree: wt, isResume: false,
            scratchInstructions: "Always use uv for scratch spaces.")
        #expect(result != nil)
        #expect(result!.contains("Always use uv for scratch spaces."))
        #expect(!result!.contains("tbd scratch promote"))
    }

    @Test("build falls back to built-in default when scratchInstructions is nil")
    func buildFallsBackToDefaultScratchInstructionsWhenNil() {
        let wt = Worktree(repoID: nil, name: "20260702-worrying-pike", displayName: "20260702-worrying-pike",
                          branch: "", path: "/tmp/scratch/x", tmuxServer: "tbd-scratch")
        let result = SystemPromptBuilder.build(repo: nil, worktree: wt, isResume: false, scratchInstructions: nil)
        #expect(result != nil)
        #expect(result!.contains("scratch space"))
        #expect(result!.contains("tbd scratch promote"))
    }

    @Test("build falls back to built-in default when scratchInstructions is whitespace-only")
    func buildFallsBackToDefaultScratchInstructionsWhenWhitespace() {
        let wt = Worktree(repoID: nil, name: "20260702-worrying-pike", displayName: "20260702-worrying-pike",
                          branch: "", path: "/tmp/scratch/x", tmuxServer: "tbd-scratch")
        let result = SystemPromptBuilder.build(repo: nil, worktree: wt, isResume: false, scratchInstructions: "   ")
        #expect(result != nil)
        #expect(result!.contains("scratch space"))
        #expect(result!.contains("tbd scratch promote"))
    }

    @Test("scratchInstructions param is ignored for a non-scratch worktree")
    func buildIgnoresScratchInstructionsForRepoWorktree() {
        let repo = Repo(path: "/test", displayName: "test", defaultBranch: "main")
        let wt = Worktree(repoID: repo.id, name: "gorgeous-panda", displayName: "gorgeous-panda",
                          branch: "tbd/gorgeous-panda", path: "/test/.tbd/worktrees/gorgeous-panda", tmuxServer: "tbd-test")
        let result = SystemPromptBuilder.build(
            repo: repo, worktree: wt, isResume: false,
            scratchInstructions: "Always use uv for scratch spaces.")
        #expect(result != nil)
        #expect(!result!.contains("Always use uv for scratch spaces."))
    }

    // MARK: - Scratch rename-nudge layer

    @Test("build includes default scratch rename prompt for a still-default scratch worktree")
    func buildIncludesDefaultScratchRenamePromptWhenNotRenamed() {
        let wt = Worktree(repoID: nil, name: "20260702-worrying-pike", displayName: "20260702-worrying-pike",
                          branch: "", path: "/tmp/scratch/x", tmuxServer: "tbd-scratch")
        let result = SystemPromptBuilder.build(repo: nil, worktree: wt, isResume: false)
        #expect(result != nil)
        #expect(result!.contains("tbd worktree rename"))
        #expect(!result!.contains("Rename the git branch"))
    }

    @Test("build excludes scratch rename prompt once the scratch space has been renamed")
    func buildExcludesScratchRenamePromptWhenRenamed() {
        let wt = Worktree(repoID: nil, name: "20260702-worrying-pike", displayName: "🐛 Login Timeout Debug",
                          branch: "", path: "/tmp/scratch/x", tmuxServer: "tbd-scratch")
        let result = SystemPromptBuilder.build(repo: nil, worktree: wt, isResume: false)
        #expect(result != nil)
        #expect(!result!.contains("tbd worktree rename"))
    }

    @Test("build uses custom scratchRenamePrompt for a still-default scratch worktree")
    func buildUsesCustomScratchRenamePrompt() {
        let wt = Worktree(repoID: nil, name: "20260702-worrying-pike", displayName: "20260702-worrying-pike",
                          branch: "", path: "/tmp/scratch/x", tmuxServer: "tbd-scratch")
        let result = SystemPromptBuilder.build(
            repo: nil, worktree: wt, isResume: false,
            scratchRenamePrompt: "Name this scratch space something fun.")
        #expect(result != nil)
        #expect(result!.contains("Name this scratch space something fun."))
        #expect(!result!.contains("tbd worktree rename"))
    }

    @Test("build falls back to default scratch rename prompt when scratchRenamePrompt is whitespace-only")
    func buildFallsBackToDefaultScratchRenamePromptWhenWhitespace() {
        let wt = Worktree(repoID: nil, name: "20260702-worrying-pike", displayName: "20260702-worrying-pike",
                          branch: "", path: "/tmp/scratch/x", tmuxServer: "tbd-scratch")
        let result = SystemPromptBuilder.build(
            repo: nil, worktree: wt, isResume: false,
            scratchRenamePrompt: "   ")
        #expect(result != nil)
        #expect(result!.contains("tbd worktree rename"))
    }

    @Test("scratchRenamePrompt param is ignored for a non-scratch worktree")
    func buildIgnoresScratchRenamePromptForRepoWorktree() {
        let repo = Repo(path: "/test", displayName: "test", defaultBranch: "main")
        let wt = Worktree(repoID: repo.id, name: "gorgeous-panda", displayName: "gorgeous-panda",
                          branch: "tbd/gorgeous-panda", path: "/test/.tbd/worktrees/gorgeous-panda", tmuxServer: "tbd-test")
        let result = SystemPromptBuilder.build(
            repo: repo, worktree: wt, isResume: false,
            scratchRenamePrompt: "Name this scratch space something fun.")
        #expect(result != nil)
        #expect(!result!.contains("Name this scratch space something fun."))
        // Non-scratch rename gating still applies (worktree not renamed yet).
        #expect(result!.contains("Rename the git branch"))
    }
}
