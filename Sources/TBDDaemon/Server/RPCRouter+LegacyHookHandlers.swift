import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "legacy-hooks")

extension RPCRouter {

    /// Read-only scan of `~/.claude/settings.json` plus every registered
    /// repo's `<repo>/.claude/settings.json` for hook entries whose
    /// `command` field contains `tbd notify` or `tbd session-event`.
    /// Returns a structured list the app uses to decide whether to surface
    /// the migration prompt and to populate the dialog body.
    public func handleDaemonLegacyHooksStatus() async throws -> RPCResponse {
        let global = LegacyHookScanner.detectEntries(at: LegacyHookScanner.globalSettingsPath)
        var repoMap: [String: [LegacyHookEntry]] = [:]
        let repos = (try? await db.repos.list()) ?? []
        let candidatePaths = LegacyHookScanner.repoSettingsPaths(repoPaths: repos.map { $0.path })
        for path in candidatePaths {
            let entries = LegacyHookScanner.detectEntries(at: path)
            if !entries.isEmpty {
                repoMap[path] = entries
            }
        }
        return try RPCResponse(result: LegacyHooksStatusResult(
            globalEntries: global,
            repoEntries: repoMap
        ))
    }

    /// Mutating: remove every legacy global entry from
    /// `~/.claude/settings.json`. Atomic + backed-up + validated via
    /// `SettingsJSONSafety`. Repo-level files are NEVER touched.
    public func handleDaemonRemoveLegacyGlobalHooks() async throws -> RPCResponse {
        do {
            let result = try LegacyHookScanner.removeGlobalEntries()
            return try RPCResponse(result: result)
        } catch let e as SettingsJSONSafety.Error {
            logger.error("removeLegacyGlobalHooks safety error: \(String(describing: e), privacy: .public)")
            switch e {
            case .backupFailed(let m): return RPCResponse(error: "backup_failed: \(m)")
            case .roundtripFailed(let m): return RPCResponse(error: "roundtrip_failed: \(m)")
            case .writeFailed(let m): return RPCResponse(error: "write_failed: \(m)")
            case .invariantFailed(let m): return RPCResponse(error: "invariant_failed: \(m)")
            }
        } catch {
            logger.error("removeLegacyGlobalHooks unexpected: \(error.localizedDescription, privacy: .public)")
            return RPCResponse(error: "remove_failed: \(error.localizedDescription)")
        }
    }
}
