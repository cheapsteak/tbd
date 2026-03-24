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

    var displayStatus: Character { isStaged ? indexStatus : workingStatus }

    var statusColor: Color {
        switch displayStatus {
        case "M": return .yellow
        case "A": return .green
        case "D": return .red
        case "R", "C": return .blue
        default: return .gray
        }
    }
}

// MARK: - Git Status Loader

func loadGitStatus(at path: String) async -> [GitFileStatus] {
    guard !path.isEmpty else { return [] }
    return await withCheckedContinuation { continuation in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path, "status", "--porcelain=v1", "-u"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        process.terminationHandler = { _ in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            continuation.resume(returning: parseGitStatus(output))
        }
        do { try process.run() } catch { continuation.resume(returning: []) }
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
                    FileStatusSection(title: "Staged", files: staged, worktreePath: worktree.path)
                }
                if !unstaged.isEmpty {
                    FileStatusSection(title: "Changes", files: unstaged, worktreePath: worktree.path)
                }
                if !untracked.isEmpty {
                    FileStatusSection(title: "Untracked", files: untracked, worktreePath: worktree.path)
                }
            }
            .padding(.vertical, 4)
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
    let worktreePath: String
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
                    GitFileRow(file: file, worktreePath: worktreePath)
                }
            }
        }
    }
}

// MARK: - GitFileRow

private struct GitFileRow: View {
    let file: GitFileStatus
    let worktreePath: String
    @State private var isHovered = false

    var body: some View {
        Button {
            let url = URL(fileURLWithPath: worktreePath).appendingPathComponent(file.path)
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 6) {
                Text(String(file.displayStatus))
                    .font(.system(.caption2, design: .monospaced))
                    .fontWeight(.bold)
                    .foregroundStyle(file.statusColor)
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
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
