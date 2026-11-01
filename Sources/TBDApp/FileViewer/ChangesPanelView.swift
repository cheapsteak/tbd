import AppKit
import SwiftUI
import TBDShared

private func copyPathToPasteboard(_ path: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(path, forType: .string)
}

private func absolutePath(worktreePath: String, relativePath: String) -> String {
    URL(fileURLWithPath: worktreePath).appendingPathComponent(relativePath).path
}

// MARK: - Data Model

struct GitFileStatus: Identifiable {
    let id = UUID()
    let path: String
    let indexStatus: Character   // X: staged status
    let workingStatus: Character // Y: working tree status

    var displayName: String { URL(fileURLWithPath: path).lastPathComponent }

    var isStaged: Bool { indexStatus != " " && indexStatus != "?" }
    var isUntracked: Bool { workingStatus == "?" }
    var isUnstaged: Bool { !isUntracked && workingStatus != " " }
}

private func statusColor(for char: Character) -> Color {
    switch char {
    case "M": return .yellow
    case "A": return .green
    case "D": return .red
    case "R", "C": return .blue
    default: return .gray
    }
}

// MARK: - Git Status Loader

func loadGitStatus(at path: String) async -> [GitFileStatus] {
    guard !path.isEmpty else { return [] }
    return await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", path, "status", "--porcelain=v1", "-u"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
                // Read while the process runs to drain the pipe — prevents deadlock
                // when stdout exceeds the kernel buffer (~64KB) on large worktrees.
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: parseGitStatus(output))
            } catch {
                continuation.resume(returning: [])
            }
        }
    }
}

private func parseGitStatus(_ output: String) -> [GitFileStatus] {
    output.components(separatedBy: "\n").compactMap { line in
        guard line.count >= 4 else { return nil }
        let index = line.startIndex
        let indexStatus = line[index]
        let workingStatus = line[line.index(index, offsetBy: 1)]
        var path = String(line.dropFirst(3))
        if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }
        guard !path.isEmpty else { return nil }
        return GitFileStatus(path: path, indexStatus: indexStatus, workingStatus: workingStatus)
    }
}

// MARK: - Branch Diff Loader

struct BranchFileChange: Identifiable {
    let id = UUID()
    let path: String
    let status: Character // A, M, D, R, C

    var displayName: String { URL(fileURLWithPath: path).lastPathComponent }
}

func loadBranchDiff(at worktreePath: String, defaultBranch: String) async -> [BranchFileChange] {
    guard !worktreePath.isEmpty else { return [] }
    return await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            // Get merge-base between HEAD and origin's default branch.
            // Use origin/<branch> since the local branch may be stale.
            let mergeBaseProc = Process()
            mergeBaseProc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            mergeBaseProc.arguments = ["-C", worktreePath, "merge-base", "HEAD", "origin/\(defaultBranch)"]
            let mergeBasePipe = Pipe()
            mergeBaseProc.standardOutput = mergeBasePipe
            mergeBaseProc.standardError = Pipe()
            do {
                try mergeBaseProc.run()
                let data = mergeBasePipe.fileHandleForReading.readDataToEndOfFile()
                mergeBaseProc.waitUntilExit()
                let mergeBase = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !mergeBase.isEmpty, mergeBaseProc.terminationStatus == 0 else {
                    continuation.resume(returning: [])
                    return
                }

                // Get diff from merge-base to HEAD
                let diffProc = Process()
                diffProc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                diffProc.arguments = ["-C", worktreePath, "diff", "--name-status", mergeBase, "HEAD"]
                let diffPipe = Pipe()
                diffProc.standardOutput = diffPipe
                diffProc.standardError = Pipe()
                try diffProc.run()
                let diffData = diffPipe.fileHandleForReading.readDataToEndOfFile()
                diffProc.waitUntilExit()
                let output = String(data: diffData, encoding: .utf8) ?? ""
                continuation.resume(returning: parseBranchDiff(output))
            } catch {
                continuation.resume(returning: [])
            }
        }
    }
}

private func parseBranchDiff(_ output: String) -> [BranchFileChange] {
    output.components(separatedBy: "\n").compactMap { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let statusChar = trimmed.first else { return nil }
        // Format: "M\tpath" or "R100\told\tnew"
        let parts = trimmed.split(separator: "\t", maxSplits: 2)
        guard parts.count >= 2 else { return nil }
        let path = parts.count > 2 ? String(parts[2]) : String(parts[1])
        // Normalize rename status (R100 → R)
        let normalizedStatus: Character = statusChar == "R" || (statusChar == "R" && parts[0].count > 1) ? "R" : statusChar
        return BranchFileChange(path: path, status: normalizedStatus)
    }
}

// MARK: - ChangesPanelClick

/// What a click on a file in the Changes list sends (side panel notes and
/// Changes spec, "Changes"): `open` of the file at its absolute path, which
/// the daemon's reuse rule places, and with `newPanel` when Shift was held.
/// Pure, so each click can be asserted without standing up a view; the row
/// reads the modifier when it is clicked.
enum ChangesPanelClick {
    static func operation(worktreePath: String, relativePath: String, shift: Bool) -> PanelOperation {
        .open(
            content: .file(FileReference(path: absolutePath(worktreePath: worktreePath, relativePath: relativePath))),
            newPanel: shift)
    }
}

// MARK: - ChangesPanelView

/// The worktree's Changes list as a side-panel tab: its staged, changed,
/// untracked and branch files, in sections that fold.
///
/// The strip around it names it, closes it and carries its refresh control
/// (`PaneChromeControl.refresh`), so it draws no header of its own. It loads
/// when it appears and again whenever that control bumps
/// `chrome.refreshCount`.
///
/// A click on a file hands its worktree-relative path to `onOpenFile`, with
/// whether Shift was held, read as the click lands. A double-click opens the
/// file in its default app, and a right-click offers Copy Path.
struct ChangesPanelView: View {
    /// Every read below is of a directory on this disk, so the panel takes the
    /// proven-local wrapper rather than a bare `Worktree`.
    let worktree: LocalWorktree
    /// The panel's control state, whose `refreshCount` the list reloads on.
    let chrome: PaneChromeState
    let onOpenFile: @MainActor (_ relativePath: String, _ newPanel: Bool) -> Void
    @Environment(AppState.self) var appState

    @State private var staged: [GitFileStatus] = []
    @State private var unstaged: [GitFileStatus] = []
    @State private var untracked: [GitFileStatus] = []
    @State private var branchChanges: [BranchFileChange] = []
    @State private var isLoading = false

    var body: some View {
        fileList
            .background(Color(nsColor: .controlBackgroundColor))
            .task(id: chrome.refreshCount) { await refresh() }
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if staged.isEmpty && unstaged.isEmpty && untracked.isEmpty && branchChanges.isEmpty && !isLoading {
                    Text("No changes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                }
                if !staged.isEmpty {
                    FileStatusSection(title: "Staged", files: staged, useIndexStatus: true, worktreePath: worktree.path, onFileClick: onOpenFile)
                }
                if !unstaged.isEmpty {
                    FileStatusSection(title: "Changes", files: unstaged, useIndexStatus: false, worktreePath: worktree.path, onFileClick: onOpenFile)
                }
                if !untracked.isEmpty {
                    FileStatusSection(title: "Untracked", files: untracked, useIndexStatus: false, worktreePath: worktree.path, onFileClick: onOpenFile)
                }
                if !branchChanges.isEmpty {
                    BranchChangeSection(title: "Branch", files: branchChanges, worktreePath: worktree.path, onFileClick: onOpenFile)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var defaultBranch: String {
        appState.repos.first { $0.id == worktree.repoID }?.defaultBranch ?? "main"
    }

    private func refresh() async {
        isLoading = true
        async let statusTask = loadGitStatus(at: worktree.path)
        async let branchTask = worktree.status == .main
            ? [BranchFileChange]()
            : loadBranchDiff(at: worktree.path, defaultBranch: defaultBranch)
        let statuses = await statusTask
        staged = statuses.filter(\.isStaged)
        unstaged = statuses.filter(\.isUnstaged)
        untracked = statuses.filter(\.isUntracked)
        branchChanges = await branchTask
        isLoading = false
    }
}

// MARK: - RetiredFilePanelDefaults

/// Defaults keys nothing reads: whether a Changes column at the window's
/// right edge showed, and its width. The Changes list is a side-panel tab
/// (`ChangesPanelView`), and `AppState` removes both keys at launch.
enum RetiredFilePanelDefaults {
    static let keys = ["filePanel.isVisible", "filePanel.width"]

    /// Removes each key `defaults` holds, and writes nothing for one it does
    /// not.
    static func remove(from defaults: UserDefaults) {
        for key in keys where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
        }
    }
}

// MARK: - FileStatusSection

private struct FileStatusSection: View {
    let title: String
    let files: [GitFileStatus]
    /// When true, show indexStatus (X) per row; when false, show workingStatus (Y).
    /// Staged section uses index; Changes/Untracked sections use working tree.
    let useIndexStatus: Bool
    let worktreePath: String
    let onFileClick: @MainActor (String, Bool) -> Void
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(title.uppercased())
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                    Text("(\(files.count))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(files) { file in
                    let statusChar = useIndexStatus ? file.indexStatus : file.workingStatus
                    GitFileRow(file: file, statusChar: statusChar, worktreePath: worktreePath, onFileClick: onFileClick)
                }
            }
        }
    }
}

// MARK: - GitFileRow

private struct GitFileRow: View {
    let file: GitFileStatus
    let statusChar: Character
    let worktreePath: String
    let onFileClick: @MainActor (String, Bool) -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text(String(statusChar))
                .font(.system(.caption2, design: .monospaced))
                .fontWeight(.bold)
                .foregroundStyle(statusColor(for: statusChar))
                .frame(width: 12, alignment: .center)
            Text(file.path)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(isHovered ? Color(nsColor: .controlAccentColor).opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            // Double-click: open in default app (Finder/external editor)
            let url = URL(fileURLWithPath: worktreePath).appendingPathComponent(file.path)
            NSWorkspace.shared.open(url)
        }
        .onTapGesture(count: 1) {
            // Single-click: open in a side panel, a new one with Shift held.
            onFileClick(file.path, NSEvent.modifierFlags.contains(.shift))
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Copy Path") {
                copyPathToPasteboard(absolutePath(worktreePath: worktreePath, relativePath: file.path))
            }
        }
    }
}

// MARK: - BranchChangeSection

private struct BranchChangeSection: View {
    let title: String
    let files: [BranchFileChange]
    let worktreePath: String
    let onFileClick: @MainActor (String, Bool) -> Void
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(title.uppercased())
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                    Text("(\(files.count))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(files) { file in
                    BranchFileRow(file: file, worktreePath: worktreePath, onFileClick: onFileClick)
                }
            }
        }
    }
}

// MARK: - BranchFileRow

private struct BranchFileRow: View {
    let file: BranchFileChange
    let worktreePath: String
    let onFileClick: @MainActor (String, Bool) -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text(String(file.status))
                .font(.system(.caption2, design: .monospaced))
                .fontWeight(.bold)
                .foregroundStyle(statusColor(for: file.status))
                .frame(width: 12, alignment: .center)
            Text(file.path)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(isHovered ? Color(nsColor: .controlAccentColor).opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            let url = URL(fileURLWithPath: worktreePath).appendingPathComponent(file.path)
            NSWorkspace.shared.open(url)
        }
        .onTapGesture(count: 1) {
            // Single-click: open in a side panel, a new one with Shift held.
            onFileClick(file.path, NSEvent.modifierFlags.contains(.shift))
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Copy Path") {
                copyPathToPasteboard(absolutePath(worktreePath: worktreePath, relativePath: file.path))
            }
        }
    }
}
