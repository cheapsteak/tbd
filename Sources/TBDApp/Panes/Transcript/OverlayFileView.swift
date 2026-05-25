// Sources/TBDApp/Panes/Transcript/OverlayFileView.swift
import SwiftUI
import AppKit
import MarkdownUI

/// File frame body for the transcript overlay. Renders markdown files
/// (.md / .markdown) with `MarkdownUI` and other text files as plain
/// monospaced text. Files >1 MB or non-text show a placeholder with a
/// "Reveal in Finder" affordance.
///
/// Installs an `OpenURLAction` so `tbd-file:` and `file:` links inside
/// rendered markdown push further file frames; everything else falls
/// through to the system handler (browser, mail, etc.).
struct OverlayFileView: View {
    let path: String

    @EnvironmentObject var overlayCoordinator: TranscriptOverlayCoordinator
    @State private var content: String?
    @State private var loadError: String?
    @State private var tooLarge: UInt64?

    private static let maxBytes: UInt64 = 1_048_576

    private var isMarkdown: Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
    }

    var body: some View {
        ScrollView(.vertical) {
            inner
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .task(id: path) { await load() }
    }

    @ViewBuilder
    private var inner: some View {
        if let err = loadError {
            placeholder(title: "Could not load file", detail: err)
        } else if let size = tooLarge {
            placeholder(
                title: "File too large to preview",
                detail: "\(size / 1024) KB · open in Finder to view"
            )
        } else if let content {
            if isMarkdown {
                Markdown(content, baseURL: URL(fileURLWithPath: path))
                    .markdownTheme(.chatBubble)
                    .textSelection(.enabled)
                    .environment(\.openURL, OpenURLAction { url in
                        if url.scheme == "tbd-file" {
                            overlayCoordinator.pushFile(path: url.path)
                            return .handled
                        }
                        if url.isFileURL {
                            overlayCoordinator.pushFile(path: url.path)
                            return .handled
                        }
                        return .systemAction
                    })
            } else {
                Text(content)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, minHeight: 100)
        }
    }

    @ViewBuilder
    private func placeholder(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text(detail).font(.caption).foregroundStyle(.tertiary)
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            .buttonStyle(.bordered)
        }
    }

    private func load() async {
        await MainActor.run {
            content = nil
            loadError = nil
            tooLarge = nil
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            await MainActor.run { loadError = "File not found: \(path)" }
            return
        }
        if let attrs = try? fm.attributesOfItem(atPath: path),
           let size = attrs[.size] as? UInt64, size > Self.maxBytes {
            await MainActor.run { tooLarge = size }
            return
        }
        do {
            let text = try String(contentsOfFile: path, encoding: .utf8)
            await MainActor.run { content = text }
        } catch {
            await MainActor.run { loadError = "Not readable as UTF-8" }
        }
    }
}
