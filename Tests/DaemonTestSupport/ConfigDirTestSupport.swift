import Foundation
@testable import TBDDaemonLib

/// A `ClaudeProfileConfigDirManager` rooted in fresh temp dirs, for every
/// `WorktreeLifecycle` / `RPCRouter` / `HibernationCoordinator` a test builds.
///
/// Two real directories are at stake and the default manager writes to both:
/// `~/tbd/profiles/<id>/` (created whenever a spawn resolves a non-bedrock
/// profile) and `~/.claude/` (the host store the profile dir mirrors, and the
/// ambient fallback the wake/revive transcript sync enumerates).
///
/// `tag` only shapes the temp dir name; make it something greppable so a
/// stray directory can be traced back to the suite that made it.
public func makeIsolatedConfigDirManager(tag: String) -> ClaudeProfileConfigDirManager {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("tbd-\(tag)-claude-\(UUID().uuidString)", isDirectory: true)
    return ClaudeProfileConfigDirManager(
        baseDirectory: home.appendingPathComponent("profiles", isDirectory: true),
        hostBaseDirectory: home.appendingPathComponent("claude-host", isDirectory: true)
    )
}
