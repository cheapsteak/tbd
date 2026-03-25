import AppKit
import SwiftUI
import TBDShared

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

// MARK: - FileViewerPanel

struct FileViewerPanel: View {
    let worktree: Worktree
    @EnvironmentObject var appState: AppState

    @State private var staged: [GitFileStatus] = []
    @State private var unstaged: [GitFileStatus] = []
    @State private var untracked: [GitFileStatus] = []
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            fileList
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .task(id: worktree.id) { await refresh() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Changes")
                .font(.subheadline)
                .fontWeight(.semibold)
            Spacer()
            if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Button { Task { await refresh() } } label: {
                    Image(systemName: "arrow.clockwise").font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if staged.isEmpty && unstaged.isEmpty && untracked.isEmpty && !isLoading {
                    Text("No changes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                }
                if !staged.isEmpty {
                    FileStatusSection(title: "Staged", files: staged, useIndexStatus: true, worktreePath: worktree.path, onFileClick: handleFileClick)
                }
                if !unstaged.isEmpty {
                    FileStatusSection(title: "Changes", files: unstaged, useIndexStatus: false, worktreePath: worktree.path, onFileClick: handleFileClick)
                }
                if !untracked.isEmpty {
                    FileStatusSection(title: "Untracked", files: untracked, useIndexStatus: false, worktreePath: worktree.path, onFileClick: handleFileClick)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func handleFileClick(_ relativePath: String, cmdClick: Bool) {
        let fullPath = URL(fileURLWithPath: worktree.path).appendingPathComponent(relativePath).path
        var tabs = appState.tabs[worktree.id, default: []]

        if !cmdClick, let existingIndex = tabs.firstIndex(where: {
            if case .codeViewer = $0.content { return true }
            return false
        }) {
            // Replace existing code viewer tab content
            let newID = UUID()
            tabs[existingIndex].content = .codeViewer(id: newID, path: fullPath)
            tabs[existingIndex].label = URL(fileURLWithPath: relativePath).lastPathComponent
            appState.tabs[worktree.id] = tabs
        } else {
            // Create new code viewer tab
            let newID = UUID()
            let tab = Tab(id: UUID(), content: .codeViewer(id: newID, path: fullPath), label: URL(fileURLWithPath: relativePath).lastPathComponent)
            appState.tabs[worktree.id, default: []].append(tab)
        }
    }

    private func refresh() async {
        isLoading = true
        let statuses = await loadGitStatus(at: worktree.path)
        staged = statuses.filter(\.isStaged)
        unstaged = statuses.filter(\.isUnstaged)
        untracked = statuses.filter(\.isUntracked)
        isLoading = false
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
    var onFileClick: (String, Bool) -> Void = { _, _ in }
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
    var onFileClick: (String, Bool) -> Void = { _, _ in }
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
            // Single-click: open in code viewer pane
            let cmdClick = NSEvent.modifierFlags.contains(.command)
            onFileClick(file.path, cmdClick)
        }
        .onHover { isHovered = $0 }
    }
}
