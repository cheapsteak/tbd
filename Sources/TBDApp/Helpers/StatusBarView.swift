import AppKit
import SwiftUI
import TBDShared

struct StatusBarView: View {
    @EnvironmentObject var appState: AppState

    /// Transient "Copied" feedback shown after the left label copies a path.
    @State private var didCopy = false

    /// Path + repo of the resolved single-selected worktree (nil when it has
    /// no path yet). The caller resolves the selection once per body
    /// evaluation and passes it in, so this never re-runs `findWorktree`.
    private static func selectedWorktreeInfo(_ worktree: Worktree?) -> (path: String, repoID: UUID?)? {
        guard let worktree, !worktree.path.isEmpty else { return nil }
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
    ///   or just `<worktree displayName>` when the repo lookup fails (or the
    ///   worktree is a repo-less scratch space). The caller pre-resolves the
    ///   selection via `AppState.findWorktree(id:)` — the scratch-aware
    ///   lookup — and passes it as `selectedWorktree` (same seam
    ///   `selectedWorktreeInfo` uses); `nil` means the lookup failed.
    /// - Multiple worktrees selected: `"<N> worktrees"`.
    /// - Repo selected, no worktree: the repo's `displayName`.
    /// - Nothing selected: `nil` (renders nothing on the left side).
    nonisolated static func focusLabel(
        selectedWorktreeIDs: Set<UUID>,
        selectedWorktree: Worktree?,
        repos: [Repo],
        selectedRepoID: UUID?
    ) -> String? {
        let count = selectedWorktreeIDs.count
        if count == 0 {
            guard let repoID = selectedRepoID,
                  let repo = repos.first(where: { $0.id == repoID }) else { return nil }
            return repo.displayName
        } else if count == 1 {
            guard let wt = selectedWorktree else { return nil }
            if let repo = repos.first(where: { $0.id == wt.repoID }) {
                return "\(repo.displayName) / \(wt.displayName)"
            }
            return wt.displayName
        } else {
            return "\(count) worktrees"
        }
    }

    /// What the left-side status-bar label does when clicked, and the tooltip it
    /// shows on hover.
    ///
    /// - A single worktree selected (non-nil path): clicking copies the absolute
    ///   path; the tooltip is that path.
    /// - Otherwise (repo-only or multi-worktree selection): clicking reveals the
    ///   selection in the sidebar; the tooltip is `"Reveal in sidebar"`.
    enum LeftLabelBehavior: Equatable {
        case copyPath(String)
        case revealInSidebar

        var tooltip: String {
            switch self {
            case .copyPath(let path): return path
            case .revealInSidebar: return "Reveal in sidebar"
            }
        }
    }

    /// Decide the left-label behavior from the selected worktree's path
    /// (`nil` when there is no single selected worktree).
    nonisolated static func leftLabelBehavior(selectedWorktreePath: String?) -> LeftLabelBehavior {
        if let path = selectedWorktreePath {
            return .copyPath(path)
        }
        return .revealInSidebar
    }

    var body: some View {
        // Resolve the single-selected worktree ONCE per body evaluation —
        // focusLabel and both selectedWorktreeInfo consumers share it, instead
        // of each re-running findWorktree per render.
        let selected = appState.selectedWorktreeIDs.count == 1
            ? appState.selectedWorktreeIDs.first.flatMap { appState.findWorktree(id: $0) }
            : nil
        let selectedInfo = Self.selectedWorktreeInfo(selected)
        HStack {
            if let label = Self.focusLabel(
                selectedWorktreeIDs: appState.selectedWorktreeIDs,
                selectedWorktree: selected,
                repos: appState.repos,
                selectedRepoID: appState.selectedRepoID
            ) {
                let behavior = Self.leftLabelBehavior(selectedWorktreePath: selectedInfo?.path)
                switch behavior {
                case .copyPath(let path):
                    Button(action: { copyPath(path) }) {
                        Text(didCopy ? "Copied" : label)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(behavior.tooltip)
                case .revealInSidebar:
                    Button(action: { appState.revealSelectionInSidebar() }) {
                        Text(label)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(behavior.tooltip)
                }
            }
            Spacer()
            if let info = selectedInfo {
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

    private func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        didCopy = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            didCopy = false
        }
    }
}
