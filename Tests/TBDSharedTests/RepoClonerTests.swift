import Foundation
import os
import Testing
@testable import TBDShared

/// Tier 2: real `git` and `sh` children, ended by events — a cancel, a
/// signal, the child's own exit — never by a wall-clock deadline.
///
/// `RepoCloner` against real child processes: real `git clone` of a local
/// `file://` repository, and `sh -c` scripts through the command seam for the
/// paths git cannot be made to take on demand (a scripted failure, a long
/// clone to cancel). Serialized because `terminateAll()` signals every clone
/// running in this process, which would reach a neighbouring test's child.
@Suite("RepoCloner", .serialized)
struct RepoClonerTests {
    // MARK: - Short form

    @Test func shortFormFollowsGhSSH() async {
        let received = OSAllocatedUnfairLock(initialState: [[String]]())
        let url = await RepoCloner.githubCloneURL(owner: "acme", repo: "widgets") { arguments in
            received.withLock { $0.append(arguments) }
            return (exitCode: 0, stdout: "ssh\n")
        }
        #expect(url == "git@github.com:acme/widgets.git")
        let calls = received.withLock { $0 }
        #expect(calls == [["gh", "config", "get", "git_protocol", "-h", "github.com"]])
    }

    @Test func shortFormDefaultsToHTTPS() async {
        let replies: [(exitCode: Int32, stdout: String)?] = [
            (exitCode: 0, stdout: "https\n"),
            (exitCode: 0, stdout: ""),
            (exitCode: 1, stdout: "ssh"),
            nil,
        ]
        for reply in replies {
            let url = await RepoCloner.githubCloneURL(owner: "acme", repo: "widgets") { _ in reply }
            #expect(url == "https://github.com/acme/widgets.git", "reply: \(String(describing: reply))")
        }
    }

    // MARK: - Environment

    @Test func noPromptEnvironment() {
        let env = RepoCloner.environment(for: .noPrompt, inheriting: ["PATH": "/usr/bin"])
        #expect(env["GIT_TERMINAL_PROMPT"] == "0")
        let path = env["PATH"] ?? ""
        #expect(path.hasPrefix("/usr/bin"))
        #expect(path.split(separator: ":").contains("/opt/homebrew/bin"))
    }

    @Test func attachedEnvironmentLeavesPromptAlone() {
        let base = ["PATH": "/usr/bin"]
        let env = RepoCloner.environment(for: .attachedToTerminal, inheriting: base)
        #expect(env["GIT_TERMINAL_PROMPT"] == nil)
        let path = env["PATH"] ?? ""
        #expect(path.hasPrefix("/usr/bin"))
        #expect(path == RepoCloner.environment(for: .noPrompt, inheriting: base)["PATH"])
    }

    // MARK: - Real git

    /// Discriminates the cloner's own check: git clones into an empty
    /// directory without complaint.
    @Test func refusesExistingEmptyDestination() async throws {
        let root = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let bare = try Self.makeBareRepository(in: root)
        let dest = root.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)

        let cloner = RepoCloner(url: "file://\(bare.path)", destination: dest.path, mode: .noPrompt)
        let outcome = await cloner.run { _ in }

        #expect(outcome == .refusedDestinationExists)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dest.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dest.path).isEmpty)
    }

    @Test func clonesFromFileURL() async throws {
        let root = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let bare = try Self.makeBareRepository(in: root)
        let dest = root.appendingPathComponent("widgets")
        let progress = ProgressLog()

        let cloner = RepoCloner(url: "file://\(bare.path)", destination: dest.path, mode: .noPrompt)
        let outcome = await cloner.run { progress.append($0) }

        #expect(outcome == .succeeded)
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent(".git").path))
        #expect(!progress.lines.isEmpty)
    }

    @Test func missingURLFailsAndLeavesNoFolder() async throws {
        let root = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = root.appendingPathComponent("acme")

        let cloner = RepoCloner(url: "file:///nonexistent/acme.git", destination: dest.path, mode: .noPrompt)
        let outcome = await cloner.run { _ in }

        guard case .failed(let exitCode, let lastErrorLines) = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(exitCode == 128)
        #expect(!lastErrorLines.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    // MARK: - Command seam

    /// A failure that leaves the claimed folder empty, as a failed fetch
    /// does, removes it. Discriminates the cloner's own cleanup: the claim
    /// created the folder and the script never touches it, so without the
    /// cleanup the empty folder would stay.
    @Test func failureRemovesFolderItCreated() async throws {
        let root = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = root.appendingPathComponent("emptied")

        let cloner = RepoCloner(
            command: ["sh", "-c", "echo 'fatal: nope' >&2; exit 2"],
            destination: dest.path, mode: .noPrompt)
        let outcome = await cloner.run { _ in }

        #expect(outcome == .failed(exitCode: 2, lastErrorLines: ["fatal: nope"]))
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    /// git exits non-zero but keeps the repository it fetched when the
    /// checkout or a `post-checkout` hook fails, and tells the person to
    /// inspect it. A failure that leaves the claimed folder non-empty keeps the
    /// folder and what is in it. Discriminates `rmdir` from a removal of the
    /// whole tree, which would delete the kept repository.
    @Test func failureKeepsWhatGitKept() async throws {
        let root = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = root.appendingPathComponent("kept")
        let kept = dest.appendingPathComponent("README")

        let cloner = RepoCloner(
            command: ["sh", "-c",
                      "echo hello > \"$0/README\"; echo 'warning: Clone succeeded, but checkout failed.' >&2; exit 128",
                      dest.path],
            destination: dest.path, mode: .noPrompt)
        let outcome = await cloner.run { _ in }

        #expect(outcome == .failed(exitCode: 128,
                                   lastErrorLines: ["warning: Clone succeeded, but checkout failed."]))
        #expect(FileManager.default.fileExists(atPath: kept.path))
    }

    @Test func progressSplitsOnCarriageReturn() async throws {
        let root = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = root.appendingPathComponent("progress")
        let progress = ProgressLog()

        let cloner = RepoCloner(
            command: ["sh", "-c", "printf 'a\\rb\\nc' >&2"], destination: dest.path, mode: .noPrompt)
        let outcome = await cloner.run { progress.append($0) }

        #expect(outcome == .succeeded)
        #expect(progress.lines == ["a", "b", "c"])
    }

    /// `.cancelled` is itself the proof that the child was killed, with no
    /// wall-clock bound to flake under a loaded pass: a clone that exits 0
    /// reports `.succeeded` even after a cancel, so a `sleep 30` that cancel
    /// failed to stop would come back `.succeeded` thirty seconds later.
    ///
    /// The script leaves a file in the folder, as git does when signalled
    /// during checkout, so this discriminates a cancel's removal of the whole
    /// folder from the `rmdir` a plain failure gets.
    @Test func cancelKillsAndRemovesFolder() async throws {
        let root = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = root.appendingPathComponent("cancelled")

        let cloner = RepoCloner(
            command: ["sh", "-c", "echo partial > \"$0/partial\"; echo started >&2; exec sleep 30", dest.path],
            destination: dest.path, mode: .noPrompt)
        let outcome = await cloner.run { line in
            if line == "started" { cloner.cancel() }
        }

        #expect(outcome == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    /// Discriminates `POSIX_SPAWN_SETSID` both from its absence and from a
    /// bare `SETPGROUP`: the child must lead a session of its own, not only a
    /// process group. Checked in-process with `getsid`/`getpgid` while the
    /// child is alive.
    @Test func noPromptRunsInOwnSession() async throws {
        let root = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = root.appendingPathComponent("session")
        let probe = OSAllocatedUnfairLock<SessionProbe?>(initialState: nil)

        let cloner = RepoCloner(
            command: ["sh", "-c", "echo $$ >&2; exec sleep 30"],
            destination: dest.path, mode: .noPrompt)
        let outcome = await cloner.run { line in
            guard let pid = pid_t(line) else { return }
            let sample = SessionProbe(pid: pid, sessionID: getsid(pid), groupID: getpgid(pid))
            probe.withLock { $0 = sample }
            cloner.cancel()
        }

        #expect(outcome == .cancelled)
        let recorded = probe.withLock { $0 }
        let observed = try #require(recorded)
        #expect(observed.sessionID == observed.pid)
        #expect(observed.groupID == observed.pid)
    }

    /// The spec's empty stdin for `.noPrompt`: a read sees end of file at once.
    @Test func noPromptStdinIsEmpty() async throws {
        let root = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = root.appendingPathComponent("stdin")
        let progress = ProgressLog()

        let cloner = RepoCloner(
            command: ["sh", "-c", "if read x; then echo got >&2; else echo eof >&2; fi"],
            destination: dest.path, mode: .noPrompt)
        let outcome = await cloner.run { progress.append($0) }

        #expect(outcome == .succeeded)
        #expect(progress.lines == ["eof"])
    }

    /// The attached branch: git keeps the caller's stdout and stderr and
    /// nothing else. `extra` is open in this process without close-on-exec, so
    /// only `POSIX_SPAWN_CLOEXEC_DEFAULT` keeps it out of the child. The child
    /// answers by exit code — 3 as expected, 4 leaked, 5 stdio missing —
    /// because its stderr is the test runner's.
    @Test func attachedModeInheritsOnlyStdio() async throws {
        let root = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = root.appendingPathComponent("attached")
        let extra = open("/dev/null", O_RDONLY)
        try #require(extra > 2)
        defer { close(extra) }
        let progress = ProgressLog()

        let cloner = RepoCloner(
            command: ["sh", "-c",
                      "if [ -e \"/dev/fd/$0\" ]; then exit 4; fi; [ -e /dev/fd/1 ] && [ -e /dev/fd/2 ] && exit 3; exit 5",
                      String(extra)],
            destination: dest.path, mode: .attachedToTerminal)
        let outcome = await cloner.run { progress.append($0) }

        #expect(outcome == .failed(exitCode: 3, lastErrorLines: []))
        #expect(progress.lines.isEmpty)
    }

    /// Discriminates the atomic claim from a check followed by git's own
    /// `mkdir`: the child must find `destination` already created, parents
    /// included. The race the claim closes — another run creating the folder
    /// between a check and git's `mkdir` — has no deterministic trigger, so
    /// this pins the ordering that removes the window. The folder is this
    /// run's, so the failure removes it.
    @Test func claimsDestinationBeforeSpawning() async throws {
        let root = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = root.appendingPathComponent("missing/parents/claimed")

        let cloner = RepoCloner(
            command: ["sh", "-c", "if [ -d \"$0\" ]; then echo claimed >&2; fi; exit 3", dest.path],
            destination: dest.path, mode: .noPrompt)
        let outcome = await cloner.run { _ in }

        #expect(outcome == .failed(exitCode: 3, lastErrorLines: ["claimed"]))
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    /// A child killed by a signal reports the shell's `128 + signal` code.
    @Test func signalledChildReportsShellStyleCode() async throws {
        let root = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = root.appendingPathComponent("signalled")

        let cloner = RepoCloner(
            command: ["sh", "-c", "kill -TERM $$"], destination: dest.path, mode: .noPrompt)
        let outcome = await cloner.run { _ in }

        #expect(outcome == .failed(exitCode: 128 + SIGTERM, lastErrorLines: []))
    }

    /// Discriminates the live-clone registry: a clone `terminateAll()` did not
    /// know about would sleep its 30 seconds out and report `.succeeded`.
    /// `terminateAll()` is not a cancel, so the signal shows in the outcome.
    @Test func terminateAllStopsARunningClone() async throws {
        let root = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = root.appendingPathComponent("terminated")

        let cloner = RepoCloner(
            command: ["sh", "-c", "mkdir -p \"$0\"; echo started >&2; exec sleep 30", dest.path],
            destination: dest.path, mode: .noPrompt)
        let outcome = await cloner.run { line in
            if line == "started" { RepoCloner.terminateAll() }
        }

        #expect(outcome == .failed(exitCode: 128 + SIGTERM, lastErrorLines: ["started"]))
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    // MARK: - Helpers

    private struct SessionProbe {
        let pid: pid_t
        let sessionID: pid_t
        let groupID: pid_t
    }

    /// Collects progress lines from the cloner's reader thread.
    private final class ProgressLog: Sendable {
        private let storage = OSAllocatedUnfairLock(initialState: [String]())

        func append(_ line: String) { storage.withLock { $0.append(line) } }

        var lines: [String] { storage.withLock { $0 } }
    }

    private static func makeScratch() throws -> URL {
        let fenced = ProcessInfo.processInfo.environment["TBD_TEST_SCRATCH_ROOT"] ?? ""
        let base = fenced.isEmpty ? FileManager.default.temporaryDirectory.path : fenced
        let root = URL(fileURLWithPath: "\(base)/repo-cloner-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A repository with one commit, cloned bare to `<root>/acme.git`.
    private static func makeBareRepository(in root: URL) throws -> URL {
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try git(["init", "-q"], in: source)
        try Data("hello\n".utf8).write(to: source.appendingPathComponent("README"))
        try git(["add", "README"], in: source)
        try git(["commit", "-q", "-m", "init"], in: source)
        let bare = root.appendingPathComponent("acme.git")
        try git(["clone", "-q", "--bare", source.path, bare.path], in: root)
        return bare
    }

    private struct GitFailed: Error {
        let arguments: [String]
        let status: Int32
    }

    /// Synchronous on purpose: `run()` and `waitUntilExit()` share one thread.
    private static func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-c", "commit.gpgsign=false", "-c", "user.name=t",
                             "-c", "user.email=t@example.com"] + arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitFailed(arguments: arguments, status: process.terminationStatus)
        }
    }
}
