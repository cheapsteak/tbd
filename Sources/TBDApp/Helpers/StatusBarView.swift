import AppKit
import SwiftUI
import TBDShared

struct StatusBarView: View {
    @EnvironmentObject var appState: AppState

    // Task 7: both helpers below take a `LocalWorktree?`, which retires the
    // hand-written empty-path guards.
    /// Path + repo of the resolved single-selected worktree (nil when it has
    /// no path yet). The caller resolves the selection once per body
    /// evaluation and passes it in, so this never re-runs `findWorktree`.
    private static func selectedWorktreeInfo(_ worktree: Worktree?) -> (path: String, repoID: UUID?)? {
        guard let worktree, !worktree.localPath.isEmpty else { return nil }
        return (worktree.localPath, worktree.repoID)
    }

    /// The bottom-left cluster: where the selected worktree lives on disk and
    /// which branch it is on. `displayPath` is tilde-abbreviated for display
    /// only — `path` is the full value that lands on the pasteboard.
    struct LocationLabel: Equatable {
        let path: String
        let displayPath: String
        /// nil when the worktree has no branch (scratch spaces).
        let branch: String?
    }

    /// Pure helper so tests can exercise the formatting without a view.
    /// `home` is injected for the same reason.
    static func locationLabel(
        _ worktree: Worktree?,
        home: String = NSHomeDirectory()
    ) -> LocationLabel? {
        guard let worktree, !worktree.localPath.isEmpty else { return nil }
        let branch = worktree.branch.trimmingCharacters(in: .whitespacesAndNewlines)
        return LocationLabel(
            path: worktree.localPath,
            displayPath: abbreviateWithTilde(worktree.localPath, home: home),
            branch: branch.isEmpty ? nil : branch
        )
    }

    /// Tilde-abbreviates `path` against `home`, matching only whole path
    /// components so a sibling directory like `/Users/meadow` under a home of
    /// `/Users/me` is left alone.
    static func abbreviateWithTilde(_ path: String, home: String) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
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
    /// Delegates to SourceWorktreePathResolver for the actual resolution logic.
    static func resolveSourceWorktreePath(
        bundleURL: URL,
        executablePath: String?,
        sidecarReader: (URL) -> String? = { try? String(contentsOf: $0, encoding: .utf8) }
    ) -> String? {
        SourceWorktreePathResolver.resolve(
            bundleURL: bundleURL,
            executablePath: executablePath,
            sidecarReader: sidecarReader
        )
    }

    private var footerLabel: (text: String, tooltip: String?) {
        let version = "v\(TBDConstants.version)"
        guard let sourcePath = Self.sourceWorktreePath,
              let worktree = appState.worktrees.values.flatMap({ $0 }).first(where: { $0.localPath == sourcePath }) else {
            return (version, nil)
        }
        return (worktree.displayName, version)
    }

    var body: some View {
        // Resolve the single-selected worktree ONCE per body evaluation —
        // selectedWorktreeInfo (the editor button) uses it, instead of
        // re-running findWorktree per render.
        let selected = appState.selectedWorktreeIDs.count == 1
            ? appState.selectedWorktreeIDs.first.flatMap { appState.findWorktree(id: $0) }
            : nil
        let selectedInfo = Self.selectedWorktreeInfo(selected)
        HStack {
            if let location = Self.locationLabel(selected) {
                HStack(spacing: 8) {
                    CopyableStatusText(
                        text: location.displayPath,
                        copyValue: location.path,
                        truncation: .head,
                        tooltip: "Click to copy \(location.path)",
                        confirmation: "Copied path"
                    )
                    if let branch = location.branch {
                        // The branch glyph doubles as the separator from the
                        // path, so no interpunct is needed between them.
                        CopyableStatusText(
                            icon: GitBranchIcon(),
                            text: branch,
                            copyValue: branch,
                            truncation: .tail,
                            tooltip: "Click to copy branch \(branch)",
                            confirmation: "Copied branch"
                        )
                    }
                }
                // Yields to the version/display-name label on the right, which
                // is short and must never truncate.
                .layoutPriority(-1)
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
}

/// A deliberately chrome-less status-bar label that copies `copyValue` on
/// click. It carries no button styling — the hover underline plus pointing-hand
/// cursor are the whole affordance, and the toast is what confirms the copy
/// landed (the label itself is too small to flash a "Copied" state legibly).
private struct CopyableStatusText: View {
    @EnvironmentObject var appState: AppState

    /// Optional leading glyph naming what the value is. Part of the same click
    /// target and hover affordance as the text.
    var icon: GitBranchIcon?
    let text: String
    let copyValue: String
    let truncation: Text.TruncationMode
    let tooltip: String
    let confirmation: String

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 3) {
            if let icon {
                // Sized to the caption text this bar is set in; the glyph's
                // own grid has generous padding, so it optically matches.
                icon.frame(width: 11, height: 11)
            }
            Text(text)
                .lineLimit(1)
                .truncationMode(truncation)
                .underline(isHovering)
        }
            .foregroundStyle(.secondary)
            // Makes the icon and the gap beside it part of the click target,
            // not just the glyphs.
            .contentShape(Rectangle())
            .help(tooltip)
            .onHover { hovering in
                guard hovering != isHovering else { return }
                isHovering = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onDisappear {
                // Selection changes can tear the label down mid-hover, and an
                // unmatched push leaves the pointing hand stuck app-wide.
                if isHovering {
                    isHovering = false
                    NSCursor.pop()
                }
            }
            .onTapGesture {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(copyValue, forType: .string)
                appState.showTransientToast(confirmation, style: .success)
            }
            .accessibilityElement()
            .accessibilityLabel(text)
            .accessibilityHint(tooltip)
            .accessibilityAddTraits(.isButton)
    }
}
