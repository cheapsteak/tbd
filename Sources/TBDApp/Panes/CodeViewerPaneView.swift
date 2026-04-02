import SwiftUI
import AppKit
@preconcurrency import Highlightr
import MarkdownUI

// MARK: - CodeViewerPaneView

/// Preference key that child views set to signal renderable content is present.
struct HasRenderableContentKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// Files that have a rich rendered view in addition to raw source code.
private func isRenderableFile(_ path: String) -> Bool {
    let ext = (path as NSString).pathExtension.lowercased()
    return ["md", "markdown"].contains(ext)
}

struct CodeViewerPaneView: View {
    let path: String
    let worktreePath: String
    let showSourceCode: Bool

    @State private var selectedFiles: [String] = []
    @AppStorage("codeViewer.showSidebar") private var showSidebar = false

    var body: some View {
        HStack(spacing: 0) {
            if showSidebar {
                CodeViewerSidebar(
                    worktreePath: worktreePath,
                    selectedFiles: $selectedFiles,
                    revealPath: path
                )
                .frame(width: 200)
                .transition(.move(edge: .leading))

                Divider()
                    .transition(.move(edge: .leading))
            }

            // Code preview
            Group {
                if selectedFiles.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(selectedFiles, id: \.self) { filePath in
                                if selectedFiles.count > 1 {
                                    fileHeader(filePath)
                                }
                                FilePreviewView(filePath: filePath, showSourceCode: showSourceCode)
                            }
                        }
                    }
                }
            }
            .background(highlightrBackgroundColor)
            .colorScheme(.dark)
        }
        .preference(key: HasRenderableContentKey.self, value: selectedFiles.contains(where: isRenderableFile))
        .onAppear {
            if !path.isEmpty && FileManager.default.fileExists(atPath: path) {
                selectedFiles = [path]
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Select a file to view")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fileHeader(_ path: String) -> some View {
        HStack {
            Image(systemName: "doc.text")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(URL(fileURLWithPath: path).lastPathComponent)
                .font(.caption)
                .fontWeight(.medium)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.08))
    }
}

// MARK: - File Type Detection

private let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "webp", "heic", "heif", "ico", "svg"]

private func isImageFile(_ path: String) -> Bool {
    let ext = (path as NSString).pathExtension.lowercased()
    return imageExtensions.contains(ext)
}

private func isTextFile(_ path: String) -> Bool {
    // Try reading a small chunk as UTF-8 to detect binary
    guard let fh = FileHandle(forReadingAtPath: path) else { return false }
    defer { fh.closeFile() }
    let sample = fh.readData(ofLength: 8192)
    return String(data: sample, encoding: .utf8) != nil
}

// MARK: - FilePreviewView

/// Routes to the appropriate preview based on file type:
/// images → native NSImage, text → syntax-highlighted code, binary → "Open in Finder" fallback.
private struct FilePreviewView: View {
    let filePath: String
    let showSourceCode: Bool

    var body: some View {
        if !showSourceCode && isRenderableFile(filePath) {
            RenderedContentView(filePath: filePath)
        } else if isImageFile(filePath) {
            ImagePreviewView(filePath: filePath)
        } else if isTextFile(filePath) {
            HighlightedCodeView(filePath: filePath)
        } else {
            BinaryFallbackView(filePath: filePath)
        }
    }
}

// MARK: - RenderedContentView

private struct RenderedContentView: View {
    let filePath: String
    @State private var content: String?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let error = loadError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else if let content {
                Markdown(content)
                    .markdownTheme(.gitHub)
                    .textSelection(.enabled)
                    .padding(16)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 100)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: filePath) {
            await loadContent()
        }
    }

    private func loadContent() async {
        content = nil
        loadError = nil
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: filePath),
           let size = attrs[.size] as? UInt64, size > 1_048_576 {
            loadError = "File too large to preview (\(size / 1024)KB)"
            return
        }
        do {
            content = try String(contentsOfFile: filePath, encoding: .utf8)
        } catch {
            loadError = "Could not read file"
        }
    }
}

// MARK: - ImagePreviewView

private struct ImagePreviewView: View {
    let filePath: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(12)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("Could not load image")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: filePath) {
            image = NSImage(contentsOfFile: filePath)
        }
    }
}

// MARK: - BinaryFallbackView

private struct BinaryFallbackView: View {
    let filePath: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Cannot preview binary file")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(URL(fileURLWithPath: filePath).lastPathComponent)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Button("Open in Finder") {
                NSWorkspace.shared.open(URL(fileURLWithPath: filePath))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - HighlightedCodeView

private struct HighlightedCodeView: View {
    let filePath: String
    @State private var attributedContent: NSAttributedString?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let error = loadError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else if let content = attributedContent {
                Text(AttributedString(content))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 100)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: filePath) {
            await loadAndHighlight()
        }
    }

    private func loadAndHighlight() async {
        // Guard against large files (>1MB) to prevent memory pressure
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: filePath),
           let size = attrs[.size] as? UInt64, size > 1_048_576 {
            loadError = "File too large to preview (\(size / 1024)KB)"
            return
        }
        do {
            let content = try String(contentsOfFile: filePath, encoding: .utf8)
            let highlighted = highlightCode(content, filename: filePath)
            attributedContent = highlighted
        } catch {
            loadError = "Could not read file"
        }
    }
}

// MARK: - Syntax Highlighting

/// Shared Highlightr instance — accessed only from @MainActor context
/// to avoid thread-safety issues (Highlightr is not thread-safe).
@MainActor
private let sharedHighlightr: Highlightr? = {
    let h = Highlightr()
    h?.setTheme(to: "atom-one-dark")
    return h
}()

@MainActor
private var highlightrBackgroundColor: Color {
    if let bg = sharedHighlightr?.theme.themeBackgroundColor {
        return Color(nsColor: bg)
    }
    return Color(nsColor: .textBackgroundColor)
}

@MainActor
private func highlightCode(_ code: String, filename: String) -> NSAttributedString {
    let lang = languageForFilename(filename)
    let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    guard let highlightr = sharedHighlightr,
          let highlighted = highlightr.highlight(code, as: lang) else {
        return NSAttributedString(string: code, attributes: [.font: monoFont])
    }

    let mutable = NSMutableAttributedString(attributedString: highlighted)
    let fullRange = NSRange(location: 0, length: mutable.length)

    // Override font to consistent monospace
    mutable.addAttribute(.font, value: monoFont, range: fullRange)

    return mutable
}

private func languageForFilename(_ filename: String) -> String? {
    let ext = (filename as NSString).pathExtension.lowercased()
    let map: [String: String] = [
        "swift": "swift", "ts": "typescript", "tsx": "typescript", "js": "javascript",
        "jsx": "javascript", "py": "python", "rb": "ruby", "go": "go", "rs": "rust",
        "java": "java", "kt": "kotlin", "cpp": "cpp", "c": "c", "h": "c", "hpp": "cpp",
        "cs": "csharp", "css": "css", "scss": "scss", "html": "xml", "xml": "xml",
        "json": "json", "yaml": "yaml", "yml": "yaml", "toml": "ini", "sql": "sql",
        "sh": "bash", "bash": "bash", "zsh": "bash", "md": "markdown",
        "graphql": "graphql", "gql": "graphql",
    ]
    return map[ext]
}

// MARK: - CodeViewerSidebar

struct CodeViewerSidebar: View {
    let worktreePath: String
    @Binding var selectedFiles: [String]
    var revealPath: String = ""
    @State private var expandedDirs: Set<String> = []
    @State private var entries: [FileEntry] = []
    @State private var scrollTargetID: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Files")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(entries, id: \.path) { entry in
                        FileEntryRow(
                            entry: entry,
                            isExpanded: expandedDirs.contains(entry.path),
                            isSelected: selectedFiles.contains(entry.path),
                            onToggleDir: { toggleDir(entry.path) },
                            onSelectFile: { selectFile(entry.path, event: NSApp.currentEvent) }
                        )
                        .id(entry.path)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $scrollTargetID, anchor: .center)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .task(id: worktreePath) {
            loadTopLevel()
            revealFile()
        }
        .onChange(of: revealPath) {
            revealFile()
        }
    }

    private func loadTopLevel() {
        guard !worktreePath.isEmpty else { return }
        entries = listDirectory(worktreePath, depth: 0)
    }

    /// Expand all ancestor directories so `revealPath` is visible in the tree,
    /// then scroll to it via `scrollPosition(id:)` binding.
    private func revealFile() {
        guard !revealPath.isEmpty,
              revealPath.hasPrefix(worktreePath + "/") else { return }

        let relative = revealPath.replacingOccurrences(of: worktreePath + "/", with: "")
        let components = relative.components(separatedBy: "/")
        // Expand each ancestor directory (all but the last component which is the file)
        var currentPath = worktreePath
        for component in components.dropLast() {
            currentPath += "/" + component
            if !expandedDirs.contains(currentPath) {
                expandedDirs.insert(currentPath)
                let depth = depthOf(currentPath)
                let children = listDirectory(currentPath, depth: depth + 1)
                if let idx = entries.firstIndex(where: { $0.path == currentPath }) {
                    entries.insert(contentsOf: children, at: idx + 1)
                }
            }
        }

        // Defer to next run loop so SwiftUI processes the entries mutation first
        Task { @MainActor in
            scrollTargetID = revealPath
        }
    }

    private func toggleDir(_ path: String) {
        if expandedDirs.contains(path) {
            expandedDirs.remove(path)
            entries.removeAll { $0.path.hasPrefix(path + "/") }
        } else {
            expandedDirs.insert(path)
            let children = listDirectory(path, depth: depthOf(path) + 1)
            if let idx = entries.firstIndex(where: { $0.path == path }) {
                entries.insert(contentsOf: children, at: idx + 1)
            }
        }
    }

    private func selectFile(_ path: String, event: NSEvent?) {
        if event?.modifierFlags.contains(.command) == true {
            if selectedFiles.contains(path) {
                selectedFiles.removeAll { $0 == path }
            } else {
                selectedFiles.append(path)
            }
        } else {
            selectedFiles = [path]
        }
    }

    private func depthOf(_ path: String) -> Int {
        let relative = path.replacingOccurrences(of: worktreePath + "/", with: "")
        return relative.components(separatedBy: "/").count - 1
    }

    private func listDirectory(_ dir: String, depth: Int) -> [FileEntry] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        return items
            .filter { !$0.hasPrefix(".") }
            .sorted { a, b in
                let aIsDir = isDirectory(dir + "/" + a)
                let bIsDir = isDirectory(dir + "/" + b)
                if aIsDir != bIsDir { return aIsDir }
                return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }
            .map { name in
                let fullPath = dir + "/" + name
                return FileEntry(path: fullPath, name: name, isDirectory: isDirectory(fullPath), depth: depth)
            }
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return isDir.boolValue
    }
}

struct FileEntry {
    let path: String
    let name: String
    let isDirectory: Bool
    let depth: Int
}

private struct FileEntryRow: View {
    let entry: FileEntry
    let isExpanded: Bool
    let isSelected: Bool
    let onToggleDir: () -> Void
    let onSelectFile: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            if entry.isDirectory {
                onToggleDir()
            } else {
                onSelectFile()
            }
        } label: {
            HStack(spacing: 4) {
                if entry.isDirectory {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                } else {
                    Color.clear.frame(width: 10)
                }

                Image(systemName: entry.isDirectory ? "folder" : "doc")
                    .font(.caption2)
                    .foregroundStyle(entry.isDirectory ? .blue : .secondary)

                Text(entry.name)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()
            }
            .padding(.leading, CGFloat(entry.depth) * 16 + 8)
            .padding(.vertical, 3)
            .background(
                isSelected ? Color.accentColor.opacity(0.2) :
                (isHovered ? Color.primary.opacity(0.05) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
