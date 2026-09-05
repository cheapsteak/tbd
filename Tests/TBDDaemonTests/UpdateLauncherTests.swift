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

    // MARK: - The inherited descriptor appends

    /// Reported when the child never produced the line the test was waiting
    /// for. Carries what the log actually held, per the assertion-hygiene rule
    /// that a timeout must report observed state — and as a thrown error, so
    /// the text survives into a CI summary.
    private struct LogLineNeverArrived: Error, CustomStringConvertible {
        let expected: String
        let observed: String
        let waited: Duration

        var description: String {
            """
            update log never contained "\(expected)" after polling up to \(waited); \
            observed: \(observed.isEmpty ? "<empty>" : observed.debugDescription)
            """
        }
    }

    /// Tier 2 — it spawns a real child and watches a real file.
    ///
    /// The property under test is the one a unit test on `plan(...)` cannot
    /// reach: the descriptor handed to the child must append, not write at an
    /// offset chosen when the child started. `scripts/update.sh` appends each
    /// of its own log lines through a separate open, so a child holding a
    /// frozen offset overwrites them — and it does so precisely when an
    /// unattended update has gone wrong and the log is the only witness.
    ///
    /// The child writes, pauses, and writes again; the test appends its own
    /// line into the pause. All three lines must survive, in order. The sleep
    /// is inside the child shell, not a `Task.sleep` standing in for
    /// synchronization: the test's own waits are bounded polls with deadlines.
    @Test func theChildAppendsRatherThanOverwritingLinesWrittenMeanwhile() async throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tbd-update-launcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        // A real script, run by a real shell: `launch` refuses a plan whose
        // script is not an executable file, and that guard is worth keeping
        // honest here rather than working around.
        // The child waits for a go-file between its two lines rather than
        // sleeping: the test's append has to land in that gap, and a loaded CI
        // runner can deschedule the test for longer than any sleep. The wait
        // is bounded so a child nobody releases still exits.
        let goFile = temp.appendingPathComponent("go")
        let script = temp.appendingPathComponent("emit-two-lines.sh")
        try """
            #!/bin/sh
            echo 'child-line-1'
            i=0
            while [ ! -e '\(goFile.path)' ] && [ "$i" -lt 3000 ]; do
                sleep 0.1
                i=$((i + 1))
            done
            echo 'child-line-2'
            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)

        let logPath = TBDConstants.updateLogPath(environment: ["TBD_HOME": temp.path])
        let plan = UpdateLaunchPlan(
            executablePath: "/bin/sh",
            arguments: [script.path],
            scriptPath: script.path,
            logPath: logPath,
            environment: ["PATH": "/usr/bin:/bin"])

        #expect(UpdateLauncher.launch(plan))

        // The child's first line is the signal that it is running and that its
        // descriptor is positioned where it will stay under the old behavior.
        try await waitForLog(logPath, toContain: "child-line-1")

        // Now the write the script's own `log()` stands for.
        let appender = try #require(FileHandle(forWritingAtPath: logPath))
        try appender.seekToEnd()
        try appender.write(contentsOf: Data("daemon-line\n".utf8))
        try appender.close()
        try Data().write(to: goFile)

        try await waitForLog(logPath, toContain: "child-line-2")

        let lines = try String(contentsOfFile: logPath, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        #expect(
            lines == ["child-line-1", "daemon-line", "child-line-2"],
            "every line must survive in order; a frozen offset overwrites the middle one")
    }

    /// Bounded poll with a deadline, per the tier-2 synchronization rule. The
    /// child is detached, so its exit is not awaitable here — the log is the
    /// observable, and it is the one under test anyway. The deadline is sized
    /// for a CI runner under load, where a child can wait tens of seconds to
    /// be scheduled at all; it is a ceiling, not a duration the test spends.
    private func waitForLog(
        _ path: String, toContain needle: String, within limit: Duration = .seconds(120)
    ) async throws {
        let deadline = ContinuousClock().now.advanced(by: limit)
        var observed = ""
        while ContinuousClock().now < deadline {
            observed = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            if observed.contains(needle) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw LogLineNeverArrived(expected: needle, observed: observed, waited: limit)
    }
}
