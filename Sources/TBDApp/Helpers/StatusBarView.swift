import SwiftUI
import TBDShared

struct StatusBarView: View {
    @EnvironmentObject var appState: AppState

    private var selectedWorktreeInfo: (path: String, repoID: UUID)? {
        guard appState.selectedWorktreeIDs.count == 1,
              let id = appState.selectedWorktreeIDs.first,
              let worktree = appState.worktrees.values.flatMap({ $0 }).first(where: { $0.id == id }),
              !worktree.path.isEmpty else { return nil }
        return (worktree.path, worktree.repoID)
    }

    /// Resolved once per process: the absolute path of the worktree that built
    /// this running TBDApp. Primary source is a sidecar file written into the
    /// bundle by `scripts/restart.sh`; falls back to parsing the exec path for
    /// the legacy in-place `.build/debug/TBD.app` launch shape.
    private static let sourceWorktreePath: String? = resolveSourceWorktreePath(
        bundleURL: Bundle.main.bundleURL,
        executablePath: Bundle.main.executablePath
    )

    /// Pure helper extracted so tests can exercise it without a real bundle.
    /// Tries the sidecar file first, then the exec-path heuristic.
    static func resolveSourceWorktreePath(
        bundleURL: URL,
        executablePath: String?,
        sidecarReader: (URL) -> String? = { try? String(contentsOf: $0, encoding: .utf8) }
    ) -> String? {
        let sidecarURL = bundleURL.appendingPathComponent("Contents/SourceWorktreePath.txt")
        if let raw = sidecarReader(sidecarURL) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let execPath = executablePath,
           let buildRange = execPath.range(of: "/.build/", options: .backwards) {
            return String(execPath[..<buildRange.lowerBound])
        }
        return nil
    }

    private var footerLabel: (text: String, tooltip: String?) {
        let version = "v\(TBDConstants.version)"
        guard let sourcePath = Self.sourceWorktreePath,
              let worktree = appState.worktrees.values.flatMap({ $0 }).first(where: { $0.path == sourcePath }) else {
            return (version, nil)
        }
        return (worktree.displayName, version)
    }

    /// Compute the left-side focus label for the status bar.
    ///
    /// - Single worktree selected: `"<repo name> / <worktree displayName>"`,
    ///   or just `<worktree displayName>` when the repo lookup fails.
    /// - Multiple worktrees selected: `"<N> worktrees"`.
    /// - Repo selected, no worktree: the repo's `displayName`.
    /// - Nothing selected: `nil` (renders nothing on the left side).
    nonisolated static func focusLabel(
        selectedWorktreeIDs: Set<UUID>,
        worktrees: [UUID: [Worktree]],
        repos: [Repo],
        selectedRepoID: UUID?
    ) -> String? {
        let count = selectedWorktreeIDs.count
        if count == 0 {
            guard let repoID = selectedRepoID,
                  let repo = repos.first(where: { $0.id == repoID }) else { return nil }
            return repo.displayName
        } else if count == 1, let id = selectedWorktreeIDs.first {
            let allWorktrees = worktrees.values.flatMap { $0 }
            guard let wt = allWorktrees.first(where: { $0.id == id }) else { return nil }
            if let repo = repos.first(where: { $0.id == wt.repoID }) {
                return "\(repo.displayName) / \(wt.displayName)"
            }
            return wt.displayName
        } else {
            return "\(count) worktrees"
        }
    }

    var body: some View {
        HStack {
            if let label = Self.focusLabel(
                selectedWorktreeIDs: appState.selectedWorktreeIDs,
                worktrees: appState.worktrees,
                repos: appState.repos,
                selectedRepoID: appState.selectedRepoID
            ) {
                Text(label)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let info = selectedWorktreeInfo {
                OpenInEditorButton(path: info.path, repoID: info.repoID)
            }
            let footer = footerLabel
            if let tooltip = footer.tooltip {
                Text(footer.text)
                    .foregroundStyle(.secondary)
                    .help(tooltip)
            } else {
                Text(footer.text)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(.bar)
    }
}
