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

// MARK: - Custom Markdown Theme

/// GitHub-like markdown theme with transparent background and font sizes
/// tuned for the code viewer pane (13pt base instead of 16pt).
private extension MarkdownUI.Theme {
    @MainActor static let codeViewer = MarkdownUI.Theme()
        .text {
            ForegroundColor(.codeViewerText)
            FontSize(13)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.85))
            BackgroundColor(.codeViewerSecondaryBg)
        }
        .strong {
            FontWeight(.semibold)
        }
        .link {
            ForegroundColor(.codeViewerLink)
        }
        .heading1 { configuration in
            VStack(alignment: .leading, spacing: 0) {
                configuration.label
                    .relativePadding(.bottom, length: .em(0.3))
                    .relativeLineSpacing(.em(0.125))
                    .markdownMargin(top: 24, bottom: 16)
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(2))
                    }
                Divider().overlay(Color.codeViewerDivider)
            }
        }
        .heading2 { configuration in
            VStack(alignment: .leading, spacing: 0) {
                configuration.label
                    .relativePadding(.bottom, length: .em(0.3))
                    .relativeLineSpacing(.em(0.125))
                    .markdownMargin(top: 24, bottom: 16)
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(1.5))
                    }
                Divider().overlay(Color.codeViewerDivider)
            }
        }
        .heading3 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.125))
                .markdownMargin(top: 24, bottom: 16)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.25))
                }
        }
        .heading4 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.125))
                .markdownMargin(top: 24, bottom: 16)
                .markdownTextStyle {
                    FontWeight(.semibold)
                }
        }
        .heading5 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.125))
                .markdownMargin(top: 24, bottom: 16)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(0.875))
                }
        }
        .heading6 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.125))
                .markdownMargin(top: 24, bottom: 16)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(0.85))
                    ForegroundColor(.codeViewerTertiaryText)
                }
        }
        .paragraph { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.25))
                .markdownMargin(top: 0, bottom: 16)
        }
        .blockquote { configuration in
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.codeViewerBorder)
                    .relativeFrame(width: .em(0.2))
                configuration.label
                    .markdownTextStyle { ForegroundColor(.codeViewerSecondaryText) }
                    .relativePadding(.horizontal, length: .em(1))
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .codeBlock { configuration in
            ScrollView(.horizontal) {
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.225))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.85))
                    }
                    .padding(16)
            }
            .background(Color.codeViewerSecondaryBg)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .markdownMargin(top: 0, bottom: 16)
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: .em(0.25))
        }
        .taskListMarker { configuration in
            Image(systemName: configuration.isCompleted ? "checkmark.square.fill" : "square")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.codeViewerCheckbox, Color.codeViewerCheckboxBg)
                .imageScale(.small)
                .relativeFrame(minWidth: .em(1.5), alignment: .trailing)
        }
        .table { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .markdownTableBorderStyle(.init(color: .codeViewerBorder))
                .markdownTableBackgroundStyle(
                    .alternatingRows(Color.clear, Color.codeViewerSecondaryBg)
                )
                .markdownMargin(top: 0, bottom: 16)
        }
        .tableCell { configuration in
            configuration.label
                .markdownTextStyle {
                    if configuration.row == 0 {
                        FontWeight(.semibold)
                    }
                    BackgroundColor(nil)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 6)
                .padding(.horizontal, 13)
                .relativeLineSpacing(.em(0.25))
        }
        .thematicBreak {
            Divider()
                .relativeFrame(height: .em(0.25))
                .overlay(Color.codeViewerBorder)
                .markdownMargin(top: 24, bottom: 24)
        }
}

private extension Color {
    static let codeViewerText = Color(
        light: Color(red: 0.024, green: 0.024, blue: 0.024),
        dark: Color(red: 0.984, green: 0.984, blue: 0.988)
    )
    static let codeViewerSecondaryText = Color(
        light: Color(red: 0.42, green: 0.43, blue: 0.48),
        dark: Color(red: 0.573, green: 0.58, blue: 0.627)
    )
    static let codeViewerTertiaryText = Color(
        light: Color(red: 0.42, green: 0.43, blue: 0.48),
        dark: Color(red: 0.427, green: 0.44, blue: 0.49)
    )
    // Slightly lighter than atom-one-dark bg for code blocks / alt table rows
    static let codeViewerSecondaryBg = Color(
        light: Color(red: 0.969, green: 0.969, blue: 0.976),
        dark: Color(white: 1, opacity: 0.06)
    )
    static let codeViewerLink = Color(
        light: Color(red: 0.173, green: 0.396, blue: 0.812),
        dark: Color(red: 0.298, green: 0.557, blue: 0.973)
    )
    static let codeViewerBorder = Color(
        light: Color(red: 0.894, green: 0.894, blue: 0.91),
        dark: Color(white: 1, opacity: 0.15)
    )
    static let codeViewerDivider = Color(
        light: Color(red: 0.816, green: 0.816, blue: 0.827),
        dark: Color(white: 1, opacity: 0.1)
    )
    static let codeViewerCheckbox = Color(red: 0.725, green: 0.725, blue: 0.733)
    static let codeViewerCheckboxBg = Color(red: 0.933, green: 0.933, blue: 0.937)
}

/// Files that have a rich rendered view in addition to raw source code.
private func isRenderableFile(_ path: String) -> Bool {
    let ext = (path as NSString).pathExtension.lowercased()
    return ["md", "markdown"].contains(ext)
}

/// Decides whether a rendered markdown document owns the whole code-viewer
/// pane instead of being stacked inside the pane's `ScrollView`.
///
/// `WKWebView` reports `noIntrinsicMetric` for height. Inside a `ScrollView`
/// the vertical proposal is unbounded, so the webview resolves to its ideal
/// height — zero — and the pane paints nothing but its background. A rendered
/// document therefore replaces the `ScrollView` outright and scrolls
/// internally.
///
/// Only a *single* selected markdown file qualifies. A multi-file selection
/// with the flag on would hit the same zero-height collapse, and stacking N
/// internally-scrolling webviews needs a layout design of its own, so it falls
/// back to the MarkdownUI rendering — a known limitation for the soak.
enum MarkdownPaneLayout {
    static func usesFullPaneWebView(
        showSourceCode: Bool,
        selectedFiles: [String],
        useWebView: Bool
    ) -> Bool {
        guard useWebView, !showSourceCode, selectedFiles.count == 1 else { return false }
        return isRenderableFile(selectedFiles[0])
    }
}

struct CodeViewerPaneView: View {
    let path: String
    let worktreePath: String
    let showSourceCode: Bool

    @State private var selectedFiles: [String] = []
    @AppStorage("codeViewer.showSidebar") private var showSidebar = false

    /// Computed rather than stored: a `private` stored property would drag the
    /// synthesized memberwise initializer down to `private` too, breaking the
    /// pane's call sites.
    private var usesFullPaneWebView: Bool {
        MarkdownPaneLayout.usesFullPaneWebView(
            showSourceCode: showSourceCode,
            selectedFiles: selectedFiles,
            useWebView: MarkdownViewerPreferences.useWebView()
        )
    }

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
                } else if usesFullPaneWebView {
                    // The webview scrolls itself; wrapping it in the pane's
                    // ScrollView collapses it to zero height. See
                    // `MarkdownPaneLayout`.
                    FilePreviewView(
                        filePath: selectedFiles[0],
                        worktreePath: worktreePath,
                        showSourceCode: showSourceCode,
                        useWebViewMarkdown: true
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(selectedFiles, id: \.self) { filePath in
                                if selectedFiles.count > 1 {
                                    fileHeader(filePath)
                                }
                                // Always the MarkdownUI renderer here: a
                                // webview nested in this ScrollView has no
                                // height. With the flag on, this is reached
                                // only by a multi-file selection — the known
                                // limitation named in `MarkdownPaneLayout`.
                                FilePreviewView(
                                    filePath: filePath,
                                    worktreePath: worktreePath,
                                    showSourceCode: showSourceCode,
                                    useWebViewMarkdown: false
                                )
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
        .onChange(of: path) { _, newPath in
            if !newPath.isEmpty && FileManager.default.fileExists(atPath: newPath) {
                selectedFiles = [newPath]
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
///
/// File-watching plumbing intentionally avoids `@StateObject` /
/// `ObservableObject` / `@Published` — see the doc-comment on
/// `FileWatcher` for the SIGTRAP that taught us why. The watcher exposes
/// changes as an `AsyncStream<Void>` consumed inside `.task(id: filePath)`;
/// when the task is cancelled (path change, view teardown) the stream's
/// `onTermination` cancels the dispatch source, closing the FD via its
/// cancel handler. SwiftUI just observes the `revision` Int.
private struct FilePreviewView: View {
    let filePath: String
    /// Trust boundary for local image inlining in the rendered markdown path.
    let worktreePath: String
    let showSourceCode: Bool
    /// Decided by the pane, not read from `UserDefaults` here: only the pane
    /// knows whether this preview owns the full height the webview needs.
    let useWebViewMarkdown: Bool

    @State private var revision: Int = 0
    private let watcher = FileWatcher()

    var body: some View {
        Group {
            if !showSourceCode && isRenderableFile(filePath) {
                RenderedContentView(
                    filePath: filePath,
                    worktreePath: worktreePath,
                    revision: revision,
                    useWebView: useWebViewMarkdown
                )
            } else if isImageFile(filePath) {
                ImagePreviewView(filePath: filePath, revision: revision)
            } else if isTextFile(filePath) {
                HighlightedCodeView(filePath: filePath, revision: revision)
            } else {
                BinaryFallbackView(filePath: filePath)
            }
        }
        .task(id: filePath) {
            // Each filePath change starts a fresh stream. Iterating it
            // inside `.task` ties FD lifetime to this view: when the task
            // is cancelled (path change, view teardown), the stream's
            // iterator is dropped, `onTermination` fires, and the dispatch
            // source is cancelled — which closes the FD via its cancel
            // handler. SwiftUI re-renders the leaf view on each yield, and
            // its `.task(id: "<path>#<rev>")` reloads the file contents.
            for await _ in watcher.changes(for: filePath) {
                revision &+= 1
            }
        }
    }
}

// MARK: - RenderedContentView

private struct RenderedContentView: View {
    let filePath: String
    let worktreePath: String
    let revision: Int
    let useWebView: Bool
    @State private var content: String?
    @State private var loadError: String?
    @State private var renderedHTML: String?
    /// The path `renderedHTML` belongs to. `@State` survives a `filePath`
    /// change because this view is not `.id(filePath)`-keyed, so without this
    /// a file switch would briefly paint the previous file's HTML.
    @State private var renderedPath: String?

    var body: some View {
        Group {
            if let error = loadError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else if useWebView {
                if let renderedHTML {
                    MarkdownWebView(html: renderedHTML)
                } else {
                    ProgressView().controlSize(.small)
                }
            } else if let content {
                Markdown(content, baseURL: URL(fileURLWithPath: filePath))
                    .markdownTheme(.codeViewer)
                    .textSelection(.enabled)
                    .environment(\.openURL, OpenURLAction { url in
                        if url.isFileURL {
                            NSWorkspace.shared.open(url)
                            return .handled
                        }
                        return .systemAction
                    })
                    .padding(16)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 100)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: "\(filePath)#\(revision)#\(useWebView)") {
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
        // Clear ONLY on a file switch. Clearing unconditionally on every
        // `revision` bump would remove `MarkdownWebView` from the hierarchy,
        // tearing down the WKWebView and its coordinator — defeating the
        // in-place swap in `updateNSView` and costing a blank flash plus a
        // scroll reset on every save.
        if renderedPath != filePath { renderedHTML = nil }
        renderedPath = filePath

        if useWebView {
            let html = await MarkdownRenderService.shared.render(
                path: filePath,
                worktreeRoot: worktreePath,
                css: MarkdownDocumentBuilder.defaultCSS
            )
            guard !Task.isCancelled else { return }
            renderedHTML = html
            if html == nil { loadError = "Unable to render this file." }
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
    let revision: Int
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
        .task(id: "\(filePath)#\(revision)") {
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
    let revision: Int
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
        .task(id: "\(filePath)#\(revision)") {
            await loadAndHighlight()
        }
    }

    private func loadAndHighlight() async {
        let result = await CodeViewerHighlightService.shared.loadAndHighlight(path: filePath)
        // `.task(id:)` cancelled us mid-highlight (rapid file switch / teardown):
        // a newer task owns this view's state now, so drop the stale result.
        guard !Task.isCancelled else { return }
        switch result {
        case .highlighted(let text):
            attributedContent = text
        case .tooLarge(let sizeKB):
            loadError = "File too large to preview (\(sizeKB)KB)"
        case .unreadable:
            loadError = "Could not read file"
        }
    }
}

// MARK: - Syntax Highlighting

/// atom-one-dark's background (#282c34), hardcoded so rendering the pane never
/// creates the Highlightr JavaScriptCore VM on the main thread just to read a
/// color. Must match the theme `CodeViewerHighlightService` sets.
private let highlightrBackgroundColor = Color(
    red: 0x28 / 255.0, green: 0x2C / 255.0, blue: 0x34 / 255.0
)

/// Result of an off-main file load + highlight for the code viewer.
/// `@unchecked` because `NSAttributedString` lacks a `Sendable` conformance:
/// the string is freshly built on the highlight queue, never mutated after,
/// and handed across exactly once.
private enum CodeViewerLoadResult: @unchecked Sendable {
    case highlighted(NSAttributedString)
    case tooLarge(sizeKB: UInt64)
    case unreadable
}

/// Off-main file read + syntax highlighter for the code viewer pane — the same
/// JSC-VM-on-main freeze class `CodeHighlightService` fixed for the transcript
/// (#129 / PR #308).
///
/// `Highlightr` wraps highlight.js inside a JavaScriptCore VM: creating the VM
/// and running highlight.js can stall the calling thread for seconds. This
/// service confines the lazily-created `Highlightr` — and every call into it —
/// to a dedicated serial queue (JSContext is thread-confined), and reads the
/// file there too, so opening a file never blocks the main thread.
///
/// `@unchecked Sendable`: the only mutable state (the lazy `Highlightr`) is
/// confined to `queue`, so access is serialized at runtime rather than checked
/// by the compiler — the same guarantee `CodeHighlightService` relies on.
private final class CodeViewerHighlightService: @unchecked Sendable {
    static let shared = CodeViewerHighlightService()

    private let queue = DispatchQueue(label: "com.tbd.code-viewer-highlight", qos: .userInitiated)

    /// Created lazily ON `queue` and only ever touched there.
    private var highlightr: Highlightr?
    private var didCreateHighlightr = false

    private init() {}

    /// Lazily create the `Highlightr` (MUST run on `queue`).
    private func makeHighlightrIfNeeded() -> Highlightr? {
        if !didCreateHighlightr {
            didCreateHighlightr = true
            let h = Highlightr()
            h?.setTheme(to: "atom-one-dark")
            highlightr = h
        }
        return highlightr
    }

    /// Read `path` and syntax-highlight its contents, entirely off the
    /// caller's thread. Callers publish the result back on the main actor.
    func loadAndHighlight(path: String) async -> CodeViewerLoadResult {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: loadAndHighlightNow(path: path))
            }
        }
    }

    /// MUST run on `queue`.
    private func loadAndHighlightNow(path: String) -> CodeViewerLoadResult {
        // Guard against large files (>1MB) to prevent memory pressure
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: path),
           let size = attrs[.size] as? UInt64, size > 1_048_576 {
            return .tooLarge(sizeKB: size / 1024)
        }
        guard let code = try? String(contentsOfFile: path, encoding: .utf8) else {
            return .unreadable
        }

        let lang = languageForFilename(path)
        let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        guard let highlightr = makeHighlightrIfNeeded(),
              let highlighted = highlightr.highlight(code, as: lang) else {
            return .highlighted(NSAttributedString(string: code, attributes: [.font: monoFont]))
        }

        let mutable = NSMutableAttributedString(attributedString: highlighted)
        // Override font to consistent monospace
        mutable.addAttribute(.font, value: monoFont, range: NSRange(location: 0, length: mutable.length))
        return .highlighted(NSAttributedString(attributedString: mutable))
    }
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
        // Stat each entry exactly once up front — the old sort comparator
        // re-statted both sides of every comparison, O(n log n) blocking
        // syscalls on the main thread.
        let unsorted = items
            .filter { !$0.hasPrefix(".") }
            .map { name -> FileEntry in
                let fullPath = dir + "/" + name
                var isDir: ObjCBool = false
                fm.fileExists(atPath: fullPath, isDirectory: &isDir)
                return FileEntry(path: fullPath, name: name, isDirectory: isDir.boolValue, depth: depth)
            }
        return FileEntry.sortedForListing(unsorted)
    }
}

struct FileEntry {
    let path: String
    let name: String
    let isDirectory: Bool
    let depth: Int

    /// Directories first, then case-insensitive name order — comparing the
    /// precomputed `isDirectory` flags so sorting never touches the filesystem.
    static func sortedForListing(_ entries: [FileEntry]) -> [FileEntry] {
        entries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
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
