import Foundation
import TBDShared
import os

let claudeCloudLogger = Logger(subsystem: "com.tbd.daemon", category: "claudeCloud")

/// The compiled `claude-cloud` provider: a second production conformance of
/// `RemoteProviderInvoking`, selected by `ProviderDispatcher` at the
/// manager's single `runner` injection site.
///
/// **Why it is compiled.** How to talk to one vendor's session API is a
/// mechanism, not a theory: there is one API, and no project's convention
/// changes its shape. Mechanisms compile.
///
/// It synthesizes the same `ProviderResult` envelope a subprocess produces,
/// fabricated exit code included, so it passes through
/// `ProviderFailureClass.classify` and the same health, auth-banner and
/// staleness handling an external provider gets.
struct ClaudeCloudInvoker: RemoteProviderInvoking {
    let db: TBDDatabase
    let spawner: any ClaudeCloudSpawning
    /// The date seam: every timestamp here is persisted to or compared
    /// against the ledger, so it is data, never behavior.
    let now: @Sendable () -> Date

    init(db: TBDDatabase, spawner: any ClaudeCloudSpawning,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.db = db
        self.spawner = spawner
        self.now = now
    }

    func run(_ config: RemoteProviderConfig, verb: [String], stdin: Data?,
             timeout: TimeInterval, contractVersion: Int) async throws -> ProviderResult {
        switch verb.first {
        case "describe":
            return ProviderResult(exitCode: 0, stdout: ClaudeCloudDescribe.json, stderr: "")
        case "create":
            return try await create(stdin: stdin, timeout: timeout)
        case "list":
            return try await list()
        case "archive", "unarchive", "land":
            // Declared by `describe` and implemented by the archive and land
            // steps of this same delivery. Until then this fails loudly as a
            // contract bug rather than exiting 0 with nothing, which is the
            // failure a caller could not distinguish from success.
            return Self.notImplementedResult(verb: verb[0])
        default:
            let verbName = verb.first ?? ""
            claudeCloudLogger.debug(
                "claude-cloud received an undeclared verb: \(verbName, privacy: .public)")
            return Self.errorResult(
                exitCode: 2, code: "invalid_params",
                message: "claude-cloud does not implement the verb '\(verbName)'")
        }
    }

    /// One contract-shaped error envelope, so every verb's failure reaches
    /// `ProviderFailureClass.classify` exactly as a subprocess's would.
    static func errorResult(
        exitCode: Int32, code: String, message: String,
        remediation: (label: String, command: String?)? = nil
    ) -> ProviderResult {
        var object: [String: Any] = ["code": code, "message": message, "retryable": exitCode == 3]
        if let remediation {
            var r: [String: Any] = ["label": remediation.label]
            if let command = remediation.command { r["command"] = command }
            object["remediation"] = r
        }
        let payload: [String: Any] = ["error": object]
        let data = (try? JSONSerialization.data(withJSONObject: payload))
            ?? Data(#"{"error":{"code":"internal","message":"error envelope could not be encoded"}}"#.utf8)
        return ProviderResult(exitCode: exitCode, stdout: data, stderr: "")
    }

    static func notImplementedResult(verb: String) -> ProviderResult {
        errorResult(
            exitCode: 2, code: "not_implemented",
            message: "claude-cloud declares '\(verb)' but this build does not implement it yet")
    }
}
