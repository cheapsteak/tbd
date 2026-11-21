import Foundation

/// A Codex executable and home for tests that open a Codex tab on a machine
/// with no Codex installed.
///
/// `WorktreeLifecycle`, `RPCRouter` and `HibernationCoordinator` resolve the
/// real Codex unless they are handed resolvers, and a test that reaches a
/// Codex launch passes these. Neither path exists. They suit a test whose
/// spawn goes through the holder spawn double, which starts no process, so
/// the paths only appear in the command it records.
public enum CodexLaunchTestStub {
    public static let executablePath = "/opt/tbd-test/bin/codex"
    public static let homePath = "/tmp/tbd-test-codex-home"

    public static let executableResolver: @Sendable () throws -> String = { CodexLaunchTestStub.executablePath }
    public static let homeEnsurer: @Sendable () throws -> URL = {
        URL(fileURLWithPath: CodexLaunchTestStub.homePath, isDirectory: true)
    }
}
