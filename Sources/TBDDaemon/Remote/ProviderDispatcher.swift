import Foundation
import TBDShared

/// Routes one provider invocation to whichever conformance serves that
/// provider: a reserved name to an in-process built-in, everything else to
/// the subprocess runner.
///
/// The selection lands at `RemoteProviderManager`'s single `runner` injection
/// site rather than at each call, and three properties make that the right
/// seam:
///
/// - **One place decides.** The manager holds a dispatcher instead of a
///   runner and is otherwise unchanged, so no verb path grows an "is this the
///   built-in one" branch that a later verb could forget.
/// - **The built-in provider is put through the same machinery.** It
///   synthesizes the same `ProviderResult` envelope a subprocess produces,
///   fabricated exit code included, so it passes through
///   `ProviderFailureClass.classify` and the same health, auth-banner and
///   staleness handling an external provider gets.
/// - **The test seam is unchanged.** `FakeProviderInvoker` conforms to the
///   same protocol and stands in for either arm, so cloud behavior is
///   testable with no network and no credential store.
struct ProviderDispatcher: RemoteProviderInvoking {
    /// `ProviderRunner` in production.
    let subprocess: any RemoteProviderInvoking
    /// Keyed by provider name. Empty when no built-in is enabled at boot, in
    /// which case every name falls through to `subprocess`.
    let builtIns: [String: any RemoteProviderInvoking]

    func run(_ config: RemoteProviderConfig, verb: [String], stdin: Data?,
             timeout: TimeInterval, contractVersion: Int) async throws -> ProviderResult {
        let target = builtIns[config.name] ?? subprocess
        return try await target.run(
            config, verb: verb, stdin: stdin, timeout: timeout,
            contractVersion: contractVersion)
    }
}
