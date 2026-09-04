import Foundation
import Testing

@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 1. What `auto` mode decides before it spawns anything.
///
/// The decision is the testable half — which binary, which arguments, which
/// log, what `PATH` the script will see. Whether the child *survives* the
/// daemon that started it is a property of process groups and signals, not of
/// this code, and a unit test that claimed to prove it would be lying.
@Suite("UpdateLauncher")
struct UpdateLauncherTests {

    private static let worktree = "/Users/me/tbd/updates/src"

    @Test func planNamesTheScriptAndTheAutoFlag() {
        let plan = UpdateLauncher.plan(
            sourceWorktree: Self.worktree,
            environment: ["PATH": "/usr/bin:/bin", "TBD_HOME": "/Users/me/tbd"])
        #expect(plan.scriptPath == "/Users/me/tbd/updates/src/scripts/update.sh")
        #expect(plan.arguments == [plan.scriptPath, "--auto"])
    }

    /// `nohup`, not the script directly: the child must ignore `SIGHUP` so an
    /// update outlives the daemon it is replacing.
    @Test func planRunsTheScriptUnderNohup() {
        let plan = UpdateLauncher.plan(sourceWorktree: Self.worktree, environment: [:])
        #expect(plan.executablePath == "/usr/bin/nohup")
    }

    /// The log honors `TBD_HOME`, so a test or a second installation never
    /// appends to the developer's real `~/tbd/updates/update.log`.
    @Test func logPathFollowsTBDHome() {
        let plan = UpdateLauncher.plan(
            sourceWorktree: Self.worktree, environment: ["TBD_HOME": "/tmp/fenced"])
        #expect(plan.logPath == "/tmp/fenced/updates/update.log")
    }

    // MARK: - PATH repair

    /// The launcher-relaunched daemon inherits `/usr/bin:/bin:/usr/sbin:/sbin`
    /// — no Homebrew, so no modern git and no `swift`. An update that cannot
    /// build is worse than one that never started.
    @Test func aBarePathGainsTheFallbacks() {
        let repaired = UpdateLauncher.augmentedPath("/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(repaired == "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin")
    }

    /// Appended, not prepended, and never duplicated: a directory the operator
    /// put on `PATH` deliberately outranks our guess about Homebrew.
    @Test func anExistingFallbackIsNotDuplicatedAndOrderIsPreserved() {
        let repaired = UpdateLauncher.augmentedPath("/opt/homebrew/bin:/usr/bin")
        #expect(repaired == "/opt/homebrew/bin:/usr/bin:/usr/local/bin")
    }

    @Test func anAbsentPathBecomesTheFallbacksAlone() {
        #expect(UpdateLauncher.augmentedPath(nil) == "/opt/homebrew/bin:/usr/local/bin")
        #expect(UpdateLauncher.augmentedPath("") == "/opt/homebrew/bin:/usr/local/bin")
        // Empty segments from a trailing or doubled colon are dropped rather
        // than turned into a "current directory" entry.
        #expect(UpdateLauncher.augmentedPath("/usr/bin::")
            == "/usr/bin:/opt/homebrew/bin:/usr/local/bin")
    }

    @Test func theChildEnvironmentCarriesTheRepairedPathAndNothingElseChanged() {
        let plan = UpdateLauncher.plan(
            sourceWorktree: Self.worktree,
            environment: ["PATH": "/usr/bin", "SSH_AUTH_SOCK": "/tmp/agent", "HOME": "/Users/me"])
        #expect(plan.environment["PATH"] == "/usr/bin:/opt/homebrew/bin:/usr/local/bin")
        #expect(plan.environment["SSH_AUTH_SOCK"] == "/tmp/agent")
        #expect(plan.environment["HOME"] == "/Users/me")
    }

    // MARK: - Refusal

    /// A worktree with no `scripts/update.sh` — a build from a tree that
    /// predates the feature — must be reported, not spawned into.
    @Test func launchRefusesWhenTheScriptIsMissing() throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tbd-update-launcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let plan = UpdateLauncher.plan(
            sourceWorktree: temp.appendingPathComponent("src").path,
            environment: ["TBD_HOME": temp.path])
        #expect(UpdateLauncher.launch(plan) == false)
        #expect(
            FileManager.default.fileExists(atPath: plan.logPath) == false,
            "a refused launch must not create a log for an update that never ran")
    }

    @Test func scriptPathComposesFromTheWorktree() {
        #expect(UpdateLauncher.scriptPath(inSourceWorktree: "/a/b") == "/a/b/scripts/update.sh")
    }
}
