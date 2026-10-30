import Foundation
import Testing

@testable import TBDDaemonLib
@testable import TBDShared

/// The start-admission command runner, against real tiny scripts in a temp
/// directory (never `~/tbd`: the path resolves through an injected `TBD_HOME`).
@Suite("StartAdmissionGate")
struct StartAdmissionGateTests {

    private let request = StartAdmissionRequest(
        kind: .wake, agent: .claude, actorKind: "anonymous",
        worktreeID: UUID(), terminalID: UUID())

    /// A temp `TBD_HOME` with `hooks/start-admission` holding `script` and the
    /// given file mode, or nothing when `script` is nil.
    private func makeHome(script: String?, mode: Int = 0o755) throws -> [String: String] {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-start-admission-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("hooks"), withIntermediateDirectories: true)
        if let script {
            let file = home.appendingPathComponent("hooks/start-admission")
            try Data(script.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
        }
        return ProcessInfo.processInfo.environment.merging(["TBD_HOME": home.path]) { _, new in new }
    }

    private func gate(
        _ environment: [String: String], timeout: Duration = .seconds(10)
    ) -> StartAdmissionGate {
        StartAdmissionGate(environment: environment, timeout: timeout)
    }

    // MARK: - Actor table

    @Test(
        "every actor kind except app and daemon is checked",
        arguments: [
            (ActuationActor.Kind.app, false),
            (ActuationActor.Kind.daemon, false),
            (ActuationActor.Kind.session, true),
            (ActuationActor.Kind.anonymous, true),
            ("declared-by-a-newer-client", true),
        ])
    func actorRule(kind: String, checked: Bool) {
        #expect(StartAdmissionActorRule.isChecked(kind: kind) == checked)
        #expect(StartAdmissionActorRule.isChecked(ActuationActor(kind: kind)) == checked)
    }

    @Test func noDeclaredActorIsAnonymousAndChecked() {
        #expect(StartAdmissionActorRule.isChecked(nil))
    }

    // MARK: - Verdicts

    @Test func exitZeroAdmits() async throws {
        let environment = try makeHome(script: "#!/bin/sh\nexit 0\n")
        #expect(await gate(environment).evaluate(request) == .admit)
    }

    @Test func nonzeroExitHoldsWithTheFirstNonEmptyStdoutLine() async throws {
        let environment = try makeHome(script: """
            #!/bin/sh
            echo
            echo "camera in use"
            echo "second line is ignored"
            exit 1
            """)
        #expect(await gate(environment).evaluate(request) == .hold(reason: "camera in use"))
    }

    @Test func nonzeroExitWithNoOutputNamesTheStatus() async throws {
        let environment = try makeHome(script: "#!/bin/sh\nexit 3\n")
        #expect(await gate(environment).evaluate(request) == .hold(reason: "start-admission exited 3"))
    }

    @Test func aLongReasonIsCutToTwoHundredCharacters() async throws {
        let environment = try makeHome(script: "#!/bin/sh\nprintf '%0500d\\n' 0\nexit 1\n")
        guard case .hold(let reason) = await gate(environment).evaluate(request) else {
            Issue.record("expected a hold")
            return
        }
        #expect(reason.count == 200)
    }

    @Test func aSignalHoldsAndNamesIt() async throws {
        let environment = try makeHome(script: "#!/bin/sh\nkill -TERM $$\nsleep 5\n")
        #expect(await gate(environment).evaluate(request)
            == .hold(reason: "start-admission was killed by signal 15"))
    }

    @Test func noAnswerBeforeTheLimitHoldsAndNamesTheTimeout() async throws {
        let environment = try makeHome(script: "#!/bin/sh\nsleep 30\n")
        let verdict = await gate(environment, timeout: .milliseconds(300)).evaluate(request)
        #expect(verdict == .hold(reason: "start-admission did not answer within 300 ms"))
    }

    @Test func aFileThatCannotRunHolds() async throws {
        let environment = try makeHome(script: "#!/bin/sh\nexit 0\n", mode: 0o644)
        guard case .hold(let reason) = await gate(environment).evaluate(request) else {
            Issue.record("a non-executable command must hold, not admit")
            return
        }
        #expect(reason.hasPrefix("start-admission could not run:"))
    }

    @Test func aMissingFileAdmitsWithoutRunningAnything() async throws {
        let environment = try makeHome(script: nil)
        #expect(await gate(environment).evaluate(request) == .admit)
    }

    // MARK: - What the command sees

    @Test func theCommandSeesTheRequestInItsEnvironment() async throws {
        let capture = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-start-admission-env-\(UUID().uuidString)")
        let environment = try makeHome(script: """
            #!/bin/sh
            echo "$TBD_START_KIND $TBD_AGENT $TBD_ACTOR $TBD_WORKTREE_ID $TBD_TERMINAL_ID" > '\(capture.path)'
            exit 0
            """)
        #expect(await gate(environment).evaluate(request) == .admit)
        let seen = try String(contentsOf: capture, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(seen == "wake claude anonymous \(request.worktreeID.uuidString) \(request.terminalID!.uuidString)")
    }

    @Test func theTerminalVariableIsOmittedWhenTheStartNamesNone() async throws {
        let capture = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-start-admission-env-\(UUID().uuidString)")
        // A daemon started inside a TBD terminal carries its own TBD_TERMINAL_ID;
        // the command must not read that as the request's.
        var environment = try makeHome(script: """
            #!/bin/sh
            echo "[${TBD_TERMINAL_ID-unset}]" > '\(capture.path)'
            exit 0
            """)
        environment["TBD_TERMINAL_ID"] = UUID().uuidString
        var create = request
        create.kind = .create
        create.terminalID = nil
        #expect(await gate(environment).evaluate(create) == .admit)
        let seen = try String(contentsOf: capture, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(seen == "[unset]")
    }

    @Test func theHookPathHonorsTBDHome() {
        let path = TBDConstants.startAdmissionHookPath(environment: ["TBD_HOME": "/acme/tbd-home"])
        #expect(path == "/acme/tbd-home/hooks/start-admission")
    }
}
