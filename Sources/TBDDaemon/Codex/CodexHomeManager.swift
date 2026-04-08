import Foundation
import TBDShared

/// Manages per-repo isolated `CODEX_HOME` directories under
/// `~/.tbd/agents/codex/<repoID>/`. This keeps TBD-launched codex sessions
/// from touching the user's real `~/.codex/` — so config, hooks, and
/// sessions stay scoped per repo and TBD never pollutes global codex state.
struct CodexHomeManager: Sendable {
    let baseDirectory: URL

    init(
        baseDirectory: URL = TBDConstants.configDir.appendingPathComponent("agents/codex", isDirectory: true)
    ) {
        self.baseDirectory = baseDirectory
    }

    func homeDirectory(forRepoID repoID: UUID) -> URL {
        baseDirectory.appendingPathComponent(repoID.uuidString.lowercased(), isDirectory: true)
    }

    @discardableResult
    func ensureHome(forRepoID repoID: UUID) throws -> URL {
        let home = homeDirectory(forRepoID: repoID)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }
}
