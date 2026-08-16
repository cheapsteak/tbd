import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib
import TBDShared

/// Tier 2. The tee is a shell script whose whole contract is behavioral — what
/// it prints, what status it exits with, what lands on disk — so it is executed
/// for real against a temp directory rather than string-matched. Asserting on
/// the source text would prove only that the source text is what it is.
///
/// Nested under `TBDHomeSerialized`: the path-derivation and cleanup cases
/// mutate the process-global `TBD_HOME`.
extension TBDHomeSerialized {
@Suite struct StatuslineTeeTests {

    // MARK: - Harness

    /// One scratch directory with the tee script written into it, and a runner.
    private struct Fixture {
        let root: URL
        let scriptPath: String
        let capturePath: String

        /// - Parameters:
        ///   - body: the script to install. Defaults to the shipped one; the
        ///     fault-injection cases below pass a copy of it with exactly one
        ///     line replaced, so the code under test stays the real script.
        ///   - capture: where the tee should publish. Defaults to a file in
        ///     this fixture's own scratch directory.
        init(body: String = StatuslineTee.scriptBody, capture: String? = nil) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("tbd-tee-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            scriptPath = root.appendingPathComponent("statusline-tee.sh").path
            capturePath = capture ?? root.appendingPathComponent("capture.json").path
            try Data(body.utf8).write(to: URL(fileURLWithPath: scriptPath))
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }

        struct Run {
            let stdout: String
            let stderr: String
            let status: Int32
        }

        /// Run the tee with `payload` on stdin and `delegate` as its second
        /// argument, exactly as Claude Code would run the installed command.
        ///
        /// - Parameter shell: the interpreter. Defaults to `/bin/sh`, which is
        ///   what Claude Code invokes. The strict-POSIX case below passes
        ///   `/bin/dash` instead, because macOS `/bin/sh` is bash and bash is
        ///   lax about exactly the thing that branch is written to survive.
        ///   The `environment` overlay is merged over the inherited one; the
        ///   between-the-opens case below uses it to give the script a `TMPDIR`
        ///   it owns, so the buffer's directory can be taken away underneath it.
        func run(
            payload: String, delegate: String, capture: String? = nil,
            shell: String = "/bin/sh", environment: [String: String] = [:]
        ) throws -> Run {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = [scriptPath, capture ?? capturePath, delegate]
            if !environment.isEmpty {
                process.environment = ProcessInfo.processInfo.environment
                    .merging(environment) { _, new in new }
            }
            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            stdin.fileHandleForWriting.write(Data(payload.utf8))
            try stdin.fileHandleForWriting.close()
            let out = stdout.fileHandleForReading.readDataToEndOfFile()
            let err = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Run(
                stdout: String(decoding: out, as: UTF8.self),
                stderr: String(decoding: err, as: UTF8.self),
                status: process.terminationStatus
            )
        }

        func captureBytes(_ path: String? = nil) -> Data? {
            FileManager.default.contents(atPath: path ?? capturePath)
        }
    }

    // MARK: - The script's real behavior

    @Test func delegateStdoutPassesThroughAndCaptureHoldsExactStdin() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let payload = #"{"session_id":"abc","context_window":{"context_window_size":200000}}"#

        let run = try fixture.run(payload: payload, delegate: "echo STATUS-FROM-OPERATOR")

        #expect(run.stdout == "STATUS-FROM-OPERATOR\n")
        #expect(run.status == 0)
        #expect(fixture.captureBytes() == Data(payload.utf8))
    }

    @Test func delegateReceivesThePayloadOnItsOwnStdin() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let payload = #"{"model":{"display_name":"Opus"}}"#

        // `cat` proves the delegate got the bytes, not just that it ran.
        let run = try fixture.run(payload: payload, delegate: "cat")

        #expect(run.stdout == payload)
        #expect(run.status == 0)
    }

    @Test func noDelegateExitsZeroAndPrintsNothingButStillCaptures() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let payload = #"{"cwd":"/tmp/x"}"#

        let run = try fixture.run(payload: payload, delegate: "")

        // Printing anything here would claim a status-line slot nobody gave
        // TBD; exiting non-zero would blank one the operator may still own.
        #expect(run.stdout.isEmpty)
        #expect(run.status == 0)
        #expect(fixture.captureBytes() == Data(payload.utf8))
    }

    @Test func failingDelegatePropagatesItsStatusAndCaptureStillLands() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let payload = #"{"v":1}"#

        let run = try fixture.run(payload: payload, delegate: "exit 7")

        // Propagated, not swallowed: a broken operator statusline must fail
        // exactly as it would have without the tee in the path.
        #expect(run.status == 7)
        #expect(fixture.captureBytes() == Data(payload.utf8))
    }

    @Test func unwritableCapturePathStillRunsTheDelegateAndSaysNothing() throws {
        let fixture = try Fixture()
        defer {
            // Restore write permission first or the tree cannot be removed.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: fixture.root.appendingPathComponent("sealed").path)
            fixture.cleanUp()
        }
        let sealed = fixture.root.appendingPathComponent("sealed")
        try FileManager.default.createDirectory(at: sealed, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: sealed.path)
        let unwritable = sealed.appendingPathComponent("nested").appendingPathComponent("cap.json").path

        let run = try fixture.run(payload: #"{"v":2}"#, delegate: "echo STILL-RAN", capture: unwritable)

        #expect(run.stdout == "STILL-RAN\n")
        #expect(run.status == 0)
        // Quiet in this branch too: nothing on stderr either, and no temp file
        // left behind next to the path it could not write.
        #expect(run.stderr.isEmpty)
        #expect(fixture.captureBytes(unwritable) == nil)
    }

    @Test func payloadWithShellMetacharactersRoundTripsByteIdentical() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        // Every expansion trigger a repo path can carry: command substitution
        // in both spellings, a bare variable, quotes, a backslash, a newline.
        let payload = """
        {"cwd":"/Users/x/$(touch \(fixture.root.path)/PWNED)/`touch \
        \(fixture.root.path)/PWNED2`/${HOME}/it's \\"quoted\\"\\\\odd",
        "extra":"line two"}
        """

        let run = try fixture.run(payload: payload, delegate: "cat")

        #expect(fixture.captureBytes() == Data(payload.utf8))
        #expect(run.stdout == payload)
        // Nothing was expanded on the way through — the payload is data, and
        // the two witnesses a substitution would have created do not exist.
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("PWNED").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("PWNED2").path))
    }

    @Test func capturePublishesAtomicallyRatherThanInPlace() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        // A pre-existing capture is replaced wholesale, and no `.tmp` sibling
        // survives — the rename either happened or was cleaned up.
        try Data("STALE-AND-MUCH-LONGER-THAN-THE-NEW-ONE".utf8)
            .write(to: URL(fileURLWithPath: fixture.capturePath))

        _ = try fixture.run(payload: "{}", delegate: "")

        #expect(fixture.captureBytes() == Data("{}".utf8))
        let siblings = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        #expect(!siblings.contains { $0.hasSuffix(".tmp") })
    }

    // MARK: - Fault injection: the two branches a live run cannot be made to take

    /// A tee killed between writing its temp and renaming it must leave a file
    /// the startup sweep can collect, or `~/tbd/runtime` accumulates one orphan
    /// per interrupted statusline render, forever.
    ///
    /// The kill is injected by replacing exactly the publish line with `exit 0`
    /// — everything up to it, the temp's name included, is the shipped script.
    /// A real signal cannot be timed into that window deterministically.
    @Test func aTeeKilledBeforeThePublishLeavesOnlyASweepableTemp() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-tee-orphan-\(UUID().uuidString)")
        let prior = setTBDHome(tmp.path)
        defer {
            restoreTBDHome(prior)
            try? FileManager.default.removeItem(at: tmp)
        }
        let publish = #"mv -f "$TMP" "$CAPTURE" 2>/dev/null || rm -f "$TMP" 2>/dev/null"#
        #expect(StatuslineTee.scriptBody.contains(publish), "the publish line moved; re-derive this injection")
        let killed = StatuslineTee.scriptBody.replacingOccurrences(of: publish, with: "exit 0")
        let key = UUID().uuidString
        let fixture = try Fixture(body: killed, capture: StatuslineTee.capturePath(sessionKey: key))
        defer { fixture.cleanUp() }

        let run = try fixture.run(payload: #"{"context_window":{"context_window_size":200000}}"#, delegate: "")

        #expect(run.stderr.isEmpty)
        // Died before the rename, so nothing was published and the temp is the
        // only thing on disk — the state the sweep has to be able to reason about.
        #expect(fixture.captureBytes() == nil)
        let stranded = try FileManager.default.contentsOfDirectory(atPath: TBDConstants.runtimeDir.path)
        #expect(stranded.count == 1, "expected exactly the stranded temp, saw \(stranded)")

        StatuslineTee.pruneOrphanedCaptures(liveSessionKeys: [key])

        // The session is LIVE, so its capture would have survived; the temp is
        // collected anyway, which is the whole point of the name it carries.
        let remaining = try FileManager.default.contentsOfDirectory(atPath: TBDConstants.runtimeDir.path)
        #expect(remaining.isEmpty, "the startup sweep cannot collect the tee's temp: \(remaining)")
    }

    /// The buffer opens are the one redirection the script does not silence,
    /// and an `exec` whose redirection fails is reported by the shell and ends
    /// the script — which blanks the status line the whole file exists to
    /// protect. Injected by pointing the buffer at a directory that is not
    /// there, since a buffer `mktemp` just created cannot be made to fail.
    @Test func anUnopenableBufferStaysQuietAndStillRunsTheDelegate() throws {
        let mktemp = #"BUF=$(mktemp "${TMPDIR:-/tmp}/tbd-statusline-XXXXXX" 2>/dev/null) || BUF="#
        #expect(StatuslineTee.scriptBody.contains(mktemp), "the buffer line moved; re-derive this injection")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-tee-nobuf-\(UUID().uuidString)")
        let unopenable = StatuslineTee.scriptBody.replacingOccurrences(
            of: mktemp, with: "BUF=\(root.path)/absent/buffer")
        let fixture = try Fixture(body: unopenable)
        defer { fixture.cleanUp() }

        let run = try fixture.run(payload: #"{"v":9}"#, delegate: "echo STILL-RAN")

        // Same contract as every other failure branch: nothing said, nothing
        // blanked, and the operator's own statusline still runs on the payload.
        #expect(run.stderr.isEmpty)
        #expect(run.stdout == "STILL-RAN\n")
        #expect(run.status == 0)
        #expect(fixture.captureBytes() == nil)
    }

    /// The same branch again, under a **strict POSIX shell**, because that is
    /// the only place the guard is load-bearing and the only place it was false.
    ///
    /// `exec` is a POSIX special built-in, and a redirection error on a special
    /// built-in is fatal to a non-interactive shell regardless of what encloses
    /// it. `dash` therefore exits 2 the instant the buffer open fails: the
    /// `if !` never evaluates, the `2>/dev/null` never applies, the delegate
    /// never runs, and the operator's status line goes blank — the one outcome
    /// this whole file is written to prevent. bash and zsh are laxer, so the
    /// case above passes under macOS `/bin/sh` whether or not the script is
    /// correct, which is exactly why it could not catch this.
    ///
    /// The script's own header promises POSIX `sh` with no bashisms, so the
    /// claim is tested against one. `/bin/dash` is an Apple system binary
    /// (`com.apple.dash`); its absence is asserted rather than skipped, because
    /// a skip here would silently retire the only arm that proves the claim.
    @Test func everyBranchStaysQuietAndNonFatalUnderAStrictPOSIXShell() throws {
        let dash = "/bin/dash"
        #expect(FileManager.default.isExecutableFile(atPath: dash),
                "/bin/dash is gone; it is the only strict POSIX shell this suite runs the tee under — find another rather than dropping the case")

        // 1. The ordinary path still works there: three descriptors on one
        //    inode, an atomic publish, and the payload replayed to the delegate.
        let healthy = try Fixture()
        defer { healthy.cleanUp() }
        let payload = #"{"context_window":{"context_window_size":200000}}"#

        let good = try healthy.run(payload: payload, delegate: "cat", shell: dash)

        #expect(good.stdout == payload)
        #expect(good.stderr.isEmpty)
        #expect(good.status == 0)
        #expect(healthy.captureBytes() == Data(payload.utf8))

        // 2. And the unopenable-buffer branch is handled rather than fatal.
        //    Same injection as the case above — the buffer points somewhere
        //    that is not there — so the code under test is the shipped script.
        let mktemp = #"BUF=$(mktemp "${TMPDIR:-/tmp}/tbd-statusline-XXXXXX" 2>/dev/null) || BUF="#
        #expect(StatuslineTee.scriptBody.contains(mktemp), "the buffer line moved; re-derive this injection")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-tee-dash-\(UUID().uuidString)")
        let unopenable = StatuslineTee.scriptBody.replacingOccurrences(
            of: mktemp, with: "BUF=\(root.path)/absent/buffer")
        let broken = try Fixture(body: unopenable)
        defer { broken.cleanUp() }

        let run = try broken.run(payload: #"{"v":9}"#, delegate: "echo STILL-RAN", shell: dash)

        // Before the fix this arm reported status 2, empty stdout and an empty
        // capture: the shell died on the redirection and took the operator's
        // status line with it.
        #expect(run.stdout == "STILL-RAN\n", "the delegate never ran under \(dash)")
        #expect(run.status == 0, "the tee exited \(run.status) under \(dash) instead of deferring to the delegate")
        #expect(run.stderr.isEmpty, "the tee spoke up under \(dash): \(run.stderr)")
        #expect(broken.captureBytes() == nil)
    }

    /// The residual the probe cannot cover: the buffer's directory goes away
    /// **between** the probe and the real opens.
    ///
    /// The probe proves the path was openable a moment ago and nothing more.
    /// The buffer lives in `$TMPDIR`, a per-user directory a cleaner or a
    /// sibling process can empty at any moment, so the second open can still
    /// fail — and there the shell is already dying: `!`, `||` and `2>/dev/null`
    /// are all inert against a redirection error on a POSIX special built-in.
    /// Before the EXIT-trap fallback, `dash` exited 2 here having printed
    /// nothing, the delegate never ran, and the operator's status line blanked.
    ///
    /// Injected by inserting one `rm -rf "$TMPDIR"` immediately before the real
    /// opens, with `TMPDIR` pointed at a directory this fixture owns — so the
    /// script under test is the shipped one and the window is the real one.
    /// Run under both shells: `dash` is where the branch is load-bearing, and
    /// macOS `/bin/sh` is what Claude Code actually invokes.
    @Test(arguments: ["/bin/dash", "/bin/sh"])
    func aBufferThatVanishesBetweenTheProbeAndTheOpensStillRunsTheDelegate(shell: String) throws {
        #expect(FileManager.default.isExecutableFile(atPath: shell),
                "\(shell) is gone; it is one of the two shells this branch is proven under — find another rather than dropping the case")
        let realOpens = #"if ! { exec 3>"$BUF" 4<"$BUF" 5<"$BUF"; } 2>/dev/null; then"#
        #expect(StatuslineTee.scriptBody.contains(realOpens),
                "the buffer opens moved; re-derive this injection")
        let vanishing = StatuslineTee.scriptBody.replacingOccurrences(
            of: realOpens, with: "rm -rf \"$TMPDIR\"\n" + realOpens)
        let fixture = try Fixture(body: vanishing)
        defer { fixture.cleanUp() }
        let tmpdir = fixture.root.appendingPathComponent("buffers")
        try FileManager.default.createDirectory(at: tmpdir, withIntermediateDirectories: true)

        let run = try fixture.run(
            payload: #"{"v":11}"#, delegate: "echo STILL-RAN",
            shell: shell, environment: ["TMPDIR": tmpdir.path])

        // Same contract as every other failure branch: nothing said, nothing
        // blanked, and the operator's own statusline still runs on the payload.
        #expect(run.stdout == "STILL-RAN\n", "the delegate never ran under \(shell)")
        #expect(run.status == 0,
                "the tee exited \(run.status) under \(shell) instead of deferring to the delegate")
        #expect(run.stderr.isEmpty, "the tee spoke up under \(shell): \(run.stderr)")
        #expect(fixture.captureBytes() == nil)
        // The buffer's directory is gone, so nothing can have leaked into it,
        // and nothing leaked beside the capture either.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        #expect(!siblings.contains { $0.hasSuffix(".tmp.json") }, "left a temp behind: \(siblings)")
    }

    // MARK: - The daemon-side write

    /// One log line, one privacy decision. `path` is `.private`, and a
    /// Foundation file error routinely embeds that same filename and its
    /// containing folder — so a `.public` error beside it prints in the clear
    /// exactly what the interpolation next to it redacts.
    ///
    /// Asserted against the source text because a privacy annotation has no
    /// runtime surface a test can read back: `os.Logger` resolves it inside the
    /// logging system, and `OSLogMessage` exposes nothing about it. A source
    /// pin is a weak instrument in general; here it is the only one, and the
    /// property it pins is exact.
    @Test func theWriteFailureLogsThePathAndTheErrorAtTheSamePrivacy() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/TBDDaemonTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/TBDDaemon/Claude/StatuslineTee.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let line = try #require(
            text.split(separator: "\n").first { $0.contains("Failed to write statusline tee at") },
            "the write-failure log line moved; re-derive this check")

        #expect(line.contains("\\(path, privacy: .private)"))
        #expect(line.contains("\\(error.localizedDescription, privacy: .private)"),
                "the error is logged at a different privacy than the path it names: \(line)")
    }

    // MARK: - Installed command and on-disk paths

    @Test func writeScriptLandsExecutableUnderTBDHome() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-tee-write-\(UUID().uuidString)")
        let prior = setTBDHome(tmp.path)
        defer {
            restoreTBDHome(prior)
            try? FileManager.default.removeItem(at: tmp)
        }

        #expect(StatuslineTee.writeScript())

        let path = StatuslineTee.scriptPath
        #expect(path == tmp.appendingPathComponent("runtime/statusline-tee.sh").path)
        let mode = try #require(
            try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)
        #expect(mode.int16Value == 0o755)
    }

    @Test func statusLineCommandEscapesAllThreeArguments() {
        let command = StatuslineTee.statusLineCommand(
            capturePath: "/tmp/it's odd/cap.json",
            delegateCommand: "printf '%s' \"$(date)\""
        )
        // Single-quoted with the `'\''` escape, so a quote in a path or in the
        // operator's own command cannot break out into a new shell word.
        #expect(command.hasPrefix("sh '"))
        #expect(command.contains("/tmp/it'\\''s odd/cap.json'"))
        #expect(command.contains("'printf '\\''%s'\\'' \"$(date)\"'"))
    }

    @Test func statusLineCommandWithNoDelegatePassesAnEmptyArgument() {
        let command = StatuslineTee.statusLineCommand(capturePath: "/tmp/c.json", delegateCommand: nil)
        // The empty third argument is what the script's no-delegate branch
        // tests for — dropping it would shift argv and silently break both.
        #expect(command.hasSuffix(" ''"))
    }

    // MARK: - Cleanup

    @Test func captureIsRemovedWithThePerSessionOverlay() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-tee-clean-\(UUID().uuidString)")
        let prior = setTBDHome(tmp.path)
        defer {
            restoreTBDHome(prior)
            try? FileManager.default.removeItem(at: tmp)
        }
        let key = UUID().uuidString
        let overlay = ClaudeHookOverlay.resolveOverlayPath(
            fallbackModels: nil, sessionKey: key,
            watchDeskRole: .readOnlyCoordinator, worktreePath: nil)
        let capture = StatuslineTee.capturePath(sessionKey: key)
        try Data("{}".utf8).write(to: URL(fileURLWithPath: capture))
        #expect(FileManager.default.fileExists(atPath: capture))

        ClaudeHookOverlay.removePerSessionOverlay(sessionKey: key)

        #expect(!FileManager.default.fileExists(atPath: overlay))
        #expect(!FileManager.default.fileExists(atPath: capture))
    }

    @Test func orphanedCapturesArePrunedAndLiveOnesSurvive() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-tee-prune-\(UUID().uuidString)")
        let prior = setTBDHome(tmp.path)
        defer {
            restoreTBDHome(prior)
            try? FileManager.default.removeItem(at: tmp)
        }
        try FileManager.default.createDirectory(
            at: TBDConstants.runtimeDir, withIntermediateDirectories: true)
        let live = UUID().uuidString, orphan = UUID().uuidString
        for key in [live, orphan] {
            try Data("{}".utf8).write(
                to: URL(fileURLWithPath: StatuslineTee.capturePath(sessionKey: key)))
        }

        ClaudeHookOverlay.pruneOrphanedSessionOverlays(liveSessionKeys: [live])

        #expect(FileManager.default.fileExists(atPath: StatuslineTee.capturePath(sessionKey: live)))
        #expect(!FileManager.default.fileExists(atPath: StatuslineTee.capturePath(sessionKey: orphan)))
    }
}
}
